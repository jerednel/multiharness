import Foundation

public struct AgentEventEnvelope: @unchecked Sendable {
    public let workspaceId: String
    public let type: String
    public let payload: [String: Any]

    public init(workspaceId: String, type: String, payload: [String: Any]) {
        self.workspaceId = workspaceId
        self.type = type
        self.payload = payload
    }
}

public protocol ControlClientDelegate: AnyObject, Sendable {
    func controlClient(_ client: ControlClient, didReceiveEvent event: AgentEventEnvelope)
    func controlClientDidConnect(_ client: ControlClient)
    func controlClientDidDisconnect(_ client: ControlClient, error: Error?)
}

/// Thin JSON-RPC-ish WebSocket client for the sidecar's control protocol.
public final class ControlClient: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public weak var delegate: ControlClientDelegate?

    private let url: URL
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pending: [String: (Result<Any?, Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "ControlClient.queue")

    private var isOpen: Bool = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []

    private let authToken: String?

    public init(port: Int, host: String = "127.0.0.1", authToken: String? = nil) {
        self.url = URL(string: "ws://\(host):\(port)")!
        self.authToken = authToken
        super.init()
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func connect() {
        var req = URLRequest(url: url)
        if let token = authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let t = session.webSocketTask(with: req)
        // Default is 1 MiB; trips on agent.create with large project/workspace
        // context, on user-pasted prompts, and on big tool_execution_end frames.
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        t.resume()
        listen()
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        queue.async {
            self.isOpen = false
            for w in self.connectWaiters {
                w.resume(throwing: ControlError.disconnected)
            }
            self.connectWaiters.removeAll()
        }
    }

    /// Suspends until the WebSocket is open, or the timeout elapses.
    public func awaitConnected(timeout: TimeInterval = 5.0) async throws {
        if isOpen { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        if self.isOpen { cont.resume(); return }
                        self.connectWaiters.append(cont)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ControlError.connectTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    public func call(method: String, params: [String: Any]) async throws -> Any? {
        // URLSessionWebSocketTask accepts send() before the connection is up,
        // and silently leaves a dead socket in place after a remote drop —
        // both surface to callers as "Socket is not connected" (ENOTCONN).
        // Strategy: ensure connected, send; on a "not connected" error,
        // reconnect once and retry the same message.
        let frame: [String: Any] = ["method": method, "params": params]
        do {
            return try await sendFramed(frame)
        } catch {
            if Self.isNotConnected(error) {
                reconnect()
                try await awaitConnected()
                return try await sendFramed(frame)
            }
            throw error
        }
    }

    /// Slightly under `maximumMessageSize` so callers see a typed error
    /// before the WebSocket layer rejects with a cryptic POSIX EMSGSIZE.
    private static let preflightSizeLimit = 60 * 1024 * 1024

    private func sendFramed(_ frame: [String: Any]) async throws -> Any? {
        if !isOpen { try await awaitConnected() }
        let id = UUID().uuidString
        var withId = frame
        withId["id"] = id
        let data = try JSONSerialization.data(withJSONObject: withId, options: [])
        if data.count > Self.preflightSizeLimit {
            throw ControlError.messageTooLarge(
                bytes: data.count,
                limit: Self.preflightSizeLimit,
                method: frame["method"] as? String
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ControlError.encodeFailed
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            queue.async {
                self.pending[id] = { result in
                    switch result {
                    case .success(let v): cont.resume(returning: v)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
            self.task?.send(.string(text)) { err in
                if let err {
                    self.queue.async {
                        if let cb = self.pending.removeValue(forKey: id) {
                            cb(.failure(err))
                        }
                    }
                }
            }
        }
    }

    private func reconnect() {
        // Tear down the dead task, mark closed, open a fresh one. Any pending
        // requests on the old task get dropped — this is best-effort.
        task?.cancel(with: .abnormalClosure, reason: nil)
        queue.async {
            self.isOpen = false
            self.pending.removeAll()
        }
        connect()
    }

    private static func isNotConnected(_ error: Error) -> Bool {
        let nse = error as NSError
        if nse.domain == NSPOSIXErrorDomain && nse.code == 57 { return true }
        // URLSession sometimes wraps ENOTCONN under NSURLErrorDomain with -1005
        // ("network connection was lost") or -1004 ("could not connect").
        if nse.domain == NSURLErrorDomain {
            return nse.code == NSURLErrorNetworkConnectionLost
                || nse.code == NSURLErrorCannotConnectToHost
                || nse.code == NSURLErrorNotConnectedToInternet
        }
        // The user-visible string contains the POSIX message verbatim in
        // some delegate paths.
        return nse.localizedDescription.lowercased().contains("socket is not connected")
    }

    private func listen() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                self.handleMessage(msg)
                self.listen()
            case .failure(let err):
                self.delegate?.controlClientDidDisconnect(self, error: err)
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return }

        if let id = dict["id"] as? String {
            if let err = dict["error"] as? [String: Any] {
                let code = err["code"] as? String ?? "ERR"
                let message = err["message"] as? String ?? "unknown"
                queue.async {
                    if let cb = self.pending.removeValue(forKey: id) {
                        cb(.failure(ControlError.remote(code: code, message: message)))
                    }
                }
            } else {
                let result = dict["result"]
                queue.async {
                    if let cb = self.pending.removeValue(forKey: id) {
                        cb(.success(result))
                    }
                }
            }
            return
        }

        if let event = dict["event"] as? String,
           let params = dict["params"] as? [String: Any] {
            let workspaceId = params["workspaceId"] as? String ?? ""
            delegate?.controlClient(
                self,
                didReceiveEvent: AgentEventEnvelope(
                    workspaceId: workspaceId,
                    type: event,
                    payload: params
                )
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            self.isOpen = true
            let pending = self.connectWaiters
            self.connectWaiters.removeAll()
            for w in pending { w.resume() }
        }
        delegate?.controlClientDidConnect(self)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            self.isOpen = false
            for w in self.connectWaiters { w.resume(throwing: ControlError.disconnected) }
            self.connectWaiters.removeAll()
        }
        delegate?.controlClientDidDisconnect(self, error: nil)
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case encodeFailed
    case remote(code: String, message: String)
    case connectTimeout
    case disconnected
    case messageTooLarge(bytes: Int, limit: Int, method: String?)
    public var description: String {
        switch self {
        case .encodeFailed: return "failed to encode RPC frame as JSON"
        case .remote(let c, let m): return "[\(c)] \(m)"
        case .connectTimeout: return "timed out waiting for control socket to connect"
        case .disconnected: return "control socket disconnected"
        case .messageTooLarge(let bytes, let limit, let method):
            let mb = Double(bytes) / (1024 * 1024)
            let cap = Double(limit) / (1024 * 1024)
            let m = method.map { "\($0) " } ?? ""
            return String(
                format: "%@RPC payload is too large to send (%.1f MB; limit %.0f MB). "
                    + "This is usually an oversized project/workspace context, a "
                    + "very long pasted message, or a huge tool result.",
                m, mb, cap
            )
        }
    }
}

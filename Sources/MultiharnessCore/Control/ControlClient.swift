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

    public init(port: Int) {
        self.url = URL(string: "ws://127.0.0.1:\(port)")!
        super.init()
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func connect() {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        listen()
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func call(method: String, params: [String: Any]) async throws -> Any? {
        let id = UUID().uuidString
        let frame: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
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
        delegate?.controlClientDidConnect(self)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        delegate?.controlClientDidDisconnect(self, error: nil)
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case encodeFailed
    case remote(code: String, message: String)
    public var description: String {
        switch self {
        case .encodeFailed: return "failed to encode RPC frame as JSON"
        case .remote(let c, let m): return "[\(c)] \(m)"
        }
    }
}

import Foundation

/// Receives `relay_request` events from the sidecar, dispatches each one to a
/// registered closure, and posts the result back as `relay.respond`. The
/// closure is responsible for executing whatever Mac-only operation the
/// remote client (iOS) wants done.
public actor RelayHandler {
    public typealias Handler = ([String: Any]) async throws -> Any?

    private var handlers: [String: Handler] = [:]
    private weak var client: ControlClient?
    private var inFlight: [String: String] = [:]   // relayId → method
    public var onActivityChange: (@Sendable (Int) -> Void)?

    public init() {}

    public func bind(client: ControlClient) {
        self.client = client
    }

    public func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    public func setActivityCallback(_ cb: @escaping @Sendable (Int) -> Void) {
        self.onActivityChange = cb
        cb(inFlight.count)
    }

    /// Called by the Mac's ControlClient delegate when a `relay_request`
    /// event arrives. Looks up the handler, runs it, sends the response
    /// (success or error) back via `relay.respond`.
    public func handle(_ event: AgentEventEnvelope) async {
        guard event.type == "relay_request" else { return }
        guard let relayId = event.payload["relayId"] as? String,
              let method = event.payload["method"] as? String
        else { return }
        let params = (event.payload["params"] as? [String: Any]) ?? [:]
        inFlight[relayId] = method
        onActivityChange?(inFlight.count)
        defer {
            inFlight.removeValue(forKey: relayId)
            onActivityChange?(inFlight.count)
        }
        let h = handlers[method]
        do {
            let result: Any?
            if let h {
                result = try await h(params)
            } else {
                throw RelayError.unknownMethod(method)
            }
            try? await client?.call(method: "relay.respond", params: [
                "relayId": relayId,
                "result": result ?? NSNull(),
            ])
        } catch {
            try? await client?.call(method: "relay.respond", params: [
                "relayId": relayId,
                "error": [
                    "code": "HANDLER_ERROR",
                    "message": String(describing: error),
                ],
            ])
        }
    }

    /// Once the Mac connects, claim the handler role. If the connection
    /// later drops, the sidecar's relay clears out automatically; we'll
    /// re-register on each onControlChanged.
    public func registerWithSidecar() async {
        guard let client else { return }
        do {
            _ = try await client.call(
                method: "client.register",
                params: ["role": "handler"]
            )
        } catch {
            FileHandle.standardError.write(
                "[relay] client.register failed: \(error)\n".data(using: .utf8) ?? Data()
            )
        }
    }
}

public enum RelayError: Error, CustomStringConvertible {
    case unknownMethod(String)
    public var description: String {
        switch self {
        case .unknownMethod(let m): return "unknown relayed method: \(m)"
        }
    }
}

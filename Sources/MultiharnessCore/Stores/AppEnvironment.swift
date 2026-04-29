import Foundation
import Observation

/// Top-level app dependencies. Constructed once at app start, passed via @Environment.
@MainActor
public final class AppEnvironment {
    public let persistence: PersistenceService
    public let keychain: KeychainService
    public let worktree: WorktreeService
    public let sidecar: SidecarManager
    public private(set) var control: ControlClient?
    /// Fired (with the new ControlClient) every time the sidecar (re)binds.
    /// Consumers — typically the AgentRegistryStore — should re-attach as
    /// the delegate and resync their per-workspace stores.
    public var onControlChanged: ((ControlClient) -> Void)?

    public init(dataDir: URL) throws {
        self.persistence = try PersistenceService(dataDir: dataDir)
        self.keychain = KeychainService()
        self.worktree = WorktreeService()
        self.sidecar = SidecarManager(dataDir: dataDir)
        self.sidecar.onPortBound = { [weak self] port in
            self?.rebindControl(port: port)
        }
    }

    public func attachControl(_ client: ControlClient) {
        self.control = client
    }

    private func rebindControl(port: Int) {
        // Tear down the dead client (if any), build a fresh one on the new port.
        control?.disconnect()
        let client = ControlClient(port: port)
        client.connect()
        self.control = client
        self.onControlChanged?(client)
    }
}

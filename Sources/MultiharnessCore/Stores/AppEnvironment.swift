import Foundation
import Observation

/// Top-level app dependencies. Constructed once at app start, passed via @Environment.
@MainActor
public final class AppEnvironment {
    public let persistence: PersistenceService
    public let keychain: KeychainService
    public let worktree: WorktreeService
    public let sidecar: SidecarManager
    public let remoteAccess: RemoteAccess
    public private(set) var control: ControlClient?
    /// Fired (with the new ControlClient) every time the sidecar (re)binds.
    /// Consumers — typically the AgentRegistryStore — should re-attach as
    /// the delegate and resync their per-workspace stores.
    public var onControlChanged: ((ControlClient) -> Void)?

    public init(dataDir: URL) throws {
        let p = try PersistenceService(dataDir: dataDir)
        let k = KeychainService()
        self.persistence = p
        self.keychain = k
        self.worktree = WorktreeService()
        self.sidecar = SidecarManager(dataDir: dataDir)
        self.remoteAccess = RemoteAccess(persistence: p, keychain: k)
        self.sidecar.onPortBound = { [weak self] port in
            self?.rebindControl(port: port)
            self?.remoteAccess.publicPort = port
            if self?.remoteAccess.enabled == true {
                self?.remoteAccess.startAdvertising(port: port)
            }
        }
        applyRemoteSettings()
    }

    /// Push the current `RemoteAccess` config into the SidecarManager.
    /// Caller is responsible for restarting the sidecar after toggling.
    public func applyRemoteSettings() {
        if remoteAccess.enabled {
            if remoteAccess.token == nil { remoteAccess.generateToken() }
            sidecar.bindAddress = "0.0.0.0"
            sidecar.authToken = remoteAccess.token
        } else {
            sidecar.bindAddress = "127.0.0.1"
            sidecar.authToken = nil
            remoteAccess.stopAdvertising()
        }
    }

    /// Toggle remote access and restart the sidecar so the bind/token take
    /// effect. Idempotent.
    public func setRemoteAccessEnabled(_ on: Bool) async {
        remoteAccess.enabled = on
        applyRemoteSettings()
        sidecar.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await sidecar.start()
        } catch {
            FileHandle.standardError.write(
                "[env] failed to restart sidecar: \(error)\n".data(using: .utf8) ?? Data()
            )
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

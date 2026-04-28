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

    public init(dataDir: URL) throws {
        self.persistence = try PersistenceService(dataDir: dataDir)
        self.keychain = KeychainService()
        self.worktree = WorktreeService()
        self.sidecar = SidecarManager(dataDir: dataDir)
    }

    public func attachControl(_ client: ControlClient) {
        self.control = client
    }
}

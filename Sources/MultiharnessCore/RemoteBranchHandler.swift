import Foundation
import MultiharnessClient

/// Testable pure logic for the `project.listBranches` relay handler.
/// The `RemoteHandlers` enum in the `Multiharness` executable target calls
/// into this type; keeping the logic here makes it reachable from
/// `MultiharnessCoreTests` without importing the executable.
public enum RemoteBranchHandler {

    // MARK: - project.listBranches

    /// Resolve params, delegate to `BranchListService`, and return a
    /// serialisable `[String: Any]` payload suitable for relay responses.
    @MainActor
    public static func handleListBranches(
        params: [String: Any],
        repoPath: String,
        service: BranchListService
    ) async throws -> Any? {
        guard let pidStr = params["projectId"] as? String,
              let pid = UUID(uuidString: pidStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        let refresh = (params["refresh"] as? Bool) ?? false
        let listing = try await service.list(
            projectId: pid, repoPath: repoPath, refresh: refresh
        )
        var dict: [String: Any] = [
            "origin": listing.origin as Any? ?? NSNull(),
            "local": listing.local,
            "originAvailable": listing.originAvailable,
            "fetchedAt": listing.fetchedAt,
        ]
        if let r = listing.originUnavailableReason {
            dict["originUnavailableReason"] = r.rawValue
        }
        return dict
    }
}

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

    // MARK: - project.update

    @MainActor
    public static func handleProjectUpdate(
        params: [String: Any],
        appStore: AppStore,
        branchListService: BranchListService
    ) async throws -> Any? {
        guard let pidStr = params["projectId"] as? String,
              let pid = UUID(uuidString: pidStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let raw = params["defaultBaseBranch"] as? String else {
            throw RemoteError.bad("defaultBaseBranch required")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteError.bad("defaultBaseBranch required and non-empty")
        }
        try appStore.setProjectDefaultBaseBranch(projectId: pid, value: trimmed)
        // No cache invalidation — branch listings don't depend on
        // defaultBaseBranch; the picker reads initialDefault from the
        // project record. The branchListService parameter is retained
        // in case future fields land that *do* depend on it.
        _ = branchListService
        return [
            "projectId": pidStr,
            "defaultBaseBranch": trimmed,
        ]
    }
}

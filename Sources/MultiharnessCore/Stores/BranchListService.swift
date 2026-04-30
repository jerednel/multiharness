import Foundation
import MultiharnessClient

/// In-memory per-project cache of branch listings. The cache lives for
/// the lifetime of the Mac app process. Pass `refresh: true` to bypass
/// the cache and re-run `git fetch origin`.
public actor BranchListService {
    private let worktree: WorktreeService
    private var cache: [UUID: BranchListing] = [:]
    private let fetchTimeoutSeconds: TimeInterval

    public init(
        worktree: WorktreeService = WorktreeService(),
        fetchTimeoutSeconds: TimeInterval = 5
    ) {
        self.worktree = worktree
        self.fetchTimeoutSeconds = fetchTimeoutSeconds
    }

    public func list(
        projectId: UUID,
        repoPath: String,
        refresh: Bool
    ) async throws -> BranchListing {
        if !refresh, let cached = cache[projectId] {
            return cached
        }
        let worktree = self.worktree
        let timeout = self.fetchTimeoutSeconds
        // Run blocking git work off the actor's thread so concurrent
        // callers don't serialize behind a slow fetch.
        let listing = try await Task.detached(priority: .utility) {
            try Self.buildListing(
                worktree: worktree,
                repoPath: repoPath,
                fetchTimeoutSeconds: timeout
            )
        }.value
        cache[projectId] = listing
        return listing
    }

    public func invalidate(projectId: UUID) {
        cache.removeValue(forKey: projectId)
    }

    private static func buildListing(
        worktree: WorktreeService,
        repoPath: String,
        fetchTimeoutSeconds: TimeInterval
    ) throws -> BranchListing {
        let hasOrigin = try worktree.hasOriginRemote(repoPath: repoPath)
        var originAvailable = false
        var reason: BranchListing.OriginUnavailableReason?
        var originBranches: [String]?

        if hasOrigin {
            // fetchOrigin or listOriginBranches may throw on flaky
            // networks, force-pushed refs, etc. — both map to .fetchFailed.
            do {
                try worktree.fetchOrigin(
                    repoPath: repoPath, timeoutSeconds: fetchTimeoutSeconds
                )
                originBranches = try worktree.listOriginBranches(repoPath: repoPath)
                originAvailable = true
            } catch {
                reason = .fetchFailed
            }
        } else {
            reason = .noRemote
        }

        let localBranches = try worktree.listBranches(repoPath: repoPath)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return BranchListing(
            origin: originBranches,
            local: localBranches,
            originAvailable: originAvailable,
            originUnavailableReason: originAvailable ? nil : reason,
            fetchedAt: now
        )
    }
}

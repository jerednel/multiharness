// Sources/MultiharnessCore/Stores/BranchListService.swift
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
        let listing = try buildListing(repoPath: repoPath)
        cache[projectId] = listing
        return listing
    }

    public func invalidate(projectId: UUID) {
        cache.removeValue(forKey: projectId)
    }

    private func buildListing(repoPath: String) throws -> BranchListing {
        let hasOrigin = (try? worktree.hasOriginRemote(repoPath: repoPath)) ?? false
        var originAvailable = false
        var reason: BranchListing.OriginUnavailableReason? = nil
        var originBranches: [String]? = nil

        if hasOrigin {
            do {
                try worktree.fetchOrigin(
                    repoPath: repoPath, timeoutSeconds: fetchTimeoutSeconds
                )
                let branches = try worktree.listOriginBranches(repoPath: repoPath)
                originBranches = branches
                originAvailable = true
            } catch {
                reason = .fetchFailed
            }
        } else {
            reason = .noRemote
        }

        let localBranches = (try? worktree.listBranches(repoPath: repoPath)) ?? []
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

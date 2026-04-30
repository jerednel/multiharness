import Foundation

/// Response payload for the `project.listBranches` RPC. Describes the
/// origin and local branches available in a project's git repository at
/// the time of the last fetch.
public struct BranchListing: Codable, Equatable, Sendable {
    public enum OriginUnavailableReason: String, Codable, Equatable, Sendable {
        case noRemote = "no_remote"
        case fetchFailed = "fetch_failed"
    }

    public var origin: [String]?
    public var local: [String]
    public var originAvailable: Bool
    /// Nil when `originAvailable` is true.
    public var originUnavailableReason: OriginUnavailableReason?
    /// Unix timestamp in milliseconds (ms since epoch).
    public var fetchedAt: Int64

    public init(
        origin: [String]?,
        local: [String],
        originAvailable: Bool,
        originUnavailableReason: OriginUnavailableReason? = nil,
        fetchedAt: Int64
    ) {
        self.origin = origin
        self.local = local
        self.originAvailable = originAvailable
        self.originUnavailableReason = originUnavailableReason
        self.fetchedAt = fetchedAt
    }
}

public enum BranchSide: String, Codable, Equatable, Sendable, CaseIterable {
    case origin
    case local
}

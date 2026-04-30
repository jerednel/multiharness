// Sources/MultiharnessClient/Models/BranchListing.swift
import Foundation

public struct BranchListing: Codable, Equatable, Sendable {
    public enum OriginUnavailableReason: String, Codable, Equatable, Sendable {
        case noRemote = "no_remote"
        case fetchFailed = "fetch_failed"
    }

    public var origin: [String]?
    public var local: [String]
    public var originAvailable: Bool
    public var originUnavailableReason: OriginUnavailableReason?
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

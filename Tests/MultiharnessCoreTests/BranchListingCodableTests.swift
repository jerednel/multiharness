// Tests/MultiharnessCoreTests/BranchListingCodableTests.swift
import XCTest
import MultiharnessClient

final class BranchListingCodableTests: XCTestCase {
    func testRoundTripWithOrigin() throws {
        let listing = BranchListing(
            origin: ["origin/main", "origin/develop"],
            local: ["main", "feature-x"],
            originAvailable: true,
            originUnavailableReason: nil,
            fetchedAt: 1_700_000_000_000
        )
        let data = try JSONEncoder().encode(listing)
        let decoded = try JSONDecoder().decode(BranchListing.self, from: data)
        XCTAssertEqual(decoded, listing)
    }

    func testRoundTripWithoutOrigin() throws {
        let listing = BranchListing(
            origin: nil,
            local: ["main"],
            originAvailable: false,
            originUnavailableReason: .noRemote,
            fetchedAt: 0
        )
        let data = try JSONEncoder().encode(listing)
        let decoded = try JSONDecoder().decode(BranchListing.self, from: data)
        XCTAssertEqual(decoded, listing)
    }

    func testReasonRawValues() {
        XCTAssertEqual(BranchListing.OriginUnavailableReason.noRemote.rawValue, "no_remote")
        XCTAssertEqual(BranchListing.OriginUnavailableReason.fetchFailed.rawValue, "fetch_failed")
    }
}

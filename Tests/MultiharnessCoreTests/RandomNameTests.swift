import XCTest
@testable import MultiharnessCore

final class RandomNameTests: XCTestCase {
    func testGenerateMatchesAdjectiveNounPattern() {
        for _ in 0..<50 {
            let name = RandomName.generate()
            let parts = name.split(separator: "-")
            XCTAssertEqual(parts.count, 2, "expected adjective-noun, got \(name)")
            XCTAssertTrue(RandomName.adjectives.contains(String(parts[0])))
            XCTAssertTrue(RandomName.nouns.contains(String(parts[1])))
        }
    }

    func testGenerateUniqueAvoidsExistingSet() {
        let existing: Set<String> = Set(RandomName.adjectives.flatMap { adj in
            RandomName.nouns.map { "\(adj)-\($0)" }
        })
        // Every adjective-noun is taken, so the function must fall through
        // to the numeric suffix path and still return something not in the set.
        let result = RandomName.generateUnique(avoiding: existing, retries: 3)
        XCTAssertFalse(existing.contains(result))
        XCTAssertTrue(result.contains("-2") || result.contains("-3") || result.contains("-4"))
    }

    func testGenerateUniqueOnEmptySetReturnsAdjectiveNoun() {
        let result = RandomName.generateUnique(avoiding: [])
        XCTAssertEqual(result.split(separator: "-").count, 2)
    }
}

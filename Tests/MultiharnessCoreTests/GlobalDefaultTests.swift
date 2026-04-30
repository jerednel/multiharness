import XCTest
@testable import MultiharnessCore

@MainActor
final class GlobalDefaultTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-globaldefault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore() throws -> (AppEnvironment, AppStore) {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let store = AppStore(env: env)
        return (env, store)
    }

    func testGlobalDefaultIsNilByDefault() throws {
        let (_, store) = try makeStore()
        XCTAssertNil(store.getGlobalDefault())
    }

    func testSetAndGetGlobalDefaultRoundtrips() throws {
        let (_, store) = try makeStore()
        let pid = UUID()
        try store.setGlobalDefault(providerId: pid, modelId: "claude-sonnet-4-6")
        let got = store.getGlobalDefault()
        XCTAssertEqual(got?.providerId, pid)
        XCTAssertEqual(got?.modelId, "claude-sonnet-4-6")
    }

    func testClearingGlobalDefault() throws {
        let (_, store) = try makeStore()
        try store.setGlobalDefault(providerId: UUID(), modelId: "m")
        try store.setGlobalDefault(providerId: nil, modelId: nil)
        XCTAssertNil(store.getGlobalDefault())
    }

    func testGlobalDefaultReturnsNilWhenOnlyHalfPresent() throws {
        let (env, store) = try makeStore()
        try env.persistence.setSetting("default_model_id", value: "m")
        XCTAssertNil(store.getGlobalDefault())
    }

    func testGlobalDefaultReturnsNilWhenProviderIdMalformed() throws {
        let (env, store) = try makeStore()
        try env.persistence.setSetting("default_provider_id", value: "not-a-uuid")
        try env.persistence.setSetting("default_model_id", value: "m")
        XCTAssertNil(store.getGlobalDefault())
    }
}

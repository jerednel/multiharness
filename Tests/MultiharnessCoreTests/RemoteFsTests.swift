import XCTest
@testable import MultiharnessCore

final class RemoteFsTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-fs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a tree:
    ///   root/
    ///     alpha/                    (plain dir)
    ///     beta/.git/                (git repo — .git is a directory)
    ///     gamma/.git                (worktree — .git is a *file*)
    ///     .hidden/                  (hidden dir)
    ///     readme.txt                (regular file)
    private func buildSampleTree() throws -> URL {
        let root = try tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("gamma"), withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(
            to: root.appendingPathComponent("gamma/.git"),
            atomically: true, encoding: .utf8
        )
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "hello".write(
            to: root.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        return root
    }

    func testListsOnlyDirectoriesExcludingHidden() throws {
        let root = try buildSampleTree()
        let listing = try RemoteFs.list(path: root.path)
        let names = listing.entries.map(\.name)
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    func testIsGitRepoDetectsDirAndFile() throws {
        let root = try buildSampleTree()
        let listing = try RemoteFs.list(path: root.path)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["alpha"]?.isGitRepo, false)
        XCTAssertEqual(byName["beta"]?.isGitRepo, true,  ".git directory should count")
        XCTAssertEqual(byName["gamma"]?.isGitRepo, true, ".git file (worktree) should count")
    }

    func testEntriesSortedCaseInsensitively() throws {
        let root = try tempDir()
        let fm = FileManager.default
        for n in ["Banana", "apple", "Cherry"] {
            try fm.createDirectory(at: root.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        let listing = try RemoteFs.list(path: root.path)
        XCTAssertEqual(listing.entries.map(\.name), ["apple", "Banana", "Cherry"])
    }

    func testParentIsNilAtFilesystemRoot() throws {
        let listing = try RemoteFs.list(path: "/")
        XCTAssertNil(listing.parent)
        XCTAssertEqual(listing.path, "/")
    }

    func testParentIsCanonicalForNestedPath() throws {
        let root = try buildSampleTree()
        let listing = try RemoteFs.list(path: root.path)
        XCTAssertEqual(listing.parent, root.deletingLastPathComponent().path)
    }

    func testThrowsForMissingPath() {
        let bogus = "/tmp/mh-does-not-exist-\(UUID().uuidString)"
        XCTAssertThrowsError(try RemoteFs.list(path: bogus))
    }

    func testThrowsForRegularFile() throws {
        let root = try tempDir()
        let file = root.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RemoteFs.list(path: file.path))
    }
}

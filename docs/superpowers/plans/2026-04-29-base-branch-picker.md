# Base Branch Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-text "Base branch" field on the workspace-create sheet (Mac + iOS) with a picker (Origin/Local toggle, search, branch list) sourced from real git refs. Add a Mac-only project setting for the per-project default base branch using the same picker.

**Architecture:** Add origin-branch enumeration + best-effort `git fetch` to `WorktreeService`, wrap them in a Mac-side `BranchListService` with an in-memory per-project cache. Expose two new Mac-only RPC methods (`project.listBranches`, `project.update`) registered through the existing relay so iOS reaches them transparently. Build a shared SwiftUI `BranchPicker` view in `MultiharnessClient` that takes an async fetcher closure, so Mac wires it directly to the local service and iOS wires it through `ConnectionStore`. No new SQLite migrations — `projects.default_base_branch` already exists.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, git subprocess via `Process`, JSON-over-WebSocket RPC (`URLSessionWebSocketTask`), SQLite via existing `AppStore.persistence` layer.

---

## File Structure

**Create:**
- `Sources/MultiharnessClient/Models/BranchListing.swift` — `BranchListing`, `BranchSide` shared model types.
- `Sources/MultiharnessClient/Views/BranchPicker.swift` — shared SwiftUI picker view.
- `Sources/MultiharnessCore/Stores/BranchListService.swift` — Mac-side per-project cache wrapping `WorktreeService`.
- `Sources/Multiharness/Views/ProjectSettingsView.swift` — Mac-only sheet for editing the project default.
- `Tests/MultiharnessCoreTests/WorktreeServiceBranchTests.swift` — fixture-repo tests for new git methods.
- `Tests/MultiharnessCoreTests/BranchListServiceTests.swift` — cache + behavior tests.
- `Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift` — handler dispatch tests for the two new methods.

**Modify:**
- `Sources/MultiharnessCore/Worktree/WorktreeService.swift` — add `listOriginBranches`, `hasOriginRemote`, `fetchOrigin` with timeout.
- `Sources/MultiharnessCore/Stores/AppStore.swift` — add `setProjectDefaultBaseBranch`.
- `Sources/Multiharness/RemoteHandlers.swift` — register `project.listBranches`, `project.update`; add private handlers.
- `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — add `listBranches`, `updateProject`.
- `Sources/Multiharness/Views/Sheets.swift` — replace `TextField("Base branch", ...)` with `BranchPicker` in `NewWorkspaceSheet`.
- `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` — same replacement in iOS `NewWorkspaceSheet`.
- One project list/detail file in `Sources/Multiharness/Views/` — add the entry-point button to `ProjectSettingsView`. Exact file determined in Task 13.

---

## Task 1: Shared model types in `MultiharnessClient`

**Files:**
- Create: `Sources/MultiharnessClient/Models/BranchListing.swift`
- Test: `Tests/MultiharnessCoreTests/BranchListingCodableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BranchListingCodableTests`
Expected: FAIL — `cannot find 'BranchListing' in scope`.

- [ ] **Step 3: Implement the model**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BranchListingCodableTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessClient/Models/BranchListing.swift \
        Tests/MultiharnessCoreTests/BranchListingCodableTests.swift
git commit -m "feat: add BranchListing + BranchSide shared model"
```

---

## Task 2: Extend `WorktreeService` with origin-branch enumeration

**Files:**
- Modify: `Sources/MultiharnessCore/Worktree/WorktreeService.swift` (add three methods after the existing `listBranches` at line 47-51)
- Test: `Tests/MultiharnessCoreTests/WorktreeServiceBranchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MultiharnessCoreTests/WorktreeServiceBranchTests.swift
import XCTest
@testable import MultiharnessCore

final class WorktreeServiceBranchTests: XCTestCase {
    var repoDir: URL!
    var remoteDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        // Bare "remote" repo
        remoteDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branch-remote-\(UUID().uuidString).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: remoteDir.path, args: ["init", "--bare", "-q", "-b", "main"])

        // Working repo, cloned from the bare remote
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try svc.runGit(at: parent.path, args: [
            "clone", "-q", remoteDir.path, "work",
        ])
        repoDir = parent.appendingPathComponent("work", isDirectory: true)
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "test@test"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "Test"])
        try "hello\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
        _ = try svc.runGit(at: repoDir.path, args: ["push", "-q", "origin", "main"])
        // Add a second remote branch
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "develop"])
        _ = try svc.runGit(at: repoDir.path, args: ["push", "-q", "-u", "origin", "develop"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: remoteDir)
    }

    func testHasOriginRemote() throws {
        XCTAssertTrue(try svc.hasOriginRemote(repoPath: repoDir.path))
    }

    func testHasOriginRemoteFalseWhenAbsent() throws {
        let solo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-solo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: solo, withIntermediateDirectories: true)
        _ = try svc.runGit(at: solo.path, args: ["init", "-q", "-b", "main"])
        defer { try? FileManager.default.removeItem(at: solo) }
        XCTAssertFalse(try svc.hasOriginRemote(repoPath: solo.path))
    }

    func testListOriginBranchesReturnsRemoteRefs() throws {
        let branches = try svc.listOriginBranches(repoPath: repoDir.path)
        XCTAssertTrue(branches.contains("origin/main"))
        XCTAssertTrue(branches.contains("origin/develop"))
        XCTAssertFalse(branches.contains(where: { $0.contains("HEAD") }))
    }

    func testFetchOriginSucceedsWhenReachable() throws {
        XCTAssertNoThrow(try svc.fetchOrigin(repoPath: repoDir.path, timeoutSeconds: 5))
    }

    func testFetchOriginThrowsOnUnreachableRemote() throws {
        // Repoint origin at a path that doesn't exist
        _ = try svc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "/nonexistent/path/repo.git",
        ])
        XCTAssertThrowsError(try svc.fetchOrigin(repoPath: repoDir.path, timeoutSeconds: 5))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorktreeServiceBranchTests`
Expected: FAIL — `value of type 'WorktreeService' has no member 'hasOriginRemote'`.

- [ ] **Step 3: Add the three methods to `WorktreeService`**

Insert immediately after the existing `listBranches(repoPath:)` (line 47-51) in `Sources/MultiharnessCore/Worktree/WorktreeService.swift`:

```swift
    public func hasOriginRemote(repoPath: String) throws -> Bool {
        let out = try runGit(at: repoPath, args: ["remote"])
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .contains("origin")
    }

    public func listOriginBranches(repoPath: String) throws -> [String] {
        let out = try runGit(at: repoPath, args: [
            "for-each-ref", "refs/remotes/origin", "--format=%(refname:short)",
        ])
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "origin/HEAD" }
    }

    /// Best-effort `git fetch origin` with a timeout. Throws on non-zero
    /// exit or when the timeout elapses.
    public func fetchOrigin(repoPath: String, timeoutSeconds: TimeInterval) throws {
        let p = Process()
        p.launchPath = "/usr/bin/git"
        p.arguments = ["fetch", "origin"]
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning {
            if Date() >= deadline {
                p.terminate()
                _ = p.waitUntilExit()
                throw WorktreeError.gitFailed(
                    args: ["fetch", "origin"],
                    exitCode: -1,
                    stderr: "fetch timed out after \(Int(timeoutSeconds))s"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw WorktreeError.gitFailed(
                args: ["fetch", "origin"],
                exitCode: p.terminationStatus,
                stderr: stderr
            )
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorktreeServiceBranchTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Worktree/WorktreeService.swift \
        Tests/MultiharnessCoreTests/WorktreeServiceBranchTests.swift
git commit -m "feat(core): add origin-branch enumeration + fetchOrigin to WorktreeService"
```

---

## Task 3: `BranchListService` with per-project cache

**Files:**
- Create: `Sources/MultiharnessCore/Stores/BranchListService.swift`
- Test: `Tests/MultiharnessCoreTests/BranchListServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MultiharnessCoreTests/BranchListServiceTests.swift
import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class BranchListServiceTests: XCTestCase {
    var repoDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        // Standalone repo (no remote) for cache tests.
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branchsvc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: repoDir.path, args: ["init", "-q", "-b", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "test@test"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "Test"])
        try "hello\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir)
    }

    func testListReportsNoRemoteWhenAbsent() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        let listing = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        XCTAssertFalse(listing.originAvailable)
        XCTAssertEqual(listing.originUnavailableReason, .noRemote)
        XCTAssertNil(listing.origin)
        XCTAssertTrue(listing.local.contains("main"))
    }

    func testCacheReturnedOnSecondCall() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        let first = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        // Add a new local branch — without `refresh`, the service should
        // return the cached listing that doesn't include it.
        _ = try svc.runGit(at: repoDir.path, args: ["branch", "topic"])
        let second = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        XCTAssertEqual(first.local, second.local)
        XCTAssertFalse(second.local.contains("topic"))
    }

    func testRefreshBypassesCache() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        _ = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        _ = try svc.runGit(at: repoDir.path, args: ["branch", "topic"])
        let refreshed = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: true)
        XCTAssertTrue(refreshed.local.contains("topic"))
    }

    func testFetchFailureMarksOriginUnavailable() async throws {
        // Add a broken origin remote
        _ = try svc.runGit(at: repoDir.path, args: [
            "remote", "add", "origin", "/nonexistent/path/repo.git",
        ])
        let service = BranchListService(worktree: svc)
        let listing = try await service.list(
            projectId: UUID(), repoPath: repoDir.path, refresh: true
        )
        XCTAssertFalse(listing.originAvailable)
        XCTAssertEqual(listing.originUnavailableReason, .fetchFailed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BranchListServiceTests`
Expected: FAIL — `cannot find 'BranchListService' in scope`.

- [ ] **Step 3: Implement the service**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BranchListServiceTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Stores/BranchListService.swift \
        Tests/MultiharnessCoreTests/BranchListServiceTests.swift
git commit -m "feat(core): add BranchListService with per-project cache"
```

---

## Task 4: `project.listBranches` RPC handler

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift` (extend `register` block + add private handler)
- Modify: One file in `Sources/Multiharness/` that wires up `RemoteHandlers.register` so the `BranchListService` instance is injected (most likely `App.swift` or wherever `RemoteHandlers.register(...)` is called).
- Test: `Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift`

- [ ] **Step 1: Locate the call site that calls `RemoteHandlers.register`**

Run: `grep -n "RemoteHandlers.register" Sources/Multiharness/*.swift`
Expected: one or two matches in the app entry / startup code.

Note the file and line. The register call signature needs a new `branchListService:` parameter added in step 3.

- [ ] **Step 2: Write the failing test**

The test exercises the handler's logic directly (constructing a fixture repo + calling the handler closure).

```swift
// Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift
import XCTest
@testable import MultiharnessCore
import MultiharnessClient

@MainActor
final class RemoteHandlersBranchTests: XCTestCase {
    var repoDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-rh-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: repoDir.path, args: ["init", "-q", "-b", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "t@t"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "T"])
        try "x\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir)
    }

    /// The handler logic is exposed for direct testing via
    /// `RemoteHandlers.handleListBranches(...)`.
    func testListBranchesNoRemote() async throws {
        let projectId = UUID()
        let service = BranchListService(worktree: svc)
        let result = try await RemoteHandlers.handleListBranches(
            params: [
                "projectId": projectId.uuidString,
                "refresh": false,
            ],
            repoPath: repoDir.path,
            service: service
        ) as? [String: Any]
        XCTAssertEqual(result?["originAvailable"] as? Bool, false)
        XCTAssertEqual(result?["originUnavailableReason"] as? String, "no_remote")
        XCTAssertTrue(((result?["local"] as? [String]) ?? []).contains("main"))
    }

    func testListBranchesRequiresProjectId() async {
        let service = BranchListService(worktree: svc)
        do {
            _ = try await RemoteHandlers.handleListBranches(
                params: [:],
                repoPath: repoDir.path,
                service: service
            )
            XCTFail("expected error")
        } catch {
            // expected
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter RemoteHandlersBranchTests`
Expected: FAIL — `RemoteHandlers` has no `handleListBranches` member, or `RemoteHandlers` is internal.

- [ ] **Step 4: Add the handler + register it**

In `Sources/Multiharness/RemoteHandlers.swift`:

a) Inside the `register(...)` function signature, add a `branchListService: BranchListService` parameter:

```swift
    static func register(
        on relay: RelayHandler,
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        branchListService: BranchListService
    ) async {
```

b) Inside the `register` body, add:

```swift
        await relay.register(method: "project.listBranches") { params in
            guard let pidStr = params["projectId"] as? String,
                  let pid = UUID(uuidString: pidStr),
                  let project = appStore.projects.first(where: { $0.id == pid }) else {
                throw RemoteError.bad("projectId required (UUID of known project)")
            }
            return try await Self.handleListBranches(
                params: params,
                repoPath: project.repoPath,
                service: branchListService
            )
        }
```

c) Add the static helper (so tests can call it directly without spinning up a relay):

```swift
    // MARK: - project.listBranches

    @MainActor
    static func handleListBranches(
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
```

d) Update the call site found in step 1 to pass `branchListService:`. Construct one shared instance there:

```swift
let branchListService = BranchListService()
await RemoteHandlers.register(
    on: relay,
    env: env,
    appStore: appStore,
    workspaceStore: workspaceStore,
    branchListService: branchListService
)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RemoteHandlersBranchTests`
Expected: 2 tests pass.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all tests pass (no regressions in existing handler tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/Multiharness/RemoteHandlers.swift \
        Sources/Multiharness/*.swift \
        Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift
git commit -m "feat: add project.listBranches RPC handler"
```

---

## Task 5: iOS `ConnectionStore.listBranches`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` (insert near other relayed mutations, ~line 195 alongside `createProject`)

- [ ] **Step 1: Add the method**

Insert in `ConnectionStore.swift`, immediately after the existing `fetchModels` method (around line 190):

```swift
    public func listBranches(
        projectId: String,
        refresh: Bool = false
    ) async throws -> BranchListing {
        var params: [String: Any] = ["projectId": projectId]
        if refresh { params["refresh"] = true }
        let result = try await client.call(
            method: "project.listBranches", params: params
        ) as? [String: Any] ?? [:]

        let originRaw = result["origin"]
        let origin: [String]? = (originRaw is NSNull) ? nil : (originRaw as? [String])
        let local = (result["local"] as? [String]) ?? []
        let available = (result["originAvailable"] as? Bool) ?? false
        let reasonRaw = result["originUnavailableReason"] as? String
        let reason = reasonRaw.flatMap(BranchListing.OriginUnavailableReason.init(rawValue:))
        let fetchedAt = (result["fetchedAt"] as? Int64)
            ?? Int64((result["fetchedAt"] as? Double) ?? 0)
        return BranchListing(
            origin: origin,
            local: local,
            originAvailable: available,
            originUnavailableReason: reason,
            fetchedAt: fetchedAt
        )
    }
```

- [ ] **Step 2: Build iOS to confirm it compiles**

Run: `bash scripts/build-ios.sh`
Expected: build succeeds (no test step on iOS — manually verified once UI lands in Task 11).

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "feat(ios): add ConnectionStore.listBranches RPC client"
```

---

## Task 6: `AppStore.setProjectDefaultBaseBranch`

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/AppStore.swift` (add method near existing `setProjectDefaultBuildMode`)
- Test: `Tests/MultiharnessCoreTests/PersistenceTests.swift` (add to existing file)

- [ ] **Step 1: Locate the existing `setProjectDefaultBuildMode` for reference**

Run: `grep -n "setProjectDefaultBuildMode" Sources/MultiharnessCore/Stores/AppStore.swift`
Note the surrounding pattern (it both writes to SQLite and updates the in-memory `projects` array).

- [ ] **Step 2: Write the failing test**

In `Tests/MultiharnessCoreTests/PersistenceTests.swift`, add a new test method (matching the file's existing patterns; if the file uses a shared `AppStore` setup, reuse it):

```swift
    func testSetProjectDefaultBaseBranchPersists() throws {
        let env = try AppEnvironment.makeEphemeral()  // or whatever pattern the file uses
        let store = AppStore(env: env)
        try store.loadAll()
        store.addProject(
            name: "Test",
            repoURL: URL(fileURLWithPath: "/tmp/test-repo"),
            defaultBaseBranch: "main"
        )
        guard let project = store.projects.first else {
            return XCTFail("expected project after addProject")
        }

        try store.setProjectDefaultBaseBranch(projectId: project.id, value: "origin/main")
        XCTAssertEqual(store.projects.first?.defaultBaseBranch, "origin/main")

        // Reload and assert persistence survives.
        let reload = AppStore(env: env)
        try reload.loadAll()
        XCTAssertEqual(reload.projects.first?.defaultBaseBranch, "origin/main")
    }
```

If `AppEnvironment.makeEphemeral` doesn't exist, follow whatever fixture pattern `PersistenceTests.swift` already uses (look for the existing `addProject` test).

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PersistenceTests/testSetProjectDefaultBaseBranchPersists`
Expected: FAIL — `setProjectDefaultBaseBranch` doesn't exist.

- [ ] **Step 4: Implement the method**

Add to `Sources/MultiharnessCore/Stores/AppStore.swift`, near the existing `setProjectDefaultBuildMode`:

```swift
    public func setProjectDefaultBaseBranch(projectId: UUID, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AppStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "defaultBaseBranch cannot be empty"
            ])
        }
        try persistence.updateProjectDefaultBaseBranch(projectId: projectId, value: trimmed)
        if let idx = projects.firstIndex(where: { $0.id == projectId }) {
            projects[idx].defaultBaseBranch = trimmed
        }
    }
```

If `persistence.updateProjectDefaultBaseBranch` doesn't exist yet, add it to whatever persistence layer holds project SQL writes (find by grepping for `update_project` / `UPDATE projects` in `Sources/MultiharnessCore/Persistence/`):

```swift
    public func updateProjectDefaultBaseBranch(projectId: UUID, value: String) throws {
        let sql = "UPDATE projects SET default_base_branch = ? WHERE id = ?"
        try db.execute(sql, params: [value, projectId.uuidString])
    }
```

(Adapt to the existing persistence layer's exact API — match the style of the existing `updateProjectDefaultBuildMode` if there is one.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PersistenceTests/testSetProjectDefaultBaseBranchPersists`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MultiharnessCore/Stores/AppStore.swift \
        Sources/MultiharnessCore/Persistence/*.swift \
        Tests/MultiharnessCoreTests/PersistenceTests.swift
git commit -m "feat(core): AppStore.setProjectDefaultBaseBranch + persistence"
```

---

## Task 7: `project.update` RPC handler

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift`
- Test: extend `Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `RemoteHandlersBranchTests.swift`:

```swift
    func testProjectUpdateRequiresProjectId() async {
        do {
            _ = try await RemoteHandlers.handleProjectUpdate(
                params: ["defaultBaseBranch": "origin/main"],
                appStore: nil
            )
            XCTFail("expected error")
        } catch {
            // expected — projectId required
        }
    }

    func testProjectUpdateRequiresDefaultBaseBranch() async {
        do {
            _ = try await RemoteHandlers.handleProjectUpdate(
                params: ["projectId": UUID().uuidString],
                appStore: nil
            )
            XCTFail("expected error")
        } catch {
            // expected — at least one editable field required
        }
    }
```

(Note: the `appStore` argument here is intentionally `nil` for the validation-only paths. The full happy-path test goes through the registered relay handler in a manual smoke test.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteHandlersBranchTests`
Expected: FAIL — `handleProjectUpdate` not found.

- [ ] **Step 3: Add the handler + register it**

In `Sources/Multiharness/RemoteHandlers.swift`, inside the `register(...)` body:

```swift
        await relay.register(method: "project.update") { params in
            try await Self.handleProjectUpdate(
                params: params,
                appStore: appStore
            )
        }
```

Add the helper:

```swift
    // MARK: - project.update

    @MainActor
    static func handleProjectUpdate(
        params: [String: Any],
        appStore: AppStore?
    ) async throws -> Any? {
        guard let pidStr = params["projectId"] as? String,
              let pid = UUID(uuidString: pidStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let defaultBaseBranch = params["defaultBaseBranch"] as? String,
              !defaultBaseBranch.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemoteError.bad("defaultBaseBranch required and non-empty")
        }
        guard let store = appStore else {
            throw RemoteError.bad("appStore unavailable")
        }
        try store.setProjectDefaultBaseBranch(
            projectId: pid, value: defaultBaseBranch
        )
        return [
            "projectId": pidStr,
            "defaultBaseBranch": defaultBaseBranch,
        ]
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RemoteHandlersBranchTests`
Expected: all tests in the file pass.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Multiharness/RemoteHandlers.swift \
        Tests/MultiharnessCoreTests/RemoteHandlersBranchTests.swift
git commit -m "feat: add project.update RPC handler"
```

---

## Task 8: iOS `ConnectionStore.updateProject`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`

- [ ] **Step 1: Add the method**

Insert immediately after `createProject` (around line 210) in `ConnectionStore.swift`:

```swift
    public func updateProject(
        projectId: String,
        defaultBaseBranch: String
    ) async throws {
        _ = try await client.call(
            method: "project.update",
            params: [
                "projectId": projectId,
                "defaultBaseBranch": defaultBaseBranch,
            ]
        )
        await refreshWorkspaces()
    }
```

- [ ] **Step 2: Build iOS to confirm it compiles**

Run: `bash scripts/build-ios.sh`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "feat(ios): add ConnectionStore.updateProject RPC client"
```

---

## Task 9: `BranchPicker` shared SwiftUI view

**Files:**
- Create: `Sources/MultiharnessClient/Views/BranchPicker.swift`

This view is consumed by Mac (Task 10), iOS (Task 11), and Mac project settings (Task 12). No XCTest — manually verified through the consuming sheets in subsequent tasks.

- [ ] **Step 1: Implement the view**

```swift
// Sources/MultiharnessClient/Views/BranchPicker.swift
import SwiftUI

/// SwiftUI picker for selecting a base branch ref. Caller provides:
///  - `fetcher` — async closure returning the current `BranchListing`. The
///    `refresh` flag lets the picker request a fresh listing when the user
///    taps the refresh button.
///  - `selection` — binding to the chosen ref string (e.g. "origin/main"
///    or "main"). The picker writes the fully-qualified ref including
///    the "origin/" prefix on the Origin side.
public struct BranchPicker: View {
    public typealias Fetcher = @Sendable (_ refresh: Bool) async throws -> BranchListing

    @Binding var selection: String
    let initialDefault: String?
    let fetcher: Fetcher

    @State private var listing: BranchListing?
    @State private var loading = false
    @State private var loadError: String?
    @State private var side: BranchSide = .local
    @State private var query: String = ""

    public init(
        selection: Binding<String>,
        initialDefault: String?,
        fetcher: @escaping Fetcher
    ) {
        self._selection = selection
        self.initialDefault = initialDefault
        self.fetcher = fetcher
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Source", selection: $side) {
                    Text("Origin").tag(BranchSide.origin)
                        .disabled(!originUsable)
                    Text("Local").tag(BranchSide.local)
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Re-fetch branches from origin")
            }

            if let caption = originDisabledCaption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }

            TextField("Filter branches…", text: $query)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading && listing == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading branches…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let err = loadError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(err).font(.caption).foregroundStyle(.red)
                        Button("Retry") { Task { await load(refresh: false) } }
                    }
                } else if filteredBranches.isEmpty {
                    Text(emptyStateText).font(.caption).foregroundStyle(.secondary)
                } else {
                    List(filteredBranches, id: \.self, selection: $selection) { branch in
                        Text(branch).tag(branch)
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                }
            }
        }
        .task { await load(refresh: false) }
        .onChange(of: side) { _, _ in
            // Don't drop the user's existing selection if it's still valid
            // on the new side; otherwise pick the first match.
            if !filteredBranches.contains(selection),
               let first = filteredBranches.first {
                selection = first
            }
        }
    }

    private var originUsable: Bool {
        listing?.originAvailable == true && (listing?.origin?.isEmpty == false)
    }

    private var originDisabledCaption: String? {
        guard !originUsable else { return nil }
        guard let listing else { return nil }
        if !listing.originAvailable {
            switch listing.originUnavailableReason {
            case .noRemote: return "No `origin` remote configured"
            case .fetchFailed: return "Failed to reach `origin`"
            case .none: return nil
            }
        }
        if listing.origin?.isEmpty == true { return "No remote branches" }
        return nil
    }

    private var filteredBranches: [String] {
        let pool: [String]
        switch side {
        case .origin: pool = listing?.origin ?? []
        case .local:  pool = listing?.local ?? []
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var emptyStateText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            switch side {
            case .origin: return "No remote branches"
            case .local:  return "No local branches"
            }
        }
        return "No branches match \"\(q)\""
    }

    @MainActor
    private func load(refresh: Bool) async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let result = try await fetcher(refresh)
            listing = result
            applyInitialSelection()
        } catch {
            loadError = "Couldn't list branches: \(error)"
        }
    }

    private func applyInitialSelection() {
        guard let listing else { return }
        let preferred = (initialDefault?.isEmpty == false) ? initialDefault! : ""
        let preferOrigin = preferred.hasPrefix("origin/")

        // Choose initial side. If preferred is an origin ref but origin
        // isn't usable, fall back to local.
        if preferOrigin && originUsable {
            side = .origin
        } else {
            side = .local
        }

        // Apply selection. Prefer the saved default if present in the
        // selected side's list; otherwise first available.
        let pool: [String] = side == .origin ? (listing.origin ?? []) : listing.local
        if !preferred.isEmpty, pool.contains(preferred) {
            selection = preferred
        } else if let first = pool.first {
            selection = first
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MultiharnessClient/Views/BranchPicker.swift
git commit -m "feat: add shared BranchPicker SwiftUI view"
```

---

## Task 10: Mac — replace text field in `NewWorkspaceSheet`

**Files:**
- Modify: `Sources/Multiharness/Views/Sheets.swift` (line 97 area)

- [ ] **Step 1: Locate `BranchListService` injection**

The Mac UI calls Mac stores directly (it does not round-trip through the relay). The `NewWorkspaceSheet` needs access to the same `BranchListService` instance constructed in Task 4. Add a property and pass it in from the sheet's caller. Look for where `NewWorkspaceSheet(...)` is instantiated (likely `RootView.swift` or `MainContentView.swift`); pass the service in via environment object, or thread it through an explicit init parameter.

For consistency with how `appStore`/`workspaceStore` are already passed in `Sheets.swift:80`, use an explicit parameter.

- [ ] **Step 2: Modify `NewWorkspaceSheet` to use `BranchPicker`**

In `Sources/Multiharness/Views/Sheets.swift`, in `NewWorkspaceSheet`:

a) Add a new property near the other store properties (around line 78):

```swift
    let branchListService: BranchListService
```

b) Replace the existing line 97:

```swift
                    TextField("Base branch", text: $baseBranch, prompt: Text(proj.defaultBaseBranch))
```

with:

```swift
                    LabeledContent("Base branch") {
                        BranchPicker(
                            selection: $baseBranch,
                            initialDefault: proj.defaultBaseBranch
                        ) { refresh in
                            try await branchListService.list(
                                projectId: proj.id,
                                repoPath: proj.repoPath,
                                refresh: refresh
                            )
                        }
                    }
```

c) Remove the now-unused `.onAppear` line that pre-fills `baseBranch = proj.defaultBaseBranch` (lines 139-141) — `BranchPicker` handles initial selection itself. Keep the other `.onAppear` initializers (`providerId`, `buildMode`).

d) Update every call site that constructs `NewWorkspaceSheet(...)` to pass the new `branchListService:` argument. Find call sites with: `grep -rn "NewWorkspaceSheet(" Sources/Multiharness/`. Each call site needs the service threaded through (typically as a property of the parent view that also holds `appStore`).

- [ ] **Step 3: Build the Mac app and smoke-test manually**

Run: `bash scripts/build-app.sh && open dist/Multiharness.app`
Expected: build succeeds, app launches, opening "New workspace" shows the picker.

Smoke checks:
- Picker loads with a spinner, then populates with the project's branches.
- Origin segment greyed when the repo has no `origin` remote.
- Search field filters the list.
- ↻ button re-fetches.
- "Create" disabled until a branch is selected; creates a worktree on that ref.

- [ ] **Step 4: Commit**

```bash
git add Sources/Multiharness/Views/Sheets.swift Sources/Multiharness/Views/*.swift
git commit -m "feat(mac): use BranchPicker in NewWorkspaceSheet"
```

---

## Task 11: iOS — replace text field in `NewWorkspaceSheet`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` (line 33 area)

- [ ] **Step 1: Modify the iOS sheet**

In `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`, locate the `Section("Basics")` block (lines 26-34). Replace:

```swift
                    TextField("Base branch (e.g. main)", text: $baseBranch)
```

with:

```swift
                    if !projectId.isEmpty {
                        let proj = connection.projects.first(where: { $0.id == projectId })
                        LabeledContent("Base branch") {
                            BranchPicker(
                                selection: $baseBranch,
                                initialDefault: proj?.defaultBaseBranch
                            ) { refresh in
                                try await connection.listBranches(
                                    projectId: projectId, refresh: refresh
                                )
                            }
                            .id(projectId)  // force re-init when project changes
                        }
                    }
```

Note: `MultiharnessClient` must be imported (already is — line 2).

- [ ] **Step 2: Adjust selection reset on project change**

In the existing `.onChange(of: projectId)` handler (around line 123), reset `baseBranch` so the picker re-pulls the new project's listing:

```swift
        .onChange(of: projectId) { _, _ in
            baseBranch = ""
            buildMode = effectiveProjectDefault()
            makeProjectDefault = false
        }
```

- [ ] **Step 3: Build iOS and smoke-test**

Run: `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`
Expected: build succeeds, simulator launches, "New workspace" sheet shows the picker.

Smoke checks (against a paired Mac with at least one project):
- Picker loads and populates from the relay.
- Origin segment greys when the project has no remote.
- Filter and ↻ behave identically to Mac.
- Workspace creation succeeds with the chosen ref.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/CreateSheets.swift
git commit -m "feat(ios): use BranchPicker in NewWorkspaceSheet"
```

---

## Task 12: Mac — `ProjectSettingsView`

**Files:**
- Create: `Sources/Multiharness/Views/ProjectSettingsView.swift`

- [ ] **Step 1: Implement the view**

```swift
// Sources/Multiharness/Views/ProjectSettingsView.swift
import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ProjectSettingsView: View {
    @ObservedObject var appStore: AppStore
    let branchListService: BranchListService
    let project: Project
    @Binding var isPresented: Bool

    @State private var defaultBaseBranch: String
    @State private var error: String?
    @State private var saving = false

    init(
        appStore: AppStore,
        branchListService: BranchListService,
        project: Project,
        isPresented: Binding<Bool>
    ) {
        self.appStore = appStore
        self.branchListService = branchListService
        self.project = project
        self._isPresented = isPresented
        self._defaultBaseBranch = State(initialValue: project.defaultBaseBranch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project settings — \(project.name)").font(.title2).bold()
            Form {
                LabeledContent("Default base branch") {
                    BranchPicker(
                        selection: $defaultBaseBranch,
                        initialDefault: project.defaultBaseBranch
                    ) { refresh in
                        try await branchListService.list(
                            projectId: project.id,
                            repoPath: project.repoPath,
                            refresh: refresh
                        )
                    }
                }
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || defaultBaseBranch.isEmpty)
            }
        }
        .padding(24).frame(width: 600, height: 460)
    }

    @MainActor
    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try appStore.setProjectDefaultBaseBranch(
                projectId: project.id, value: defaultBaseBranch
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: build succeeds. (No call sites yet — Task 13 wires the entry point.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Multiharness/Views/ProjectSettingsView.swift
git commit -m "feat(mac): add ProjectSettingsView with BranchPicker"
```

---

## Task 13: Mac — entry point to `ProjectSettingsView`

**Files:**
- Modify: a project list/sidebar view in `Sources/Multiharness/Views/`. Find the right file in step 1.

- [ ] **Step 1: Locate the project list / sidebar UI**

Run: `grep -rn "appStore.projects" Sources/Multiharness/Views/`
Identify the view that renders the project list (e.g., `Sidebar.swift` or `ProjectListView.swift`). The entry point fits naturally as a context-menu item on each project row, matching whatever per-project actions already exist there.

- [ ] **Step 2: Add the menu/button + sheet presentation**

In the identified view, add `@State private var settingsForProject: Project?` and a `.contextMenu` (or button, matching the file's convention) that sets it:

```swift
.contextMenu {
    Button("Project settings…") {
        settingsForProject = project
    }
    // ...keep any other existing items
}
```

Add a `.sheet(item: $settingsForProject)` at the same level the file already uses for sheets:

```swift
.sheet(item: $settingsForProject) { proj in
    ProjectSettingsView(
        appStore: appStore,
        branchListService: branchListService,
        project: proj,
        isPresented: Binding(
            get: { settingsForProject != nil },
            set: { if !$0 { settingsForProject = nil } }
        )
    )
}
```

`Project` must conform to `Identifiable` for `.sheet(item:)` — it likely already does via its `id: UUID`. If not, add the conformance in `MultiharnessClient/Models/Models.swift`.

The view also needs `branchListService` threaded in. If the parent doesn't already hold a reference, add it as a property and have its parent inject the same instance constructed in Task 4.

- [ ] **Step 3: Build and smoke-test**

Run: `bash scripts/build-app.sh && open dist/Multiharness.app`
Expected: app launches, right-clicking a project shows "Project settings…", clicking it opens the settings sheet, changing the default base branch saves and the next "New workspace" sheet pre-selects the new default.

- [ ] **Step 4: Commit**

```bash
git add Sources/Multiharness/Views/*.swift
git commit -m "feat(mac): expose ProjectSettingsView from project list"
```

---

## Final verification

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: every test passes (the existing 5 + the new ones from tasks 1, 2, 3, 4, 6, 7).

- [ ] **Step 2: End-to-end smoke test on Mac**

1. Launch fresh: `bash scripts/build-app.sh && open dist/Multiharness.app`.
2. Add a project pointing at a clone with an `origin` remote.
3. Open "New workspace": picker loads, Origin segment enabled, list contains `origin/main`.
4. Pick `origin/main`, create the workspace. Worktree is created off `origin/main`.
5. Open project settings, change default to `origin/develop` (assuming it exists). Re-open "New workspace": picker pre-selects `origin/develop`.
6. Add a second project with no `origin` remote. Open "New workspace": Origin segment greyed with "No `origin` remote configured" caption; Local list still works.

- [ ] **Step 3: End-to-end smoke test on iOS**

1. Pair iPhone simulator: `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`.
2. Open "New workspace" on iOS, repeat the relevant subset of the Mac smoke test (origin enable/disable, search, ↻).

If any smoke check fails, fix and re-test before declaring complete.

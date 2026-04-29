# Sidebar Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a spinner on streaming workspace rows and a blue dot on rows whose latest assistant turn has not yet been viewed, on both the Mac sidebar and the iOS workspaces list.

**Architecture:** The Mac persists `last_viewed_at` on the `workspaces` table. The sidecar exposes per-workspace `isStreaming` (from `AgentRegistry`) and `unseen` (computed by comparing the latest persisted `agent_end` timestamp in `messages.jsonl` against `last_viewed_at`) on `remote.workspaces`, and emits a `workspace.activity` event on transitions for live iOS updates. iOS marks workspaces as viewed via a relayed `workspace.markViewed` RPC; the Mac marks viewed locally on selection-change and on `agent_end` for the currently-selected workspace.

**Tech Stack:** SwiftUI / Swift 5.10 (Mac, iOS), Bun + TypeScript (sidecar), SQLite (`bun:sqlite` and a hand-rolled Swift wrapper), JSONL append logs.

---

## File Structure

**New files:**
- `sidecar/src/workspaceActivity.ts` — `WorkspaceActivityTracker` class: tracks live `isStreaming` Set and lazy `lastAssistantAt` Map.
- `sidecar/test/workspaceActivity.test.ts` — unit tests for the tracker.
- `Tests/MultiharnessCoreTests/SidebarIndicatorsTests.swift` — Mac-side WorkspaceStore + persistence tests that don't fit `PersistenceTests`.

**Modified files (responsibilities):**
- `Sources/MultiharnessCore/Persistence/Migrations.swift` — append migration v6.
- `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — read/write `lastViewedAt`; new `markWorkspaceViewed`; new `lastAssistantAt(workspaceId:)`.
- `Sources/MultiharnessClient/Models/Models.swift` — add `lastViewedAt: Date?` to `Workspace`.
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — `lastAssistantAt` cache, `markViewed`, `unseen(_:)` helper.
- `Sources/MultiharnessCore/Stores/AgentStore.swift` — emit `lastAssistantAt = Date()` change on `agent_end` (via callback).
- `Sources/Multiharness/App.swift` — `AgentRegistryStore` propagates `agent_end` into `WorkspaceStore`.
- `Sources/Multiharness/ContentView.swift` (or wherever `selection` is owned) — `.onChange(of: selection)` → `markViewed`.
- `Sources/Multiharness/Views/WorkspaceSidebar.swift` — `WorkspaceRow` accepts and renders spinner / unseen dot; both call sites updated.
- `Sources/Multiharness/RemoteHandlers.swift` — register `workspace.markViewed` handler.
- `sidecar/src/server.ts` — instantiate tracker; wrap `sink` to feed it; emit `workspace.activity` on transitions.
- `sidecar/src/methods.ts` — `registerMethods` accepts tracker; enrich `remote.workspaces`; register `workspace.markViewed` (relayed); after relay returns, emit `workspace.activity` with `unseen=false`.
- `sidecar/src/dataReader.ts` — `listWorkspaces` returns `lastViewedAt` (epoch ms or `null`).
- `Sources/MultiharnessClient/Models/Models.swift` — (already covered above for `Workspace`).
- `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — `RemoteWorkspace` gains `isStreaming`, `unseen`; `controlClient(_:didReceiveEvent:)` handles `workspace.activity`; new `markViewed` method.
- `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift` — render spinner + dot.
- `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift` — call `markViewed` from `.task`.

---

## Task 1: Schema migration v6 + Workspace.lastViewedAt + PersistenceService

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/Migrations.swift`
- Modify: `Sources/MultiharnessClient/Models/Models.swift`
- Modify: `Sources/MultiharnessCore/Persistence/PersistenceService.swift`
- Test: `Tests/MultiharnessCoreTests/PersistenceTests.swift`

- [ ] **Step 1: Write the failing test for migration backfill**

Add to `Tests/MultiharnessCoreTests/PersistenceTests.swift`:

```swift
func testMigrationV6BackfillsLastViewedAt() throws {
    let dir = try tempDir()
    let svc = try PersistenceService(dataDir: dir)
    let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
    try svc.upsertProject(proj)
    let prov = ProviderRecord(name: "Local", kind: .openaiCompatible, baseUrl: "http://localhost:1234/v1")
    try svc.upsertProvider(prov)
    let ws = Workspace(
        projectId: proj.id, name: "W", slug: "w",
        branchName: "u/w", baseBranch: "main",
        worktreePath: "/tmp/wt",
        providerId: prov.id, modelId: "m"
    )
    try svc.upsertWorkspace(ws)
    let loaded = try svc.listWorkspaces(projectId: proj.id)
    XCTAssertEqual(loaded.count, 1)
    let lvAt = loaded[0].lastViewedAt
    XCTAssertNotNil(lvAt)
    XCTAssertLessThanOrEqual(abs(lvAt!.timeIntervalSinceNow), 5)
}

func testMarkWorkspaceViewedUpdatesTimestamp() throws {
    let dir = try tempDir()
    let svc = try PersistenceService(dataDir: dir)
    let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
    try svc.upsertProject(proj)
    let prov = ProviderRecord(name: "Local", kind: .openaiCompatible, baseUrl: "http://localhost:1234/v1")
    try svc.upsertProvider(prov)
    let ws = Workspace(
        projectId: proj.id, name: "W", slug: "w",
        branchName: "u/w", baseBranch: "main",
        worktreePath: "/tmp/wt",
        providerId: prov.id, modelId: "m"
    )
    try svc.upsertWorkspace(ws)

    let original = try svc.listWorkspaces(projectId: proj.id)[0].lastViewedAt!
    Thread.sleep(forTimeInterval: 0.05)
    try svc.markWorkspaceViewed(id: ws.id)
    let after = try svc.listWorkspaces(projectId: proj.id)[0].lastViewedAt!
    XCTAssertGreaterThan(after, original)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter PersistenceTests/testMigrationV6BackfillsLastViewedAt`
Expected: FAIL — `'Workspace' has no member 'lastViewedAt'`

- [ ] **Step 3: Add `lastViewedAt` to the `Workspace` struct**

In `Sources/MultiharnessClient/Models/Models.swift`, add a new property and constructor parameter to `Workspace`. Insert immediately after the existing `contextInstructions` property and parameter:

```swift
public struct Workspace: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var slug: String
    public var branchName: String
    public var baseBranch: String
    public var worktreePath: String
    public var lifecycleState: LifecycleState
    public var providerId: UUID
    public var modelId: String
    public var buildMode: BuildMode?
    public var createdAt: Date
    public var archivedAt: Date?
    public var nameSource: NameSource
    public var contextInstructions: String
    /// Last time the user opened this workspace in the UI. Used together
    /// with the latest persisted `agent_end` timestamp from messages.jsonl
    /// to decide whether to show an "unseen" dot on the workspace row.
    public var lastViewedAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        slug: String,
        branchName: String,
        baseBranch: String,
        worktreePath: String,
        lifecycleState: LifecycleState = .inProgress,
        providerId: UUID,
        modelId: String,
        buildMode: BuildMode? = nil,
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        nameSource: NameSource = .random,
        contextInstructions: String = "",
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.slug = slug
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.lifecycleState = lifecycleState
        self.providerId = providerId
        self.modelId = modelId
        self.buildMode = buildMode
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.nameSource = nameSource
        self.contextInstructions = contextInstructions
        self.lastViewedAt = lastViewedAt
    }

    public func effectiveBuildMode(in project: Project) -> BuildMode {
        if let m = buildMode { return m }
        if let m = project.defaultBuildMode { return m }
        return .primary
    }
}
```

- [ ] **Step 4: Append migration v6 to `Migrations.all`**

In `Sources/MultiharnessCore/Persistence/Migrations.swift`, append a new entry to the `all` array:

```swift
public static let all: [String] = [
    v1,
    "ALTER TABLE projects ADD COLUMN repo_bookmark BLOB;",
    """
    ALTER TABLE projects ADD COLUMN default_build_mode TEXT;
    ALTER TABLE workspaces ADD COLUMN build_mode TEXT;
    """,
    "ALTER TABLE workspaces ADD COLUMN name_source TEXT NOT NULL DEFAULT 'random';",
    """
    ALTER TABLE projects   ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
    ALTER TABLE workspaces ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
    """,
    // v6: per-workspace last-viewed timestamp powering the unseen dot.
    // Backfill existing rows to "now" so users don't see a flood of dots
    // on first launch after upgrade.
    """
    ALTER TABLE workspaces ADD COLUMN last_viewed_at INTEGER;
    UPDATE workspaces SET last_viewed_at = CAST(strftime('%s','now') AS INTEGER) * 1000;
    """,
]
```

- [ ] **Step 5: Persist `lastViewedAt` in upsertWorkspace + listWorkspaces**

In `Sources/MultiharnessCore/Persistence/PersistenceService.swift`, modify the `upsertWorkspace` method's SQL and bindings, and modify `listWorkspaces` to read the new column.

Replace the body of `upsertWorkspace(_ w: Workspace)` with:

```swift
public func upsertWorkspace(_ w: Workspace) throws {
    try db.executeUpdate(
        """
        INSERT INTO workspaces (id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name,
          slug=excluded.slug,
          branch_name=excluded.branch_name,
          base_branch=excluded.base_branch,
          worktree_path=excluded.worktree_path,
          lifecycle_state=excluded.lifecycle_state,
          provider_id=excluded.provider_id,
          model_id=excluded.model_id,
          build_mode=excluded.build_mode,
          archived_at=excluded.archived_at,
          name_source=excluded.name_source,
          context_instructions=excluded.context_instructions,
          last_viewed_at=excluded.last_viewed_at;
        """
    ) { st in
        st.bind(1, w.id.uuidString)
        st.bind(2, w.projectId.uuidString)
        st.bind(3, w.name)
        st.bind(4, w.slug)
        st.bind(5, w.branchName)
        st.bind(6, w.baseBranch)
        st.bind(7, w.worktreePath)
        st.bind(8, w.lifecycleState.rawValue)
        st.bind(9, w.providerId.uuidString)
        st.bind(10, w.modelId)
        st.bind(11, w.buildMode?.rawValue)
        st.bind(12, w.createdAt)
        st.bind(13, w.archivedAt)
        st.bind(14, w.nameSource.rawValue)
        st.bind(15, w.contextInstructions)
        st.bind(16, w.lastViewedAt)
    }
}
```

Replace the body of `listWorkspaces(projectId:)` with:

```swift
public func listWorkspaces(projectId: UUID? = nil) throws -> [Workspace] {
    let sql: String
    if projectId != nil {
        sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at FROM workspaces WHERE project_id = ? ORDER BY created_at DESC;"
    } else {
        sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at FROM workspaces ORDER BY created_at DESC;"
    }
    return try db.query(
        sql,
        bind: { st in
            if let pid = projectId { st.bind(1, pid.uuidString) }
        },
        rowMap: { st in
            Workspace(
                id: UUID(uuidString: st.requiredString(0))!,
                projectId: UUID(uuidString: st.requiredString(1))!,
                name: st.requiredString(2),
                slug: st.requiredString(3),
                branchName: st.requiredString(4),
                baseBranch: st.requiredString(5),
                worktreePath: st.requiredString(6),
                lifecycleState: LifecycleState(rawValue: st.requiredString(7)) ?? .inProgress,
                providerId: UUID(uuidString: st.requiredString(8))!,
                modelId: st.requiredString(9),
                buildMode: st.string(10).flatMap(BuildMode.init(rawValue:)),
                createdAt: st.requiredDate(11),
                archivedAt: st.date(12),
                nameSource: st.string(13).flatMap(NameSource.init(rawValue:)) ?? .random,
                contextInstructions: st.string(14) ?? "",
                lastViewedAt: st.date(15)
            )
        }
    )
}
```

- [ ] **Step 6: Add `markWorkspaceViewed(id:)` method**

In `Sources/MultiharnessCore/Persistence/PersistenceService.swift`, add immediately after the existing `deleteWorkspace(id:)` method:

```swift
public func markWorkspaceViewed(id: UUID) throws {
    try db.executeUpdate(
        "UPDATE workspaces SET last_viewed_at = ? WHERE id = ?;"
    ) { st in
        st.bind(1, Date())
        st.bind(2, id.uuidString)
    }
}
```

- [ ] **Step 7: Run the persistence tests**

Run: `swift test --filter PersistenceTests`
Expected: PASS, including the two new tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/Migrations.swift \
        Sources/MultiharnessCore/Persistence/PersistenceService.swift \
        Sources/MultiharnessClient/Models/Models.swift \
        Tests/MultiharnessCoreTests/PersistenceTests.swift
git commit -m "Persist last_viewed_at per workspace"
```

---

## Task 2: PersistenceService.lastAssistantAt(workspaceId:)

Reads a workspace's `messages.jsonl` and returns the latest `agent_end` event timestamp. Used by `WorkspaceStore` to seed the in-memory cache at app launch.

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/PersistenceService.swift`
- Test: `Tests/MultiharnessCoreTests/PersistenceTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PersistenceTests.swift`:

```swift
func testLastAssistantAtReadsLatestAgentEnd() throws {
    let dir = try tempDir()
    let svc = try PersistenceService(dataDir: dir)
    let wsId = UUID()
    let path = svc.messagesPath(workspaceId: wsId)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // ts in milliseconds since 1970, matching the sidecar's JsonlWriter.
    let lines = [
        #"{"seq":0,"ts":1000,"event":{"type":"agent_start"}}"#,
        #"{"seq":1,"ts":2000,"event":{"type":"message_end","message":{}}}"#,
        #"{"seq":2,"ts":3000,"event":{"type":"agent_end","messages":[]}}"#,
        #"{"seq":3,"ts":4000,"event":{"type":"agent_start"}}"#,
        #"{"seq":4,"ts":5000,"event":{"type":"agent_end","messages":[]}}"#,
    ].joined(separator: "\n") + "\n"
    try lines.data(using: .utf8)!.write(to: path)
    let result = try svc.lastAssistantAt(workspaceId: wsId)
    XCTAssertEqual(result?.timeIntervalSince1970, 5.0) // 5000 ms
}

func testLastAssistantAtReturnsNilWhenFileMissing() throws {
    let dir = try tempDir()
    let svc = try PersistenceService(dataDir: dir)
    let result = try svc.lastAssistantAt(workspaceId: UUID())
    XCTAssertNil(result)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter PersistenceTests/testLastAssistantAtReadsLatestAgentEnd`
Expected: FAIL — no member `lastAssistantAt`.

- [ ] **Step 3: Implement `lastAssistantAt(workspaceId:)`**

Append to `Sources/MultiharnessCore/Persistence/PersistenceService.swift` (just before the closing brace of the class):

```swift
/// Scan a workspace's messages.jsonl and return the timestamp of the most
/// recent `agent_end` event, or `nil` if the file is missing or empty.
/// Reads the whole file; this is acceptable because the file is small in
/// practice and we only call this once per workspace at app launch.
public func lastAssistantAt(workspaceId: UUID) throws -> Date? {
    let path = messagesPath(workspaceId: workspaceId)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let data = try Data(contentsOf: path)
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var maxMs: Int64 = -1
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "agent_end"
        else { continue }
        let ts: Int64
        if let n = obj["ts"] as? Int64 { ts = n }
        else if let n = obj["ts"] as? Int { ts = Int64(n) }
        else if let n = obj["ts"] as? Double { ts = Int64(n) }
        else { continue }
        if ts > maxMs { maxMs = ts }
    }
    if maxMs < 0 { return nil }
    return Date(timeIntervalSince1970: TimeInterval(maxMs) / 1000.0)
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PersistenceTests/testLastAssistantAt`
Expected: PASS for both new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/PersistenceService.swift \
        Tests/MultiharnessCoreTests/PersistenceTests.swift
git commit -m "Add PersistenceService.lastAssistantAt(workspaceId:)"
```

---

## Task 3: WorkspaceStore — markViewed, lastAssistantAt cache, unseen helper

Adds an in-memory `lastAssistantAt: [UUID: Date]` cache populated from JSONL on `load()`, a `markViewed(_:)` method that updates SQLite + in-memory state, and an `unseen(_:)` helper used by view code.

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/WorkspaceStore.swift`
- Test: `Tests/MultiharnessCoreTests/SidebarIndicatorsTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/MultiharnessCoreTests/SidebarIndicatorsTests.swift`:

```swift
import XCTest
@testable import MultiharnessCore

@MainActor
final class SidebarIndicatorsTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() throws -> (env: AppEnvironment, ws: WorkspaceStore, workspace: Workspace) {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(name: "Local", kind: .openaiCompatible, baseUrl: "http://localhost:1234/v1")
        try env.persistence.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id, name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main",
            worktreePath: "/tmp/wt",
            providerId: prov.id, modelId: "m"
        )
        try env.persistence.upsertWorkspace(ws)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        return (env, store, ws)
    }

    private func writeJsonl(_ env: AppEnvironment, workspaceId: UUID, agentEndMs: Int64) throws {
        let path = env.persistence.messagesPath(workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = #"{"seq":0,"ts":\#(agentEndMs),"event":{"type":"agent_end","messages":[]}}"#
        try (line + "\n").data(using: .utf8)!.write(to: path)
    }

    func testUnseenIsTrueWhenAssistantNewerThanLastViewed() throws {
        let (env, store, ws) = try makeFixture()
        // Backfill puts last_viewed_at at "now"; force it earlier.
        try env.persistence.db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = 0 WHERE id = ?;"
        ) { $0.bind(1, ws.id.uuidString) }
        try writeJsonl(env, workspaceId: ws.id, agentEndMs: 1_000)
        store.load(projectId: ws.projectId)
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertTrue(store.unseen(updated))
    }

    func testUnseenIsFalseAfterMarkViewed() throws {
        let (env, store, ws) = try makeFixture()
        try env.persistence.db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = 0 WHERE id = ?;"
        ) { $0.bind(1, ws.id.uuidString) }
        try writeJsonl(env, workspaceId: ws.id, agentEndMs: 1_000)
        store.load(projectId: ws.projectId)
        store.markViewed(ws.id)
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertFalse(store.unseen(updated))
    }

    func testUnseenIsFalseWhenNoAssistantActivity() throws {
        let (_, store, ws) = try makeFixture()
        // No JSONL written.
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertFalse(store.unseen(updated))
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter SidebarIndicatorsTests`
Expected: FAIL — `WorkspaceStore` has no `unseen(_:)` or `markViewed(_:)`.

- [ ] **Step 3: Implement the new state and methods on `WorkspaceStore`**

In `Sources/MultiharnessCore/Stores/WorkspaceStore.swift`, modify the class header to add the new state and methods. Add the property after the existing `lastError`:

```swift
/// Cache of the latest `agent_end` timestamp observed in each workspace's
/// messages.jsonl. Populated on `load(projectId:)` and updated by callers
/// (e.g. AgentRegistryStore) on live `agent_end` events.
public var lastAssistantAt: [UUID: Date] = [:]
```

Modify `load(projectId:)` to populate the cache after loading workspaces:

```swift
public func load(projectId: UUID?) {
    do {
        self.workspaces = try env.persistence.listWorkspaces(projectId: projectId)
        if let id = selectedWorkspaceId, !workspaces.contains(where: { $0.id == id }) {
            selectedWorkspaceId = nil
        }
        // Refresh lastAssistantAt for every loaded workspace. Reads JSONL
        // off-disk; cheap because each file is small (<1MB typical).
        var fresh: [UUID: Date] = [:]
        for w in workspaces {
            if let ts = try? env.persistence.lastAssistantAt(workspaceId: w.id) {
                fresh[w.id] = ts
            }
        }
        self.lastAssistantAt = fresh
    } catch {
        lastError = String(describing: error)
    }
}
```

Add new methods immediately after `selected()`:

```swift
/// Mark a workspace as just-viewed: persist now() to last_viewed_at and
/// reflect it in the in-memory copy so unseen(_:) flips to false
/// immediately. Safe to call repeatedly.
public func markViewed(_ id: UUID) {
    do {
        try env.persistence.markWorkspaceViewed(id: id)
        if let idx = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[idx].lastViewedAt = Date()
        }
    } catch {
        lastError = String(describing: error)
    }
}

/// True iff this workspace's most recent `agent_end` happened after the
/// user last viewed it. Returns false when there's been no agent activity
/// at all.
public func unseen(_ ws: Workspace) -> Bool {
    guard let lastEnd = lastAssistantAt[ws.id] else { return false }
    guard let viewed = ws.lastViewedAt else { return true }
    return lastEnd > viewed
}

/// Record a fresh `agent_end` for a workspace at the current wall-clock.
/// Called by AgentRegistryStore when it sees an `agent_end` event from
/// the sidecar.
public func recordAssistantEnd(workspaceId: UUID) {
    lastAssistantAt[workspaceId] = Date()
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SidebarIndicatorsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Stores/WorkspaceStore.swift \
        Tests/MultiharnessCoreTests/SidebarIndicatorsTests.swift
git commit -m "Track lastAssistantAt + unseen on WorkspaceStore"
```

---

## Task 4: Mac wiring — selection-change & agent_end auto-mark

The Mac flips a workspace as viewed in two situations: when the user selects a row in the sidebar, and when an `agent_end` event arrives for the currently-selected workspace.

**Files:**
- Modify: `Sources/Multiharness/App.swift` (`AgentRegistryStore` + ContentView).
- Modify: `Sources/Multiharness/Views/WorkspaceSidebar.swift` (or wherever sidebar selection is observed). If `selection` is bound from `ContentView`, change in App.swift's ContentView area.

- [ ] **Step 1: Add a workspaceStore reference to AgentRegistryStore**

In `Sources/Multiharness/App.swift`, modify `AgentRegistryStore` to take an optional `WorkspaceStore` reference and call `recordAssistantEnd` + `markViewed` when appropriate.

Replace the property block of `AgentRegistryStore` and `bindEnvironment(env:appStore:)`:

```swift
@MainActor
@Observable
final class AgentRegistryStore: NSObject, ControlClientDelegate {
    var stores: [UUID: AgentStore] = [:]
    weak var env: AppEnvironment?
    weak var appStore: AppStore?
    weak var workspaceStore: WorkspaceStore?
    var relayHandler: RelayHandler?

    func bindEnvironment(env: AppEnvironment, appStore: AppStore, workspaceStore: WorkspaceStore) {
        self.env = env
        self.appStore = appStore
        self.workspaceStore = workspaceStore
    }

    // ... ensureStore unchanged ...
```

- [ ] **Step 2: Update the call site that invokes `bindEnvironment`**

In `Sources/Multiharness/App.swift` (around line 96), change:

```swift
self.agentRegistry.bindEnvironment(env: env, appStore: app)
```

To:

```swift
self.agentRegistry.bindEnvironment(env: env, appStore: app, workspaceStore: ws)
```

(`ws` is the local `WorkspaceStore` constructed earlier in `boot()`.)

- [ ] **Step 3: Hook agent_end in the delegate**

In the `controlClient(_:didReceiveEvent:)` method of `AgentRegistryStore`, modify the existing `Task { @MainActor in ... }` block at the bottom of the function (the catch-all that forwards to `self.stores[id]?.handleEvent(event)`) so it also feeds `WorkspaceStore`:

Replace the existing block:

```swift
Task { @MainActor in
    guard let id = UUID(uuidString: event.workspaceId) else { return }
    self.stores[id]?.handleEvent(event)
}
```

With:

```swift
Task { @MainActor in
    guard let id = UUID(uuidString: event.workspaceId) else { return }
    self.stores[id]?.handleEvent(event)
    if event.type == "agent_end" {
        self.workspaceStore?.recordAssistantEnd(workspaceId: id)
        // Auto-mark the currently-selected workspace so the user never
        // sees a dot for the row they're actively looking at.
        if self.workspaceStore?.selectedWorkspaceId == id {
            self.workspaceStore?.markViewed(id)
        }
    }
}
```

- [ ] **Step 4: Mark viewed on selection change in RootView**

In `Sources/Multiharness/Views/RootView.swift`, add an `.onChange(of: workspaceStore.selectedWorkspaceId)` modifier on the `body`'s top-level view chain. Place it next to the existing `.onChange(of: appStore.sidebarMode)` modifier (currently around lines 60–62):

```swift
.onChange(of: appStore.sidebarMode) { _, new in
    reloadForMode(new)
}
.onChange(of: workspaceStore.selectedWorkspaceId) { _, newId in
    if let newId { workspaceStore.markViewed(newId) }
}
```

This is idempotent — `markViewed` simply rewrites `last_viewed_at` to "now".

- [ ] **Step 5: Build and run the tests**

Run: `swift build && swift test`
Expected: full build passes; all tests pass. The new behavior isn't testable without UI, so we'll exercise it manually in Task 5.

- [ ] **Step 6: Commit**

```bash
git add Sources/Multiharness/App.swift
git commit -m "Auto-mark workspace viewed on selection and agent_end"
```

---

## Task 5: Render spinner + unseen dot in Mac sidebar

**Files:**
- Modify: `Sources/Multiharness/Views/WorkspaceSidebar.swift`

- [ ] **Step 1: Modify `WorkspaceRow` to accept the new flags**

Replace the current `WorkspaceRow` struct in `Sources/Multiharness/Views/WorkspaceSidebar.swift` with:

```swift
struct WorkspaceRow: View {
    let ws: Workspace
    var showLifecycleDot: Bool = false
    var isStreaming: Bool = false
    var isUnseen: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showLifecycleDot {
                Circle()
                    .fill(Self.color(for: ws.lifecycleState))
                    .frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.body)
                Text(ws.branchName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else if isUnseen {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unseen response")
            }
        }
        .padding(.vertical, 2)
    }

    static func color(for state: LifecycleState) -> Color {
        switch state {
        case .inProgress: return .blue
        case .inReview: return .orange
        case .done: return .green
        case .backlog: return .gray
        case .cancelled: return .red.opacity(0.6)
        }
    }
}
```

- [ ] **Step 2: Pass flags from the call sites**

The two call sites need access to the `AgentRegistryStore` (for `isStreaming`) and `WorkspaceStore` (for `unseen`). Make `WorkspaceSidebar` and `AllProjectsSidebar` (and `ProjectDisclosure`) take an additional `agentRegistry: AgentRegistryStore` parameter.

Modify `WorkspaceSidebar`:

```swift
struct WorkspaceSidebar: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var agentRegistry: AgentRegistryStore
    @Binding var selection: UUID?

    @State private var renameTarget: Workspace?

    var body: some View {
        List(selection: $selection) {
            ForEach(workspaceStore.grouped(), id: \.0) { (state, items) in
                Section(state.label) {
                    ForEach(items) { ws in
                        WorkspaceRow(
                            ws: ws,
                            isStreaming: agentRegistry.stores[ws.id]?.isStreaming ?? false,
                            isUnseen: workspaceStore.unseen(ws)
                        )
                        .tag(ws.id as UUID?)
                        .contextMenu { workspaceContextMenu(ws) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $renameTarget) { ws in
            RenameWorkspaceSheet(
                workspaceStore: workspaceStore,
                workspace: ws,
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            )
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ ws: Workspace) -> some View {
        Button("Rename…") { renameTarget = ws }
        Divider()
        ForEach(LifecycleState.allCases, id: \.self) { other in
            Button(other.label) {
                workspaceStore.setLifecycle(ws, other)
            }
            .disabled(other == ws.lifecycleState)
        }
        Divider()
        Button("Archive (keep worktree)") {
            workspaceStore.archive(ws, removeWorktree: false)
        }
        Button("Archive + remove worktree", role: .destructive) {
            workspaceStore.archive(ws, removeWorktree: true)
        }
    }
}
```

Modify `AllProjectsSidebar` and `ProjectDisclosure` to accept and forward `agentRegistry`. Replace the existing `AllProjectsSidebar` body and the relevant ProjectDisclosure init/usage:

```swift
struct AllProjectsSidebar: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var agentRegistry: AgentRegistryStore
    @Binding var selection: UUID?
    var onQuickCreate: (Project) -> Void

    @State private var pendingReconcileProject: Project? = nil

    var body: some View {
        List(selection: $selection) {
            ForEach(appStore.projects) { project in
                ProjectDisclosure(
                    project: project,
                    appStore: appStore,
                    workspaceStore: workspaceStore,
                    agentRegistry: agentRegistry,
                    onQuickCreate: { onQuickCreate(project) },
                    onReconcile: { pendingReconcileProject = project }
                )
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $pendingReconcileProject) { proj in
            ReconcileSheet(
                appStore: appStore,
                workspaceStore: workspaceStore,
                project: proj,
                isPresented: Binding(
                    get: { pendingReconcileProject != nil },
                    set: { if !$0 { pendingReconcileProject = nil } }
                )
            )
        }
    }
}
```

In `ProjectDisclosure`, add `let agentRegistry: AgentRegistryStore` to its stored properties (not `@Bindable` — it's not mutated here), thread it through `init`, and update the row rendering inside `content`:

```swift
private struct ProjectDisclosure: View {
    let project: Project
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore
    let onQuickCreate: () -> Void
    let onReconcile: () -> Void

    // ...existing State properties unchanged...

    init(
        project: Project,
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        agentRegistry: AgentRegistryStore,
        onQuickCreate: @escaping () -> Void,
        onReconcile: @escaping () -> Void
    ) {
        self.project = project
        self.appStore = appStore
        self.workspaceStore = workspaceStore
        self.agentRegistry = agentRegistry
        self.onQuickCreate = onQuickCreate
        self.onReconcile = onReconcile
        let expandedKey = Self.expandedKey(project.id)
        let groupKey = Self.groupKey(project.id)
        let defaults = UserDefaults.standard
        let initialExpanded = defaults.object(forKey: expandedKey) as? Bool ?? true
        let initialGroup = defaults.object(forKey: groupKey) as? Bool ?? false
        self._isExpanded = State(initialValue: initialExpanded)
        self._groupByStatus = State(initialValue: initialGroup)
    }

    // ...body, header, hasEligibleWorkspaces, sheets unchanged...

    @ViewBuilder
    private var content: some View {
        let items = workspaceStore.workspaces(for: project.id)
        if items.isEmpty {
            Text("No workspaces yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else if groupByStatus {
            ForEach(workspaceStore.grouped(projectId: project.id), id: \.0) { (state, items) in
                Section(state.label) {
                    ForEach(items) { ws in
                        WorkspaceRow(
                            ws: ws,
                            isStreaming: agentRegistry.stores[ws.id]?.isStreaming ?? false,
                            isUnseen: workspaceStore.unseen(ws)
                        )
                        .tag(ws.id as UUID?)
                        .contextMenu { workspaceContextMenu(ws) }
                    }
                }
            }
        } else {
            ForEach(items) { ws in
                WorkspaceRow(
                    ws: ws,
                    showLifecycleDot: true,
                    isStreaming: agentRegistry.stores[ws.id]?.isStreaming ?? false,
                    isUnseen: workspaceStore.unseen(ws)
                )
                .tag(ws.id as UUID?)
                .contextMenu { workspaceContextMenu(ws) }
            }
        }
    }
```

- [ ] **Step 3: Update `WorkspaceSidebar` and `AllProjectsSidebar` call sites**

The two call sites are in `Sources/Multiharness/Views/RootView.swift` (around lines 89 and 114). Add `agentRegistry: agentRegistry` to both:

```swift
WorkspaceSidebar(
    workspaceStore: workspaceStore,
    agentRegistry: agentRegistry,
    selection: Binding(
        get: { workspaceStore.selectedWorkspaceId },
        set: { workspaceStore.selectedWorkspaceId = $0 }
    )
)
```

```swift
AllProjectsSidebar(
    appStore: appStore,
    workspaceStore: workspaceStore,
    agentRegistry: agentRegistry,
    selection: Binding(
        get: { workspaceStore.selectedWorkspaceId },
        set: { newID in
            workspaceStore.selectedWorkspaceId = newID
            if let id = newID,
               let ws = workspaceStore.workspaces.first(where: { $0.id == id }),
               appStore.selectedProjectId != ws.projectId {
                appStore.selectedProjectId = ws.projectId
            }
        }
    ),
    onQuickCreate: { runQuickCreate(project: $0) }
)
```

`agentRegistry` is already a parameter of `RootView`, so it's in scope.

- [ ] **Step 4: Build and launch the app, verify visually**

```bash
bash scripts/build-app.sh
open dist/Multiharness.app
```

Manual verification:
- Open a workspace, send a prompt, switch to another workspace mid-stream → spinner appears on the streaming row.
- Wait for it to finish, switch back → no spinner, no dot (since it auto-marked viewed via `agent_end`).
- Trigger a turn, switch to a different workspace before it finishes, wait → returns to no-spinner + blue dot on the now-finished row.
- Click the dotted row → dot disappears.

- [ ] **Step 5: Commit**

```bash
git add Sources/Multiharness/Views/WorkspaceSidebar.swift Sources/Multiharness/App.swift
git commit -m "Render spinner + unseen dot on Mac workspace rows"
```

---

## Task 6: Sidecar `WorkspaceActivityTracker`

A small tracker that mirrors live `agent_start` / `agent_end` state and lazily reads the latest `agent_end` ts from each workspace's JSONL on demand. Used by `methods.ts` to enrich `remote.workspaces` with `isStreaming` + `unseen`, and by `server.ts` to emit `workspace.activity` events.

**Files:**
- Create: `sidecar/src/workspaceActivity.ts`
- Test: `sidecar/test/workspaceActivity.test.ts`

- [ ] **Step 1: Write the failing test**

Create `sidecar/test/workspaceActivity.test.ts`:

```typescript
import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WorkspaceActivityTracker } from "../src/workspaceActivity.js";

function tempDataDir(): string {
  const d = mkdtempSync(join(tmpdir(), "mh-act-"));
  return d;
}

function writeJsonl(dataDir: string, workspaceId: string, lines: string[]): void {
  const dir = join(dataDir, "workspaces", workspaceId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "messages.jsonl"), lines.join("\n") + "\n");
}

describe("WorkspaceActivityTracker", () => {
  it("isStreaming reflects observed start/end", () => {
    const t = new WorkspaceActivityTracker(tempDataDir());
    expect(t.isStreaming("w1")).toBe(false);
    t.observe("w1", "agent_start");
    expect(t.isStreaming("w1")).toBe(true);
    t.observe("w1", "agent_end");
    expect(t.isStreaming("w1")).toBe(false);
  });

  it("lastAssistantAt reads the latest agent_end ts from JSONL", () => {
    const dir = tempDataDir();
    writeJsonl(dir, "w2", [
      JSON.stringify({ seq: 0, ts: 1000, event: { type: "agent_start" } }),
      JSON.stringify({ seq: 1, ts: 2000, event: { type: "agent_end", messages: [] } }),
      JSON.stringify({ seq: 2, ts: 3000, event: { type: "agent_end", messages: [] } }),
    ]);
    const t = new WorkspaceActivityTracker(dir);
    expect(t.lastAssistantAt("w2")).toBe(3000);
  });

  it("observe(agent_end) updates lastAssistantAt to now", () => {
    const t = new WorkspaceActivityTracker(tempDataDir());
    const before = Date.now();
    t.observe("w3", "agent_end");
    const got = t.lastAssistantAt("w3");
    expect(got).not.toBeNull();
    expect(got!).toBeGreaterThanOrEqual(before);
  });

  it("isUnseen is true when lastAssistantAt > lastViewedAt", () => {
    const dir = tempDataDir();
    writeJsonl(dir, "w4", [
      JSON.stringify({ seq: 0, ts: 5000, event: { type: "agent_end", messages: [] } }),
    ]);
    const t = new WorkspaceActivityTracker(dir);
    expect(t.isUnseen("w4", 1000)).toBe(true);
    expect(t.isUnseen("w4", 6000)).toBe(false);
    expect(t.isUnseen("w4", null)).toBe(true);
    expect(t.isUnseen("never-active", 0)).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd sidecar && bun test test/workspaceActivity.test.ts
```

Expected: FAIL — module `../src/workspaceActivity.js` not found.

- [ ] **Step 3: Implement the tracker**

Create `sidecar/src/workspaceActivity.ts`:

```typescript
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Tracks per-workspace streaming state and the last `agent_end` timestamp,
 * used to compute `isStreaming` and `unseen` flags for `remote.workspaces`
 * responses and `workspace.activity` events.
 *
 * `lastAssistantAt` is loaded lazily from messages.jsonl on first request,
 * then kept up-to-date via `observe()` calls driven from the wrapped sink
 * in server.ts. Only the file's `ts` field is read, so we don't need to
 * parse big payloads.
 */
export class WorkspaceActivityTracker {
  private readonly streaming = new Set<string>();
  private readonly lastEnd = new Map<string, number>();
  /// Workspaces whose JSONL we've already scanned. Stops repeated disk
  /// reads for workspaces that have never produced an agent_end.
  private readonly scanned = new Set<string>();

  constructor(private readonly dataDir: string) {}

  observe(workspaceId: string, eventType: string): void {
    if (eventType === "agent_start") {
      this.streaming.add(workspaceId);
    } else if (eventType === "agent_end") {
      this.streaming.delete(workspaceId);
      this.lastEnd.set(workspaceId, Date.now());
      this.scanned.add(workspaceId);
    }
  }

  isStreaming(workspaceId: string): boolean {
    return this.streaming.has(workspaceId);
  }

  /** Returns the latest agent_end timestamp in ms, or null if none. */
  lastAssistantAt(workspaceId: string): number | null {
    if (!this.scanned.has(workspaceId)) {
      const ts = this.scanJsonl(workspaceId);
      if (ts !== null) this.lastEnd.set(workspaceId, ts);
      this.scanned.add(workspaceId);
    }
    return this.lastEnd.get(workspaceId) ?? null;
  }

  /** True iff the latest agent_end > lastViewedAt (or no lastViewedAt and
   *  there has been at least one agent_end). */
  isUnseen(workspaceId: string, lastViewedAt: number | null): boolean {
    const last = this.lastAssistantAt(workspaceId);
    if (last === null) return false;
    if (lastViewedAt === null) return true;
    return last > lastViewedAt;
  }

  private scanJsonl(workspaceId: string): number | null {
    const path = join(this.dataDir, "workspaces", workspaceId, "messages.jsonl");
    if (!existsSync(path)) return null;
    let text: string;
    try {
      text = readFileSync(path, "utf8");
    } catch {
      return null;
    }
    let max = -1;
    for (const line of text.split("\n")) {
      if (!line) continue;
      let obj: any;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (obj?.event?.type !== "agent_end") continue;
      const ts = typeof obj.ts === "number" ? obj.ts : -1;
      if (ts > max) max = ts;
    }
    return max < 0 ? null : max;
  }
}
```

- [ ] **Step 4: Run tests**

```bash
cd sidecar && bun test test/workspaceActivity.test.ts
```

Expected: PASS for all four cases.

- [ ] **Step 5: Commit**

```bash
git add sidecar/src/workspaceActivity.ts sidecar/test/workspaceActivity.test.ts
git commit -m "Add WorkspaceActivityTracker to sidecar"
```

---

## Task 7: DataReader returns `lastViewedAt`

**Files:**
- Modify: `sidecar/src/dataReader.ts`

- [ ] **Step 1: Modify the `listWorkspaces` query and return type**

In `sidecar/src/dataReader.ts`, replace the `listWorkspaces` method body and signature:

```typescript
listWorkspaces(): Array<{
  id: string;
  name: string;
  branchName: string;
  baseBranch: string;
  lifecycleState: string;
  projectId: string;
  contextInstructions: string;
  lastViewedAt: number | null;
}> {
  if (!this.db) return [];
  const rows = this.db
    .query(`
      SELECT
        id,
        name,
        branch_name AS branchName,
        base_branch AS baseBranch,
        lifecycle_state AS lifecycleState,
        project_id AS projectId,
        context_instructions AS contextInstructions,
        last_viewed_at AS lastViewedAt
      FROM workspaces
      WHERE archived_at IS NULL
      ORDER BY created_at DESC;
    `)
    .all() as Array<{
      id: string;
      name: string;
      branchName: string;
      baseBranch: string;
      lifecycleState: string;
      projectId: string;
      contextInstructions: string;
      lastViewedAt: number | null;
    }>;
  return rows;
}
```

- [ ] **Step 2: Run sidecar typecheck**

```bash
cd sidecar && bun run typecheck
```

Expected: PASS (no callers blow up — the new field is additive).

- [ ] **Step 3: Commit**

```bash
git add sidecar/src/dataReader.ts
git commit -m "DataReader.listWorkspaces returns lastViewedAt"
```

---

## Task 8: Sidecar wires tracker, enriches `remote.workspaces`, emits `workspace.activity`

**Files:**
- Modify: `sidecar/src/server.ts`
- Modify: `sidecar/src/methods.ts`
- Test: `sidecar/test/methods.test.ts` (extend or create — check existing tests first)

- [ ] **Step 1: Wrap the sink in `server.ts` to feed the tracker and emit transition events**

In `sidecar/src/server.ts`, just after the existing `clients` Set declaration (around line 51), instantiate the tracker and replace the `sink` definition:

```typescript
type WS = ServerWebSocket<undefined>;
const clients = new Set<WS>();
const tracker = new WorkspaceActivityTracker(opts.dataDir);

function broadcast(frame: string): void {
  for (const c of clients) {
    try {
      c.send(frame);
    } catch (e) {
      log.warn("send failed", { err: String(e) });
    }
  }
}

const sink = (workspaceId: string, ev: { type: string }) => {
  // Fan out the original event to all clients first so order-of-events
  // observed by clients matches what AgentSession produced.
  const frame = formatEvent(ev.type, { workspaceId, ...(ev as Record<string, unknown>) });
  broadcast(frame);

  // Mirror agent start/end into the tracker, then push a workspace.activity
  // event so iOS workspace lists update without polling.
  if (workspaceId && (ev.type === "agent_start" || ev.type === "agent_end")) {
    tracker.observe(workspaceId, ev.type);
    const activity = formatEvent("workspace.activity", {
      workspaceId,
      isStreaming: tracker.isStreaming(workspaceId),
      // unseen is recomputed against per-workspace lastViewedAt by the
      // recipient — sidecar can't know lastViewedAt without re-querying
      // SQLite, and clients already cache it from their last
      // remote.workspaces snapshot. So just send isStreaming and the
      // latest lastAssistantAt, letting the client decide.
      lastAssistantAt: tracker.lastAssistantAt(workspaceId),
    });
    broadcast(activity);
  }
};
```

Add the import at the top of the file alongside the other imports:

```typescript
import { WorkspaceActivityTracker } from "./workspaceActivity.js";
```

- [ ] **Step 2: Pass the tracker into `registerMethods`**

Still in `sidecar/src/server.ts`, modify the `registerMethods(...)` call to include `tracker`:

```typescript
registerMethods(dispatcher, registry, opts.dataDir, relay, oauthStore, sink, tracker);
```

- [ ] **Step 3: Update `registerMethods` signature and enrich `remote.workspaces`**

In `sidecar/src/methods.ts`:

Add the import at the top:

```typescript
import type { WorkspaceActivityTracker } from "./workspaceActivity.js";
```

Modify `registerMethods` signature:

```typescript
export function registerMethods(
  d: Dispatcher,
  registry: AgentRegistry,
  dataDir: string,
  relay: Relay,
  oauthStore: OAuthStore,
  sink: EventEmit,
  tracker: WorkspaceActivityTracker,
): void {
```

Replace the `remote.workspaces` registration with the enriched version:

```typescript
// Read-only views into the Mac app's persisted state, served to iOS.
d.register("remote.workspaces", () => {
  const workspaces = reader.listWorkspaces().map((w) => ({
    ...w,
    isStreaming: tracker.isStreaming(w.id),
    unseen: tracker.isUnseen(w.id, w.lastViewedAt),
  }));
  return {
    workspaces,
    projects: reader.listProjects(),
    providers: reader.listProviders(),
  };
});
```

- [ ] **Step 4: Run sidecar typecheck and tests**

```bash
cd sidecar && bun run typecheck && bun test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sidecar/src/server.ts sidecar/src/methods.ts
git commit -m "Sidecar tracks streaming + emits workspace.activity events"
```

---

## Task 9: `workspace.markViewed` relayed RPC + Mac handler

**Files:**
- Modify: `sidecar/src/methods.ts`
- Modify: `Sources/Multiharness/RemoteHandlers.swift`

- [ ] **Step 1: Register `workspace.markViewed` as a relayed RPC, with post-relay activity broadcast**

In `sidecar/src/methods.ts`, add a new registration immediately after the existing `workspace.rename` block (which already shows the "relay then broadcast" pattern):

```typescript
// Mark a workspace as viewed. The Mac handler writes last_viewed_at to
// SQLite. After the relay returns we also push a `workspace.activity`
// event so other connected clients (iOS, multi-instance) flip their
// local `unseen` flag immediately.
d.register("workspace.markViewed", async (params) => {
  const result = await relay.dispatch("workspace.markViewed", params);
  const wsId = typeof params.workspaceId === "string" ? params.workspaceId : "";
  if (wsId) {
    sink(wsId, {
      type: "workspace.activity",
      isStreaming: tracker.isStreaming(wsId),
      lastAssistantAt: tracker.lastAssistantAt(wsId),
    } as unknown as Parameters<EventEmit>[1]);
  }
  return result;
});
```

Note: this fires a `workspace.activity` carrying the new state, which the Mac and iOS clients use to recompute `unseen`. (Strictly the Mac doesn't need this — it already updated its own state — but the broadcast is harmless because the Mac's view of `lastViewedAt` is already past `lastAssistantAt` after `markViewed`.)

- [ ] **Step 2: Implement the Mac-side handler**

In `Sources/Multiharness/RemoteHandlers.swift`, add a registration for `workspace.markViewed`. Locate the existing block of `await relay.register(method: ...) { ... }` calls and add:

```swift
await relay.register(method: "workspace.markViewed") { params in
    return try await Self.workspaceMarkViewed(
        params: params,
        workspaceStore: workspaceStore
    )
}
```

Add the static handler method to the same file (alongside the existing `workspaceCreate`, `workspaceRename`, etc.):

```swift
@MainActor
private static func workspaceMarkViewed(
    params: [String: Any],
    workspaceStore: WorkspaceStore
) async throws -> Any? {
    guard let idStr = params["workspaceId"] as? String,
          let id = UUID(uuidString: idStr) else {
        throw RemoteError.bad("workspaceId required (UUID string)")
    }
    workspaceStore.markViewed(id)
    return ["workspaceId": idStr]
}
```

(Mirror the pattern of the existing `workspaceSetContext` handler — same `@MainActor`, same `RemoteError.bad(_:)` error type, same `Any?` return.)

- [ ] **Step 3: Build the Mac app + sidecar**

```bash
cd sidecar && bun run typecheck
cd .. && swift build && bash sidecar/scripts/build.sh
```

Expected: PASS for all three.

- [ ] **Step 4: Commit**

```bash
git add sidecar/src/methods.ts Sources/Multiharness/RemoteHandlers.swift
git commit -m "Add workspace.markViewed relayed RPC"
```

---

## Task 10: `RemoteWorkspace` + `ConnectionStore` handle activity

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`

- [ ] **Step 1: Extend `RemoteWorkspace` with `isStreaming` and `unseen`**

Replace the `RemoteWorkspace` struct in `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` with:

```swift
public struct RemoteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let branchName: String
    public let baseBranch: String
    public let lifecycleState: String
    public let projectId: String
    public let contextInstructions: String
    public let lastViewedAt: Int64?
    public let lastAssistantAt: Int64?
    public let isStreaming: Bool

    /// Computed locally from `lastAssistantAt` and `lastViewedAt`. The
    /// sidecar provides an `unseen` field too, but we recompute so live
    /// `workspace.activity` events that only carry `lastAssistantAt`
    /// don't leave us stale.
    public var unseen: Bool {
        guard let last = lastAssistantAt else { return false }
        guard let viewed = lastViewedAt else { return true }
        return last > viewed
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let branch = json["branchName"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.branchName = branch
        self.baseBranch = json["baseBranch"] as? String ?? ""
        self.lifecycleState = json["lifecycleState"] as? String ?? "in_progress"
        self.projectId = json["projectId"] as? String ?? ""
        self.contextInstructions = json["contextInstructions"] as? String ?? ""
        self.lastViewedAt = (json["lastViewedAt"] as? NSNumber)?.int64Value
        // The remote.workspaces response doesn't include lastAssistantAt
        // directly — it's only delivered via workspace.activity events.
        // Use the sidecar's `unseen` flag as a one-shot bootstrap: if
        // the snapshot says unseen=true, set lastAssistantAt to "after
        // lastViewedAt" by adding 1 ms; if false, leave it nil.
        let snapshotUnseen = (json["unseen"] as? Bool) ?? false
        if snapshotUnseen, let lv = self.lastViewedAt {
            self.lastAssistantAt = lv + 1
        } else if snapshotUnseen {
            self.lastAssistantAt = 1
        } else {
            self.lastAssistantAt = nil
        }
        self.isStreaming = (json["isStreaming"] as? Bool) ?? false
    }

    init(
        id: String,
        name: String,
        branchName: String,
        baseBranch: String,
        lifecycleState: String,
        projectId: String,
        contextInstructions: String,
        lastViewedAt: Int64? = nil,
        lastAssistantAt: Int64? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.name = name
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.lifecycleState = lifecycleState
        self.projectId = projectId
        self.contextInstructions = contextInstructions
        self.lastViewedAt = lastViewedAt
        self.lastAssistantAt = lastAssistantAt
        self.isStreaming = isStreaming
    }

    func withName(_ newName: String) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: newName,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: lastViewedAt,
            lastAssistantAt: lastAssistantAt,
            isStreaming: isStreaming
        )
    }

    func withActivity(isStreaming: Bool, lastAssistantAt: Int64?) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: lastViewedAt,
            lastAssistantAt: lastAssistantAt ?? self.lastAssistantAt,
            isStreaming: isStreaming
        )
    }

    func withMarkViewed(at ts: Int64) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: ts,
            lastAssistantAt: lastAssistantAt,
            isStreaming: isStreaming
        )
    }
}
```

- [ ] **Step 2: Handle `workspace.activity` in the delegate**

In the same file, modify `controlClient(_:didReceiveEvent:)` (currently at lines 199–214). Add a new branch before the existing `workspace_updated` branch:

```swift
nonisolated public func controlClient(_ client: ControlClient, didReceiveEvent event: AgentEventEnvelope) {
    if event.type == "workspace.activity" {
        let wsId = event.workspaceId
        let isStreaming = (event.payload["isStreaming"] as? Bool) ?? false
        let lastAssistantAt = (event.payload["lastAssistantAt"] as? NSNumber)?.int64Value
        Task { @MainActor in
            if let idx = self.workspaces.firstIndex(where: { $0.id == wsId }) {
                self.workspaces[idx] = self.workspaces[idx].withActivity(
                    isStreaming: isStreaming,
                    lastAssistantAt: lastAssistantAt
                )
            }
        }
        return
    }
    if event.type == "workspace_updated" {
        // ... existing code unchanged ...
    }
    // ... existing trailing block unchanged ...
}
```

- [ ] **Step 3: Add a `markViewed(workspaceId:)` method on ConnectionStore**

In the same file, add immediately after `requestRename`:

```swift
public func markViewed(workspaceId: String) async {
    do {
        _ = try await client.call(
            method: "workspace.markViewed",
            params: ["workspaceId": workspaceId]
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            workspaces[idx] = workspaces[idx].withMarkViewed(at: now)
        }
    } catch {
        // Non-fatal — the next remote.workspaces refresh will reconcile.
    }
}
```

- [ ] **Step 4: Build the iOS app to verify compilation**

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "RemoteWorkspace gains activity flags + ConnectionStore.markViewed"
```

---

## Task 11: iOS `WorkspacesView` renders indicators + detail calls `markViewed`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift`
- Modify: `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`

- [ ] **Step 1: Render spinner / unseen dot on the row**

In `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift`, replace the row body (around lines 162–180) with:

```swift
ForEach(group.workspaces) { ws in
    NavigationLink(value: ws) {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.body)
                Text(ws.branchName).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if ws.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            } else if ws.unseen {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unseen response")
            }
            LifecyclePill(state: ws.lifecycleState)
        }
    }
    .contextMenu {
        Button { renameTarget = ws } label: {
            Label("Rename…", systemImage: "pencil")
        }
    }
}
```

- [ ] **Step 2: Call `markViewed` in `WorkspaceDetailView.task`**

In `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`, modify the `.task(id:)` block (lines 44–46) to also mark viewed:

```swift
.task(id: workspace.id) {
    await connection.openWorkspace(workspace)
    await connection.markViewed(workspaceId: workspace.id)
}
```

- [ ] **Step 3: Build and test on simulator**

```bash
MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh
```

Manual verification (iPhone simulator paired to a running Mac):
- Trigger a turn on the Mac for a workspace not currently open on iOS.
- Watch the iOS list — the workspace row shows the spinner during streaming.
- After it finishes, the spinner is replaced by a blue dot.
- Tap the row → enter detail → return to list. Dot is gone.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift \
        ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift
git commit -m "iOS: render activity indicators + mark viewed on detail entry"
```

---

## Task 12: End-to-end smoke test + final QA

**Files:** None — manual + integration.

- [ ] **Step 1: Run all tests**

```bash
swift test
cd sidecar && bun run typecheck && bun test
```

Expected: all green.

- [ ] **Step 2: Build app + sidecar release**

```bash
bash scripts/build-app.sh
```

Expected: produces `dist/Multiharness.app` cleanly.

- [ ] **Step 3: Manual matrix**

Verify on Mac (open `dist/Multiharness.app`):

1. Send a prompt in workspace A; immediately switch to workspace B → A's row shows a spinner.
2. Wait for A's response to finish (B is still selected) → A's row replaces the spinner with a blue dot.
3. Click A → dot disappears.
4. While viewing A, send another prompt and let it finish → A keeps no dot (auto-mark on `agent_end` for the selected workspace).
5. Quit the app, simulate further activity (e.g., let an iOS-initiated prompt complete on A), relaunch → A's row shows the dot because `last_viewed_at < last_agent_end` from JSONL.

Verify on iOS (paired to the Mac, simulator):

6. With the iOS list visible, send a Mac-side prompt → spinner appears on the row.
7. After it ends → blue dot.
8. Tap the row → detail view → swipe back → dot is gone.
9. Disconnect/reconnect Tailscale; verify the dot persists across reconnects (data lives on the Mac side, not iOS state).

- [ ] **Step 4: Final commit (only if any cleanup edits were needed)**

If you fixed anything during QA, commit it with a message like:

```bash
git commit -am "QA: <specific fix>"
```

Otherwise, no commit — the plan is complete.

---

## Notes for the implementer

- **WorkspaceActivityTracker is sidecar-only.** The Mac uses its own in-memory `WorkspaceStore.lastAssistantAt` cache fed by `AgentRegistryStore` events; this is intentional — the Mac doesn't go through the relay or the sidecar's tracker.
- **`workspace.activity` event delivers `lastAssistantAt`, not `unseen`.** Each client computes `unseen` itself by comparing against its cached `lastViewedAt`. This avoids requiring the sidecar to re-query SQLite on every transition.
- **iOS bootstraps `lastAssistantAt` via the snapshot's `unseen` boolean.** This is a small lossy hack (we don't know the exact ts on first fetch), but the moment any `workspace.activity` event fires, we have the real value. For any workspace that's been quiescent since launch, the sidecar's snapshot `unseen` flag is authoritative.
- **`markViewed` is idempotent and racy-safe.** Repeatedly calling it just rewrites `last_viewed_at` to "now". The sidecar broadcasts `workspace.activity` after the relay returns; the Mac's local update has already happened by then so it's a no-op for the Mac's own state.
- **Spinner styling matches the existing scale of the lifecycle dot.** If it visually clashes, adjust `scaleEffect` / frame sizes in Task 5 + 11 — keep both platforms consistent.

# Build Mode Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-workspace `buildMode` setting (`primary` / `shadowed`) with a per-project default, surfaced in both Mac and iOS workspace-creation UIs, that injects a contextual addendum into the agent's system prompt when shadowed.

**Architecture:** Append-only migration v3 adds `default_build_mode` to `projects` and `build_mode` to `workspaces` (both nullable; NULL = inherit). The Mac is the source of truth for resolving the effective mode and passes it on `agent.create`. The sidecar's `AgentSession` builds its system prompt from a pure `buildSystemPrompt(mode)` function so the prompt logic is test-first and provider-independent. The Mac stops passing a literal `systemPrompt` over the wire.

**Tech Stack:** Swift (SwiftUI, XCTest, custom SQLite wrapper), TypeScript (Bun, pi-agent-core), JSON-RPC-ish WebSocket protocol.

**Spec:** `docs/superpowers/specs/2026-04-29-build-mode-toggle-design.md`

---

## File Map

**Created:**
- `sidecar/src/prompts.ts` — pure `buildSystemPrompt(mode)` function + constants
- `sidecar/test/prompts.test.ts` — unit tests for prompt assembly
- `Tests/MultiharnessCoreTests/BuildModeTests.swift` — unit tests for precedence + Codable roundtrip

**Modified:**
- `Sources/MultiharnessCore/Persistence/Migrations.swift` — add v3 entry
- `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — extend `upsertProject`, `upsertWorkspace`, `listProjects`, `listWorkspaces` SQL + binding + rowMap
- `Sources/MultiharnessClient/Models/Models.swift` — add `BuildMode` enum, fields on `Project` + `Workspace`, computed `effectiveBuildMode(in: Project)`
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — `create(...)` accepts optional `buildMode`
- `Sources/MultiharnessCore/Stores/AppStore.swift` — `bootstrapAllSessions` resolves and passes `buildMode` instead of `systemPrompt`; new helper `setProjectDefaultBuildMode`
- `Sources/Multiharness/RemoteHandlers.swift` — `workspace.create` parses `buildMode` + `makeProjectDefault`, applies them
- `Sources/Multiharness/Views/Sheets.swift` — `NewWorkspaceSheet` gains segmented control + checkbox
- `sidecar/src/agentSession.ts` — `AgentSessionOptions` takes `buildMode` instead of `systemPrompt`; constructor calls `buildSystemPrompt`
- `sidecar/src/agentRegistry.ts` — propagate the new option (file path inferred from `agent.create` handler in `methods.ts`)
- `sidecar/src/methods.ts` — `agent.create` parses `buildMode` (drop `systemPrompt`)
- `sidecar/test/agentRegistry.test.ts` — update fixtures to pass `buildMode` not `systemPrompt`
- `sidecar/test/e2e.test.ts` — same fixture update
- `Tests/MultiharnessCoreTests/PersistenceTests.swift` — extend roundtrip test to assert build_mode columns
- `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — `createWorkspace` accepts optional `buildMode` + `makeProjectDefault`
- `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` — `NewWorkspaceSheet` gains segmented Picker + Toggle

---

## Task 1: Add `BuildMode` enum to shared models

**Files:**
- Modify: `Sources/MultiharnessClient/Models/Models.swift` (insert after the existing `LifecycleState` enum, around line 25)

- [ ] **Step 1.1: Add the `BuildMode` enum**

Insert this block after line 24 (immediately following the closing `}` of `LifecycleState`):

```swift

public enum BuildMode: String, Codable, CaseIterable, Sendable, Equatable {
    case primary
    case shadowed

    public var label: String {
        switch self {
        case .primary: return "This worktree"
        case .shadowed: return "Local main"
        }
    }
}
```

- [ ] **Step 1.2: Build verifies**

Run: `swift build`
Expected: builds clean (the enum is self-contained, no callers yet).

- [ ] **Step 1.3: Commit**

```bash
git add Sources/MultiharnessClient/Models/Models.swift
git commit -m "Add BuildMode enum to shared models"
```

---

## Task 2: Add `defaultBuildMode` to `Project` struct

**Files:**
- Modify: `Sources/MultiharnessClient/Models/Models.swift` (the `Project` struct, currently lines 26–61)

- [ ] **Step 2.1: Add the property and init parameter**

Edit the `Project` struct. After the line `public var defaultModelId: String?` add:

```swift
    public var defaultBuildMode: BuildMode?
```

After the line `public var repoBookmark: Data?` keep as-is. Then in the `init`, add a parameter `defaultBuildMode: BuildMode? = nil` immediately after `defaultModelId: String? = nil,` and assign `self.defaultBuildMode = defaultBuildMode` in the body, immediately after `self.defaultModelId = defaultModelId`.

The resulting `Project` struct should look like:

```swift
public struct Project: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var repoPath: String
    public var defaultBaseBranch: String
    public var defaultProviderId: UUID?
    public var defaultModelId: String?
    public var defaultBuildMode: BuildMode?
    public var createdAt: Date
    public var repoBookmark: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        repoPath: String,
        defaultBaseBranch: String = "main",
        defaultProviderId: UUID? = nil,
        defaultModelId: String? = nil,
        defaultBuildMode: BuildMode? = nil,
        createdAt: Date = Date(),
        repoBookmark: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.repoPath = repoPath
        self.defaultBaseBranch = defaultBaseBranch
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.defaultBuildMode = defaultBuildMode
        self.createdAt = createdAt
        self.repoBookmark = repoBookmark
    }
}
```

- [ ] **Step 2.2: Build verifies**

Run: `swift build`
Expected: builds clean. (Existing call sites use the default `nil` value.)

- [ ] **Step 2.3: Commit**

```bash
git add Sources/MultiharnessClient/Models/Models.swift
git commit -m "Add Project.defaultBuildMode"
```

---

## Task 3: Add `buildMode` + `effectiveBuildMode` to `Workspace`

**Files:**
- Modify: `Sources/MultiharnessClient/Models/Models.swift` (the `Workspace` struct, currently lines 63–104)

- [ ] **Step 3.1: Add the property, init param, and computed effective accessor**

Replace the entire `Workspace` struct with:

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
        archivedAt: Date? = nil
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
    }

    /// Resolves the effective build mode using the precedence chain:
    /// `workspace.buildMode → project.defaultBuildMode → .primary`.
    public func effectiveBuildMode(in project: Project) -> BuildMode {
        if let m = buildMode { return m }
        if let m = project.defaultBuildMode { return m }
        return .primary
    }
}
```

- [ ] **Step 3.2: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3.3: Commit**

```bash
git add Sources/MultiharnessClient/Models/Models.swift
git commit -m "Add Workspace.buildMode + effectiveBuildMode resolver"
```

---

## Task 4: Unit-test `effectiveBuildMode` precedence

**Files:**
- Create: `Tests/MultiharnessCoreTests/BuildModeTests.swift`

- [ ] **Step 4.1: Write the failing test**

```swift
import XCTest
import MultiharnessClient

final class BuildModeTests: XCTestCase {
    func testEffectiveBuildModeDefaultsToPrimary() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p")
        let ws = workspace(projectId: proj.id, mode: nil)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .primary)
    }

    func testEffectiveBuildModeUsesProjectDefault() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed)
        let ws = workspace(projectId: proj.id, mode: nil)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .shadowed)
    }

    func testWorkspaceOverridesProjectDefault() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed)
        let ws = workspace(projectId: proj.id, mode: .primary)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .primary)
    }

    func testCodableRoundtrip() throws {
        let original = Project(
            name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(restored.defaultBuildMode, .shadowed)
    }

    private func workspace(projectId: UUID, mode: BuildMode?) -> Workspace {
        Workspace(
            projectId: projectId,
            name: "w",
            slug: "w",
            branchName: "u/w",
            baseBranch: "main",
            worktreePath: "/tmp/w",
            providerId: UUID(),
            modelId: "m",
            buildMode: mode
        )
    }
}
```

- [ ] **Step 4.2: Run test to verify it passes**

Run: `swift test --filter BuildModeTests`
Expected: 4 tests pass. (No implementation needed — Tasks 1–3 already provided the behavior.)

- [ ] **Step 4.3: Commit**

```bash
git add Tests/MultiharnessCoreTests/BuildModeTests.swift
git commit -m "Test BuildMode precedence + Codable roundtrip"
```

---

## Task 5: Migration v3 — add `default_build_mode` and `build_mode` columns

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/Migrations.swift`

- [ ] **Step 5.1: Add v3 to the migrations array**

Replace the `all` array (currently lines 49–53) with:

```swift
    public static let all: [String] = [
        v1,
        // v2: persist security-scoped bookmark for the repo path
        "ALTER TABLE projects ADD COLUMN repo_bookmark BLOB;",
        // v3: build mode toggle
        """
        ALTER TABLE projects ADD COLUMN default_build_mode TEXT;
        ALTER TABLE workspaces ADD COLUMN build_mode TEXT;
        """,
    ]
```

- [ ] **Step 5.2: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 5.3: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/Migrations.swift
git commit -m "Migration v3: add build_mode columns"
```

---

## Task 6: Persist `defaultBuildMode` on projects

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/PersistenceService.swift` (`upsertProject` at lines 24–49 and `listProjects` — find it; SELECT pattern matches `listWorkspaces`)

- [ ] **Step 6.1: Update `upsertProject` SQL + bindings**

Replace the body of `upsertProject` (lines 24–49) with:

```swift
    public func upsertProject(_ p: Project) throws {
        try db.executeUpdate(
            """
            INSERT INTO projects (id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              slug=excluded.slug,
              repo_path=excluded.repo_path,
              default_base_branch=excluded.default_base_branch,
              default_provider_id=excluded.default_provider_id,
              default_model_id=excluded.default_model_id,
              default_build_mode=excluded.default_build_mode,
              repo_bookmark=excluded.repo_bookmark;
            """
        ) { st in
            st.bind(1, p.id.uuidString)
            st.bind(2, p.name)
            st.bind(3, p.slug)
            st.bind(4, p.repoPath)
            st.bind(5, p.defaultBaseBranch)
            st.bind(6, p.defaultProviderId?.uuidString)
            st.bind(7, p.defaultModelId)
            st.bind(8, p.defaultBuildMode?.rawValue)
            st.bind(9, p.createdAt)
            st.bind(10, p.repoBookmark)
        }
    }
```

- [ ] **Step 6.2: Update `listProjects` to read the new column**

Replace the `listProjects()` method (currently lines 51–68) with:

```swift
    public func listProjects() throws -> [Project] {
        try db.query(
            "SELECT id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark FROM projects ORDER BY created_at ASC;",
            rowMap: { st in
                Project(
                    id: UUID(uuidString: st.requiredString(0))!,
                    name: st.requiredString(1),
                    slug: st.requiredString(2),
                    repoPath: st.requiredString(3),
                    defaultBaseBranch: st.requiredString(4),
                    defaultProviderId: st.string(5).flatMap { UUID(uuidString: $0) },
                    defaultModelId: st.string(6),
                    defaultBuildMode: st.string(7).flatMap(BuildMode.init(rawValue:)),
                    createdAt: st.requiredDate(8),
                    repoBookmark: st.data(9)
                )
            }
        )
    }
```

- [ ] **Step 6.3: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 6.4: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/PersistenceService.swift
git commit -m "Persist Project.defaultBuildMode"
```

---

## Task 7: Persist `buildMode` on workspaces

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/PersistenceService.swift` (`upsertWorkspace` at lines 129–158 and `listWorkspaces` at lines 161–190)

- [ ] **Step 7.1: Update `upsertWorkspace`**

Replace the body of `upsertWorkspace` with:

```swift
    public func upsertWorkspace(_ w: Workspace) throws {
        try db.executeUpdate(
            """
            INSERT INTO workspaces (id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              archived_at=excluded.archived_at;
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
        }
    }
```

- [ ] **Step 7.2: Update `listWorkspaces`**

Replace the body with:

```swift
    public func listWorkspaces(projectId: UUID? = nil) throws -> [Workspace] {
        let sql: String
        if projectId != nil {
            sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at FROM workspaces WHERE project_id = ? ORDER BY created_at DESC;"
        } else {
            sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at FROM workspaces ORDER BY created_at DESC;"
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
                    archivedAt: st.date(12)
                )
            }
        )
    }
```

- [ ] **Step 7.3: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 7.4: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/PersistenceService.swift
git commit -m "Persist Workspace.buildMode"
```

---

## Task 8: Persistence integration test for build mode roundtrip

**Files:**
- Modify: `Tests/MultiharnessCoreTests/PersistenceTests.swift`

- [ ] **Step 8.1: Add a roundtrip test**

Append to the test class (before the closing `}` of `final class PersistenceTests`):

```swift
    func testBuildModeRoundtripsForProjectAndWorkspace() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed
        )
        try svc.upsertProject(proj)
        let prov = ProviderRecord(
            name: "Local",
            kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1"
        )
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "Feature",
            slug: "feature",
            branchName: "user/feature",
            baseBranch: "main",
            worktreePath: "/tmp/wt",
            providerId: prov.id,
            modelId: "qwen2.5-7b-instruct",
            buildMode: .primary
        )
        try svc.upsertWorkspace(ws)
        let projects = try svc.listProjects()
        XCTAssertEqual(projects.first(where: { $0.id == proj.id })?.defaultBuildMode, .shadowed)
        let workspaces = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertEqual(workspaces.first?.buildMode, .primary)
    }

    func testNullBuildModeStaysNull() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: prov.id, modelId: "m"
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertNil(loaded.first?.buildMode)
        XCTAssertNil(try svc.listProjects().first(where: { $0.id == proj.id })?.defaultBuildMode)
    }
```

- [ ] **Step 8.2: Run tests**

Run: `swift test --filter PersistenceTests`
Expected: all PersistenceTests (including 2 new ones) pass.

- [ ] **Step 8.3: Commit**

```bash
git add Tests/MultiharnessCoreTests/PersistenceTests.swift
git commit -m "Test build_mode roundtrip and NULL preservation"
```

---

## Task 9: Sidecar — extract `buildSystemPrompt` pure function

**Files:**
- Create: `sidecar/src/prompts.ts`
- Create: `sidecar/test/prompts.test.ts`

- [ ] **Step 9.1: Write the failing test**

Create `sidecar/test/prompts.test.ts`:

```typescript
import { describe, it, expect } from "bun:test";
import { buildSystemPrompt, type BuildMode } from "../src/prompts.js";

describe("buildSystemPrompt", () => {
  it("returns the base prompt for primary mode", () => {
    const out = buildSystemPrompt("primary");
    expect(out).toContain("helpful coding agent operating inside a git worktree");
    expect(out).not.toContain("Builds and tests for this project are run by the user");
  });

  it("appends the shadowed addendum for shadowed mode", () => {
    const out = buildSystemPrompt("shadowed");
    expect(out).toContain("helpful coding agent operating inside a git worktree");
    expect(out).toContain("Builds and tests for this project are run by the user");
    expect(out).toContain("Do not run build, test, or run commands");
  });

  it("rejects unknown modes", () => {
    // @ts-expect-error invalid input
    expect(() => buildSystemPrompt("bogus" as BuildMode)).toThrow();
  });
});
```

- [ ] **Step 9.2: Run test to verify it fails**

Run: `cd sidecar && bun test test/prompts.test.ts`
Expected: FAIL — module `../src/prompts.js` not found.

- [ ] **Step 9.3: Implement `prompts.ts`**

Create `sidecar/src/prompts.ts`:

```typescript
export type BuildMode = "primary" | "shadowed";

const BASE = "You are a helpful coding agent operating inside a git worktree. Use the available tools to read and modify files.";

const SHADOWED_ADDENDUM =
  "\n\nBuilds and tests for this project are run by the user against a different checkout, not this worktree. Do not run build, test, or run commands (e.g. `swift build`, `xcodebuild`, `npm test`, `bun run dev`) — you will not get useful feedback from them. Reason carefully from the code; the user will verify.";

export function buildSystemPrompt(mode: BuildMode): string {
  switch (mode) {
    case "primary":
      return BASE;
    case "shadowed":
      return BASE + SHADOWED_ADDENDUM;
    default:
      throw new Error(`unknown build mode: ${String(mode)}`);
  }
}
```

- [ ] **Step 9.4: Run test to verify it passes**

Run: `cd sidecar && bun test test/prompts.test.ts`
Expected: 3 tests pass.

- [ ] **Step 9.5: Typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors.

- [ ] **Step 9.6: Commit**

```bash
git add sidecar/src/prompts.ts sidecar/test/prompts.test.ts
git commit -m "sidecar: add buildSystemPrompt pure function"
```

---

## Task 10: Sidecar — `AgentSession` takes `buildMode` instead of `systemPrompt`

**Files:**
- Modify: `sidecar/src/agentSession.ts`

- [ ] **Step 10.1: Replace `systemPrompt` with `buildMode` in `AgentSessionOptions`**

In `sidecar/src/agentSession.ts`:

Add `import { buildSystemPrompt, type BuildMode } from "./prompts.js";` at the top (with the other imports).

Change `AgentSessionOptions` (currently around lines 14–22) to:

```typescript
export type AgentSessionOptions = {
  workspaceId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  jsonlPath: string;
  sink: EventSink;
  oauthStore?: OAuthStore;
};
```

- [ ] **Step 10.2: Use `buildSystemPrompt` in the constructor**

Inside the `constructor` body, change the line `systemPrompt: opts.systemPrompt,` (currently line 40) to:

```typescript
        systemPrompt: buildSystemPrompt(opts.buildMode),
```

- [ ] **Step 10.3: Typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: errors about `systemPrompt` references in callers (`agentRegistry.ts`, `methods.ts`) — those are fixed in the next task. No errors inside `agentSession.ts` itself.

- [ ] **Step 10.4: Don't commit yet — caller updates land together in Task 11**

---

## Task 11: Sidecar — propagate `buildMode` through `AgentRegistry` and `methods.ts`

**Files:**
- Modify: `sidecar/src/agentRegistry.ts`
- Modify: `sidecar/src/methods.ts` (the `agent.create` registration at lines 32–41)

- [ ] **Step 11.1: Update `AgentRegistry.create` signature**

Open `sidecar/src/agentRegistry.ts`. Find the `create` method (it accepts an options object passed straight to `AgentSession`). Replace its `systemPrompt: string` parameter with `buildMode: BuildMode`. Add `import type { BuildMode } from "./prompts.js";` if needed. Pass `buildMode` through to `new AgentSession({...})`.

- [ ] **Step 11.2: Update `agent.create` handler in `methods.ts`**

Replace the `agent.create` registration (lines 32–41) with:

```typescript
  d.register("agent.create", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const worktreePath = requireString(p, "worktreePath");
    const buildModeRaw = requireString(p, "buildMode");
    if (buildModeRaw !== "primary" && buildModeRaw !== "shadowed") {
      throw new Error(`invalid_build_mode: ${buildModeRaw}`);
    }
    const buildMode = buildModeRaw as "primary" | "shadowed";
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    await registry.create({ workspaceId, worktreePath, buildMode, providerConfig });
    return { ok: true };
  });
```

- [ ] **Step 11.3: Typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors.

- [ ] **Step 11.4: Don't commit yet — tests in Task 12 land in the same commit**

---

## Task 12: Sidecar — update existing fixtures for the new `buildMode` field

**Files:**
- Modify: `sidecar/test/agentRegistry.test.ts` (lines 14–24 and any other `systemPrompt` references)
- Modify: `sidecar/test/e2e.test.ts` (any `systemPrompt` references)

- [ ] **Step 12.1: Replace `systemPrompt` with `buildMode` everywhere in test fixtures**

In `agentRegistry.test.ts`, change every `systemPrompt: "..."` line in the `reg.create({...})` calls to `buildMode: "primary"`.

In `e2e.test.ts`, do the same for any direct calls to `agent.create` or `registry.create`.

If any test references a `systemPrompt` parameter elsewhere (e.g., constructing an `AgentSession` directly), change it to `buildMode: "primary"`.

- [ ] **Step 12.2: Run all sidecar tests**

Run: `cd sidecar && bun test`
Expected: all tests pass (including the new `prompts.test.ts`).

- [ ] **Step 12.3: Commit Tasks 10–12 together**

```bash
git add sidecar/src/agentSession.ts sidecar/src/agentRegistry.ts sidecar/src/methods.ts sidecar/test/agentRegistry.test.ts sidecar/test/e2e.test.ts
git commit -m "sidecar: agent.create accepts buildMode (replaces systemPrompt)"
```

---

## Task 13: Mac — `WorkspaceStore.create` accepts `buildMode`

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` (lines 44–75)

- [ ] **Step 13.1: Add the parameter and pass it through**

Replace the `create` method body with:

```swift
    @discardableResult
    public func create(
        project: Project,
        name: String,
        baseBranch: String,
        provider: ProviderRecord,
        modelId: String,
        gitUserName: String,
        buildMode: BuildMode? = nil
    ) throws -> Workspace {
        let slug = slugify(name)
        let branch = "\(slugify(gitUserName))/\(slug)"
        let path = env.worktree.worktreePath(projectSlug: project.slug, workspaceSlug: slug)
        try env.worktree.createWorktree(
            repoPath: project.repoPath,
            baseBranch: baseBranch,
            branchName: branch,
            worktreePath: path
        )
        let ws = Workspace(
            projectId: project.id,
            name: name,
            slug: slug,
            branchName: branch,
            baseBranch: baseBranch,
            worktreePath: path.path,
            providerId: provider.id,
            modelId: modelId,
            buildMode: buildMode
        )
        try env.persistence.upsertWorkspace(ws)
        workspaces.insert(ws, at: 0)
        selectedWorkspaceId = ws.id
        return ws
    }
```

- [ ] **Step 13.2: Build verifies**

Run: `swift build`
Expected: builds clean. (`buildMode` defaults to `nil`, so the existing call site in `NewWorkspaceSheet.commit()` keeps working.)

- [ ] **Step 13.3: Commit**

```bash
git add Sources/MultiharnessCore/Stores/WorkspaceStore.swift
git commit -m "WorkspaceStore.create accepts optional buildMode"
```

---

## Task 14: Mac — `AppStore.bootstrapAllSessions` resolves and passes `buildMode`

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/AppStore.swift` (lines 42–60 and add a helper at end of class)

- [ ] **Step 14.1: Replace `systemPrompt` with `buildMode` in the params**

Replace the body of `bootstrapAllSessions(workspaces:)` with:

```swift
    public func bootstrapAllSessions(workspaces: [Workspace]) async {
        guard let client = env.control else { return }
        for ws in workspaces where ws.archivedAt == nil {
            guard let provider = providers.first(where: { $0.id == ws.providerId }) else { continue }
            guard let project = projects.first(where: { $0.id == ws.projectId }) else { continue }
            let cfg = providerConfig(provider: provider, modelId: ws.modelId)
            let mode = ws.effectiveBuildMode(in: project)
            let params: [String: Any] = [
                "workspaceId": ws.id.uuidString,
                "worktreePath": ws.worktreePath,
                "buildMode": mode.rawValue,
                "providerConfig": cfg,
            ]
            do {
                _ = try await client.call(method: "agent.create", params: params)
            } catch let e as ControlError {
                if case .remote(_, let msg) = e, msg.contains("already exists") {
                    continue
                }
                FileHandle.standardError.write(
                    "[bootstrap] agent.create for \(ws.name) failed: \(e)\n".data(using: .utf8) ?? Data()
                )
            } catch {
                FileHandle.standardError.write(
                    "[bootstrap] agent.create for \(ws.name) error: \(error)\n".data(using: .utf8) ?? Data()
                )
            }
        }
    }
```

- [ ] **Step 14.2: Add `setProjectDefaultBuildMode` helper**

Add this method somewhere in the same `AppStore` class (style-match the existing methods):

```swift
    @MainActor
    public func setProjectDefaultBuildMode(projectId: UUID, mode: BuildMode) throws {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        var updated = projects[idx]
        updated.defaultBuildMode = mode
        try env.persistence.upsertProject(updated)
        projects[idx] = updated
    }
```

- [ ] **Step 14.3: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 14.4: Run all Swift tests**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 14.5: Commit**

```bash
git add Sources/MultiharnessCore/Stores/AppStore.swift
git commit -m "AppStore: pass buildMode to agent.create; add setProjectDefaultBuildMode"
```

---

## Task 15: Mac — `RemoteHandlers.workspaceCreate` parses `buildMode` + `makeProjectDefault`

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift` (`workspaceCreate` at lines 74–127)

- [ ] **Step 15.1: Parse the new optional params and apply them**

Replace the entire `workspaceCreate` method with:

```swift
    @MainActor
    private static func workspaceCreate(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let projectIdStr = params["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            throw RemoteError.bad("name required")
        }
        guard let providerIdStr = params["providerId"] as? String,
              let providerId = UUID(uuidString: providerIdStr) else {
            throw RemoteError.bad("providerId required (UUID string)")
        }
        guard let modelId = (params["modelId"] as? String)?.trimmingCharacters(in: .whitespaces),
              !modelId.isEmpty else {
            throw RemoteError.bad("modelId required")
        }

        var buildMode: BuildMode? = nil
        if let raw = params["buildMode"] as? String {
            guard let parsed = BuildMode(rawValue: raw) else {
                throw RemoteError.bad("invalid buildMode: \(raw)")
            }
            buildMode = parsed
        }
        let makeProjectDefault = (params["makeProjectDefault"] as? Bool) ?? false

        guard let project = appStore.projects.first(where: { $0.id == projectId }) else {
            throw RemoteError.bad("project not found")
        }
        guard let provider = appStore.providers.first(where: { $0.id == providerId }) else {
            throw RemoteError.bad("provider not found")
        }
        let baseBranch = (params["baseBranch"] as? String) ?? project.defaultBaseBranch
        let userName = NSUserName()

        if makeProjectDefault, let mode = buildMode {
            try appStore.setProjectDefaultBuildMode(projectId: project.id, mode: mode)
        }

        let workspace = try workspaceStore.create(
            project: project,
            name: name,
            baseBranch: baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: userName,
            buildMode: buildMode
        )

        await appStore.bootstrapAllSessions(workspaces: [workspace])

        let resolvedMode = workspace.effectiveBuildMode(
            in: appStore.projects.first(where: { $0.id == project.id }) ?? project
        )

        return [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "branchName": workspace.branchName,
            "worktreePath": workspace.worktreePath,
            "lifecycleState": workspace.lifecycleState.rawValue,
            "modelId": workspace.modelId,
            "buildMode": resolvedMode.rawValue,
        ]
    }
```

- [ ] **Step 15.2: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 15.3: Commit**

```bash
git add Sources/Multiharness/RemoteHandlers.swift
git commit -m "RemoteHandlers: parse buildMode + makeProjectDefault on workspace.create"
```

---

## Task 16: Mac UI — segmented control + checkbox in `NewWorkspaceSheet`

**Files:**
- Modify: `Sources/Multiharness/Views/Sheets.swift` (`NewWorkspaceSheet` at lines 76–148)

- [ ] **Step 16.1: Add state and form rows**

Replace the entire `NewWorkspaceSheet` struct with:

```swift
struct NewWorkspaceSheet: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var providerId: UUID?
    @State private var modelId: String = ""
    @State private var buildMode: BuildMode = .primary
    @State private var makeProjectDefault: Bool = false
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace").font(.title2).bold()
            if let proj = appStore.selectedProject {
                Form {
                    LabeledContent("Project") { Text(proj.name) }
                    TextField("Workspace name", text: $name)
                    TextField("Base branch", text: $baseBranch, prompt: Text(proj.defaultBaseBranch))
                    Picker("Provider", selection: $providerId) {
                        ForEach(appStore.providers) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("Build target", selection: $buildMode) {
                        ForEach(BuildMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Make default for this project",
                        isOn: $makeProjectDefault
                    )
                    .disabled(buildMode == effectiveProjectDefault(proj))
                }
                Divider()
                ModelPicker(
                    appStore: appStore,
                    provider: appStore.providers.first(where: { $0.id == providerId }),
                    modelId: $modelId
                )
            } else {
                Text("No project selected").foregroundStyle(.secondary)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !canCreate)
            }
        }
        .padding(24).frame(width: 600, height: 680)
        .onAppear {
            if let proj = appStore.selectedProject, baseBranch.isEmpty {
                baseBranch = proj.defaultBaseBranch
            }
            if providerId == nil { providerId = appStore.providers.first?.id }
            if let proj = appStore.selectedProject {
                buildMode = effectiveProjectDefault(proj)
            }
        }
        .onChange(of: buildMode) { _, newValue in
            if let proj = appStore.selectedProject,
               newValue == effectiveProjectDefault(proj) {
                makeProjectDefault = false
            }
        }
    }

    private func effectiveProjectDefault(_ proj: Project) -> BuildMode {
        proj.defaultBuildMode ?? .primary
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
        && providerId != nil
        && appStore.selectedProject != nil
    }

    @MainActor
    private func commit() async {
        guard let proj = appStore.selectedProject,
              let pid = providerId,
              let provider = appStore.providers.first(where: { $0.id == pid }) else {
            error = "Missing project or provider"
            return
        }
        creating = true
        defer { creating = false }
        do {
            if makeProjectDefault {
                try appStore.setProjectDefaultBuildMode(projectId: proj.id, mode: buildMode)
            }
            let storedMode: BuildMode? =
                buildMode == effectiveProjectDefault(proj) ? nil : buildMode
            let userName = NSUserName()
            _ = try workspaceStore.create(
                project: proj,
                name: name,
                baseBranch: baseBranch.isEmpty ? proj.defaultBaseBranch : baseBranch,
                provider: provider,
                modelId: modelId,
                gitUserName: userName,
                buildMode: storedMode
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
```

- [ ] **Step 16.2: Build the Mac app**

Run: `bash scripts/build-app.sh CONFIG=debug`
Expected: builds clean. Outputs `dist/Multiharness.app`.

- [ ] **Step 16.3: Commit**

```bash
git add Sources/Multiharness/Views/Sheets.swift
git commit -m "Mac UI: build target segmented control + make-default toggle"
```

---

## Task 16.5: Sidecar — `DataReader` exposes `defaultBuildMode` to iOS

**Files:**
- Modify: `sidecar/src/dataReader.ts` (`listProjects` at lines 28–34)

The iOS app pulls projects through the sidecar's `DataReader` (read-only SQLite views), not via the shared `Project` Codable. `RemoteProject` on iOS must see `defaultBuildMode` to pre-select the segmented control correctly.

- [ ] **Step 16.5.1: Update `listProjects` to include `defaultBuildMode`**

Replace the `listProjects()` method (lines 28–34) with:

```typescript
  listProjects(): Array<{ id: string; name: string; defaultBuildMode: string | null }> {
    if (!this.db) return [];
    const rows = this.db
      .query("SELECT id, name, default_build_mode AS defaultBuildMode FROM projects ORDER BY created_at ASC;")
      .all() as Array<{ id: string; name: string; defaultBuildMode: string | null }>;
    return rows;
  }
```

- [ ] **Step 16.5.2: Typecheck and run sidecar tests**

Run: `cd sidecar && bun run typecheck && bun test`
Expected: all green.

- [ ] **Step 16.5.3: Commit**

```bash
git add sidecar/src/dataReader.ts
git commit -m "sidecar: expose project.defaultBuildMode to iOS"
```

---

## Task 17: iOS — `ConnectionStore.createWorkspace` forwards `buildMode` + `makeProjectDefault`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` (`createWorkspace` at lines 100–113)

- [ ] **Step 17.1: Add params and forward them**

Replace `createWorkspace` with:

```swift
    public func createWorkspace(
        projectId: String,
        name: String,
        baseBranch: String?,
        providerId: String,
        modelId: String,
        buildMode: BuildMode? = nil,
        makeProjectDefault: Bool = false
    ) async throws {
        var params: [String: Any] = [
            "projectId": projectId,
            "name": name,
            "providerId": providerId,
            "modelId": modelId,
        ]
        if let bb = baseBranch, !bb.isEmpty { params["baseBranch"] = bb }
        if let mode = buildMode { params["buildMode"] = mode.rawValue }
        if makeProjectDefault { params["makeProjectDefault"] = true }
        _ = try await client.call(method: "workspace.create", params: params)
        await refreshWorkspaces()
    }
```

(If `BuildMode` isn't already imported via `MultiharnessClient`, add `import MultiharnessClient` at the top of the file. Check the existing imports.)

- [ ] **Step 17.1.5: Add `defaultBuildMode` to `RemoteProject`**

Open `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`. Replace the `RemoteProject` struct (currently lines 204–214) with:

```swift
public struct RemoteProject: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let defaultBuildMode: BuildMode?
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.defaultBuildMode = (json["defaultBuildMode"] as? String).flatMap(BuildMode.init(rawValue:))
    }
}
```

- [ ] **Step 17.2: Build the iOS app**

Run: `bash scripts/build-ios.sh`
Expected: builds clean.

- [ ] **Step 17.3: Don't commit yet — Task 18 lands the iOS UI in the same commit**

---

## Task 18: iOS UI — segmented control + toggle in iOS `NewWorkspaceSheet`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` (`NewWorkspaceSheet` at lines 4–61)

- [ ] **Step 18.1: Add state and form rows**

Replace `NewWorkspaceSheet` with:

```swift
struct NewWorkspaceSheet: View {
    @Bindable var connection: ConnectionStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var projectId: String = ""
    @State private var providerId: String = ""
    @State private var modelId: String = ""
    @State private var buildMode: BuildMode = .primary
    @State private var makeProjectDefault: Bool = false
    @State private var manualMode = false
    @State private var loadedModels: [DiscoveredModel] = []
    @State private var loadingModels = false
    @State private var modelLoadError: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Workspace name", text: $name)
                    Picker("Project", selection: $projectId) {
                        ForEach(connection.projects) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    TextField("Base branch (e.g. main)", text: $baseBranch)
                }
                Section("Build target") {
                    Picker("Build target", selection: $buildMode) {
                        ForEach(BuildMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Make default for this project",
                        isOn: $makeProjectDefault
                    )
                    .disabled(buildMode == effectiveProjectDefault())
                }
                Section {
                    Picker("Provider", selection: $providerId) {
                        ForEach(connection.providers) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    if manualMode {
                        TextField("Model id (e.g. anthropic/claude-sonnet-4-6)",
                                  text: $modelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else if loadingModels {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let err = modelLoadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else if loadedModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $modelId) {
                            Text("Pick a model…").tag("")
                            ForEach(loadedModels) { m in
                                Text(m.displayName).tag(m.id)
                            }
                        }
                    }
                    Toggle("Enter model id manually", isOn: $manualMode)
                        .font(.caption)
                } header: {
                    HStack {
                        Text("Model")
                        Spacer()
                        if !manualMode {
                            Button {
                                Task { await loadModels() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(providerId.isEmpty || loadingModels)
                        }
                    }
                }
                if let err = error {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(working || !canCreate)
                }
            }
        }
        .onAppear {
            projectId = connection.projects.first?.id ?? ""
            providerId = connection.providers.first?.id ?? ""
            buildMode = effectiveProjectDefault()
            Task { await loadModels() }
        }
        .onChange(of: providerId) { _, _ in
            modelId = ""
            loadedModels = []
            modelLoadError = nil
            Task { await loadModels() }
        }
        .onChange(of: projectId) { _, _ in
            buildMode = effectiveProjectDefault()
            makeProjectDefault = false
        }
        .onChange(of: buildMode) { _, newValue in
            if newValue == effectiveProjectDefault() { makeProjectDefault = false }
        }
    }

    private func effectiveProjectDefault() -> BuildMode {
        connection.projects.first(where: { $0.id == projectId })?.defaultBuildMode ?? .primary
    }

    @MainActor
    private func loadModels() async {
        guard !providerId.isEmpty, !manualMode else { return }
        loadingModels = true
        modelLoadError = nil
        defer { loadingModels = false }
        do {
            loadedModels = try await connection.fetchModels(providerId: providerId)
        } catch {
            modelLoadError = String(describing: error)
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
        && !projectId.isEmpty && !providerId.isEmpty
    }

    @MainActor
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let storedMode: BuildMode? =
                buildMode == effectiveProjectDefault() ? nil : buildMode
            try await connection.createWorkspace(
                projectId: projectId,
                name: name,
                baseBranch: baseBranch,
                providerId: providerId,
                modelId: modelId,
                buildMode: storedMode,
                makeProjectDefault: makeProjectDefault
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
```

- [ ] **Step 18.2: Build the iOS app**

Run: `bash scripts/build-ios.sh`
Expected: builds clean. If Xcode caches misbehave, retry with `MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh`.

- [ ] **Step 18.3: Commit Tasks 17 + 18 together**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift ios/Sources/MultiharnessIOS/Views/CreateSheets.swift
git commit -m "iOS: build target segmented control + make-default toggle"
```

---

## Task 19: End-to-end manual verification

- [ ] **Step 19.1: Mac happy-path smoke test**

Run: `bash scripts/build-app.sh CONFIG=debug && open dist/Multiharness.app`

In the running app:
1. Open an existing project, click "New workspace."
2. Confirm the segmented control appears with **This worktree** preselected.
3. Flip to **Local main**. Confirm the "Make default for this project" toggle becomes enabled.
4. Check the toggle, click Create. Watch the sidecar logs (`tail -f ~/Library/Logs/Multiharness/sidecar.log` if available, otherwise the app's stderr).
5. Send the new agent a message like "What build commands should I run?" Confirm the agent's reply mentions that builds happen elsewhere / it shouldn't run them.
6. Open another New workspace sheet. Confirm the segmented control now defaults to **Local main** (the new project default) and the toggle is disabled.

- [ ] **Step 19.2: iOS pairing smoke test**

Run: `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`

Pair the simulator with the running Mac sidecar. Open New workspace from iOS. Confirm:
1. Segmented control matches the project default.
2. "Make default" toggle behaves the same way.
3. Creating a workspace successfully spins up an agent on the Mac.

- [ ] **Step 19.3: Run all tests**

Run from project root:

```bash
swift test && (cd sidecar && bun test) && (cd sidecar && bun run typecheck)
```

Expected: all green.

- [ ] **Step 19.4: Commit if anything was tweaked during smoke testing**

If the smoke tests were clean, no commit. Otherwise commit fixes individually with descriptive messages.

---

## Done

The build mode toggle is now live end-to-end:

- Per-project default + per-workspace override, persisted in SQLite via migration v3.
- Mac and iOS UIs both expose the toggle with a "make default" inline checkbox.
- Sidecar's `agent.create` consumes `buildMode` and assembles the system prompt via `buildSystemPrompt`.
- Agent system prompt picks up the shadowed-mode addendum when the workspace is `shadowed`.
- Bash tool remains available — this is inform-only, no gating.

Out of scope for this PR (will be follow-ups):

- Project settings sheet for editing project defaults outside workspace creation.
- Reconcile-worktrees feature (separate spec, separate plan).
- Customizable shadowed-mode prompt text per project.

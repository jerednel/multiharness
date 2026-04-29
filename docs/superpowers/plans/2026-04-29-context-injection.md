# Context Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-workspace and per-project free-text instructions that are concatenated onto the agent system prompt and applied live on the next turn (including for in-flight sessions).

**Architecture:** Two new TEXT columns (`projects.context_instructions`, `workspaces.context_instructions`, default `''`). The Mac persists edits via SQLite and pushes them to the live `AgentSession` in the sidecar; pi-agent-core reads `_state.systemPrompt` fresh on each turn so mutating it is sufficient. The Mac UI gets a tabbed Inspector (Files / Context); a project-settings sheet hosts the project field. iOS sees both fields read-only.

**Tech Stack:** Swift / SwiftUI (Mac + iOS), Bun + TypeScript (sidecar), `pi-agent-core`, SQLite via the existing `Database` helper.

**Spec:** `docs/superpowers/specs/2026-04-29-context-injection-design.md`

---

## File map

**Persistence (Mac, shared models)**
- Modify `Sources/MultiharnessClient/Models/Models.swift` — add `contextInstructions: String` to `Project` and `Workspace`.
- Modify `Sources/MultiharnessCore/Persistence/Migrations.swift` — append v4 migration.
- Modify `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — round-trip the new column for both tables.
- Modify `Tests/MultiharnessCoreTests/PersistenceTests.swift` — add round-trip tests.

**Sidecar (composition + live update + RPC)**
- Modify `sidecar/src/agentSession.ts` — accept project/workspace context, compose system prompt, expose setters.
- Modify `sidecar/src/agentRegistry.ts` — track `projectId` per session; add fan-out methods.
- Modify `sidecar/src/methods.ts` — extend `agent.create`, register `agent.applyWorkspaceContext`, `agent.applyProjectContext`, relay `workspace.setContext`, `project.setContext`.
- Modify `sidecar/src/dataReader.ts` — include `context_instructions` in the iOS-facing projections.
- Modify `sidecar/test/agentRegistry.test.ts` — fan-out tests.
- Create `sidecar/test/agentSession.test.ts` — `composeSystemPrompt` matrix and live-update assertions.

**Mac wiring**
- Modify `Sources/MultiharnessCore/Stores/AppStore.swift` — pass new context to `agent.create`; add `setWorkspaceContext`, `setProjectContext` helpers that persist + push to sidecar.
- Modify `Sources/Multiharness/RemoteHandlers.swift` — register handlers for `workspace.setContext` and `project.setContext`.

**Mac UI**
- Modify `Sources/Multiharness/Views/WorkspaceDetailView.swift` — refactor `Inspector` into `TabView` (Files / Context).
- Create `Sources/Multiharness/Views/ContextTab.swift` — Context tab body (workspace editor + read-only project header + Copy from CLAUDE.md button).
- Create `Sources/Multiharness/Views/ProjectSettingsSheet.swift` — sheet hosting project context editor.
- Modify `Sources/Multiharness/Views/WorkspaceSidebar.swift` — add "Project settings…" menu entry that opens the sheet.

**iOS**
- Modify `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — add `contextInstructions` to `RemoteWorkspace` and `RemoteProject` JSON parsing.
- Modify `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift` — add a collapsible read-only "Context" disclosure section.

---

## Task 1: Add `contextInstructions` to shared Codable models

**Files:**
- Modify: `Sources/MultiharnessClient/Models/Models.swift:50-142`

- [ ] **Step 1: Add field + init param to `Project`**

In `Sources/MultiharnessClient/Models/Models.swift`, the `Project` struct currently ends with `repoBookmark`. Add a new stored property and init param **after** `repoBookmark`:

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
    public var contextInstructions: String

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
        repoBookmark: Data? = nil,
        contextInstructions: String = ""
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
        self.contextInstructions = contextInstructions
    }
}
```

- [ ] **Step 2: Add field + init param to `Workspace`**

Same file. Add the property after `archivedAt` (last stored property) and the init param at the end of the init list:

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
    public var contextInstructions: String

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
        contextInstructions: String = ""
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
        self.contextInstructions = contextInstructions
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

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: builds without errors. Codable is auto-synthesized, defaults make missing JSON keys decode to `""`.

- [ ] **Step 4: Commit**

```bash
git add Sources/MultiharnessClient/Models/Models.swift
git commit -m "Add contextInstructions to Project and Workspace models"
```

---

## Task 2: Migration v4 — `context_instructions` columns

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/Migrations.swift:50-59`

- [ ] **Step 1: Append v4 to `Migrations.all`**

Replace the existing `all` array literal (currently ends at the v3 entry) with one that has v4 appended. The trailing comma is intentional to match the existing style.

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
    // v4: per-project and per-workspace context injection
    """
    ALTER TABLE projects   ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
    ALTER TABLE workspaces ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
    """,
]
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/Migrations.swift
git commit -m "Add migration v4 for context_instructions columns"
```

---

## Task 3: Round-trip `context_instructions` in PersistenceService

**Files:**
- Modify: `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — `upsertProject`, `listProjects`, `upsertWorkspace`, `listWorkspaces`.

- [ ] **Step 1: Update `upsertProject` SQL + binds**

Find `upsertProject` (line 24). Replace **only the SQL string and the binding closure** — keep the surrounding `try db.executeUpdate(...)` shape:

```swift
public func upsertProject(_ p: Project) throws {
    try db.executeUpdate(
        """
        INSERT INTO projects (id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark, context_instructions)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name,
          slug=excluded.slug,
          repo_path=excluded.repo_path,
          default_base_branch=excluded.default_base_branch,
          default_provider_id=excluded.default_provider_id,
          default_model_id=excluded.default_model_id,
          default_build_mode=excluded.default_build_mode,
          repo_bookmark=excluded.repo_bookmark,
          context_instructions=excluded.context_instructions;
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
        st.bind(11, p.contextInstructions)
    }
}
```

- [ ] **Step 2: Update `listProjects` SELECT + row map**

Find `listProjects` (line 53). Replace it:

```swift
public func listProjects() throws -> [Project] {
    try db.query(
        "SELECT id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark, context_instructions FROM projects ORDER BY created_at ASC;",
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
                repoBookmark: st.data(9),
                contextInstructions: st.string(10) ?? ""
            )
        }
    )
}
```

- [ ] **Step 3: Update `upsertWorkspace` SQL + binds**

Find `upsertWorkspace` (line 132). Replace:

```swift
public func upsertWorkspace(_ w: Workspace) throws {
    try db.executeUpdate(
        """
        INSERT INTO workspaces (id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, context_instructions)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          context_instructions=excluded.context_instructions;
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
        st.bind(14, w.contextInstructions)
    }
}
```

- [ ] **Step 4: Update `listWorkspaces` SELECT + row map**

Find `listWorkspaces` (line 166). Replace:

```swift
public func listWorkspaces(projectId: UUID? = nil) throws -> [Workspace] {
    let sql: String
    if projectId != nil {
        sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, context_instructions FROM workspaces WHERE project_id = ? ORDER BY created_at DESC;"
    } else {
        sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, context_instructions FROM workspaces ORDER BY created_at DESC;"
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
                contextInstructions: st.string(13) ?? ""
            )
        }
    )
}
```

- [ ] **Step 5: Build to verify**

Run: `swift build`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add Sources/MultiharnessCore/Persistence/PersistenceService.swift
git commit -m "Round-trip contextInstructions in PersistenceService"
```

---

## Task 4: Persistence round-trip tests

**Files:**
- Modify: `Tests/MultiharnessCoreTests/PersistenceTests.swift`

- [ ] **Step 1: Add new tests at the end of the class**

Append (before the closing `}` of `final class PersistenceTests`):

```swift
    func testProjectContextInstructionsRoundtrip() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(
            name: "P",
            slug: "p",
            repoPath: "/tmp/p",
            contextInstructions: "Always use pnpm in this repo."
        )
        try svc.upsertProject(proj)
        let loaded = try svc.listProjects()
        XCTAssertEqual(loaded.first?.contextInstructions, "Always use pnpm in this repo.")
    }

    func testWorkspaceContextInstructionsRoundtrip() throws {
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
            providerId: prov.id, modelId: "m",
            contextInstructions: "Prefer SwiftUI over UIKit here."
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertEqual(loaded.first?.contextInstructions, "Prefer SwiftUI over UIKit here.")
    }

    func testEmptyContextInstructionsDefaultIsEmptyString() throws {
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
        XCTAssertEqual(try svc.listProjects().first?.contextInstructions, "")
        XCTAssertEqual(try svc.listWorkspaces(projectId: proj.id).first?.contextInstructions, "")
    }
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter PersistenceTests`
Expected: all PersistenceTests pass, including the three new ones.

- [ ] **Step 3: Commit**

```bash
git add Tests/MultiharnessCoreTests/PersistenceTests.swift
git commit -m "Add persistence tests for contextInstructions"
```

---

## Task 5: Sidecar — `composeSystemPrompt` + live update on `AgentSession`

**Files:**
- Modify: `sidecar/src/agentSession.ts`

- [ ] **Step 1: Replace the file with the new implementation**

Replace the entire contents of `sidecar/src/agentSession.ts` with:

```typescript
import { Agent, type AgentEvent } from "@mariozechner/pi-agent-core";
import { buildModel, apiKeyFor, type ProviderConfig } from "./providers.js";
import { buildTools } from "./tools/index.js";
import { JsonlWriter } from "./jsonl.js";
import { log } from "./logger.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";
import { buildSystemPrompt, type BuildMode } from "./prompts.js";

export type EventSink = (workspaceId: string, ev: AgentEvent) => void;

export type AgentSessionOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  jsonlPath: string;
  sink: EventSink;
  oauthStore?: OAuthStore;
  projectContext?: string;
  workspaceContext?: string;
};

const PERSIST_EVENTS = new Set<AgentEvent["type"]>([
  "agent_start",
  "agent_end",
  "turn_end",
  "message_end",
  "tool_execution_end",
]);

export class AgentSession {
  private readonly agent: Agent;
  private readonly writer: JsonlWriter;
  private readonly unsubscribe: () => void;
  private seq = 0;
  private projectContext: string;
  private workspaceContext: string;

  readonly workspaceId: string;
  readonly projectId: string;

  constructor(private readonly opts: AgentSessionOptions) {
    this.workspaceId = opts.workspaceId;
    this.projectId = opts.projectId;
    this.projectContext = opts.projectContext ?? "";
    this.workspaceContext = opts.workspaceContext ?? "";
    const cfg = opts.providerConfig;
    const staticKey = apiKeyFor(cfg);
    this.agent = new Agent({
      initialState: {
        systemPrompt: this.composeSystemPrompt(),
        model: buildModel(cfg) as any,
        tools: buildTools(opts.worktreePath),
      },
      // OAuth providers (Anthropic Pro/Max) need a fresh access token each
      // request — getApiKey is called by pi-ai right before every API
      // call, so refresh-on-demand happens here.
      getApiKey: async () => {
        if (cfg.kind === "anthropic-oauth") {
          if (!opts.oauthStore) {
            throw new Error("anthropic-oauth requires oauthStore");
          }
          return await getAnthropicAccessToken(opts.oauthStore);
        }
        if (cfg.kind === "openai-codex-oauth") {
          if (!opts.oauthStore) {
            throw new Error("openai-codex-oauth requires oauthStore");
          }
          return await getOpenAICodexAccessToken(opts.oauthStore);
        }
        return staticKey;
      },
    });
    this.writer = new JsonlWriter(opts.jsonlPath);
    this.unsubscribe = this.agent.subscribe((event) => this.handle(event));
  }

  async prompt(message: string): Promise<void> {
    await this.agent.prompt(message);
  }

  async continueRun(): Promise<void> {
    await this.agent.continue();
  }

  abort(): void {
    this.agent.abort();
  }

  setWorkspaceContext(text: string): void {
    this.workspaceContext = text;
    this.agent.state.systemPrompt = this.composeSystemPrompt();
  }

  setProjectContext(text: string): void {
    this.projectContext = text;
    this.agent.state.systemPrompt = this.composeSystemPrompt();
  }

  /** Exposed for testing. */
  currentSystemPrompt(): string {
    return this.agent.state.systemPrompt;
  }

  private composeSystemPrompt(): string {
    const parts: string[] = [buildSystemPrompt(this.opts.buildMode)];
    const proj = this.projectContext.trim();
    if (proj) {
      parts.push(`<project_instructions>\n${this.projectContext}\n</project_instructions>`);
    }
    const ws = this.workspaceContext.trim();
    if (ws) {
      parts.push(`<workspace_instructions>\n${this.workspaceContext}\n</workspace_instructions>`);
    }
    return parts.join("\n\n");
  }

  async dispose(): Promise<void> {
    try {
      this.agent.abort();
    } catch {
      // ignore
    }
    this.unsubscribe();
    await this.writer.close();
  }

  private handle(event: AgentEvent): void {
    this.opts.sink(this.opts.workspaceId, event);
    if (PERSIST_EVENTS.has(event.type)) {
      this.writer
        .append({ seq: this.seq++, ts: Date.now(), event })
        .catch((err) => log.warn("jsonl append failed", { err: String(err) }));
    }
  }
}
```

- [ ] **Step 2: Run typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors. (`AgentRegistry.create` will still typecheck because `projectId` is being added to `CreateOptions` in the next task; that file-level error if any is acceptable here — proceed to next task.)

If typecheck reports a missing `projectId` in `agentRegistry.ts`, that's expected — the next task fixes it.

- [ ] **Step 3: Commit**

```bash
git add sidecar/src/agentSession.ts
git commit -m "Compose system prompt with project + workspace overlays"
```

---

## Task 6: Sidecar — `AgentRegistry` fan-out

**Files:**
- Modify: `sidecar/src/agentRegistry.ts`

- [ ] **Step 1: Update `CreateOptions` and add fan-out methods**

Replace the entire contents of `sidecar/src/agentRegistry.ts` with:

```typescript
import { join } from "node:path";
import { AgentSession, type EventSink } from "./agentSession.js";
import type { ProviderConfig } from "./providers.js";
import type { OAuthStore } from "./oauthStore.js";
import type { BuildMode } from "./prompts.js";

export type CreateOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  projectContext?: string;
  workspaceContext?: string;
};

export class AgentRegistry {
  private readonly sessions = new Map<string, AgentSession>();

  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
    private readonly oauthStore?: OAuthStore,
  ) {}

  async create(opts: CreateOptions): Promise<void> {
    if (this.sessions.has(opts.workspaceId)) {
      throw new Error(`session for workspace ${opts.workspaceId} already exists`);
    }
    const jsonlPath = join(
      this.dataDir,
      "workspaces",
      opts.workspaceId,
      "messages.jsonl",
    );
    const session = new AgentSession({
      ...opts,
      jsonlPath,
      sink: this.sink,
      oauthStore: this.oauthStore,
    });
    this.sessions.set(opts.workspaceId, session);
  }

  get(workspaceId: string): AgentSession {
    const s = this.sessions.get(workspaceId);
    if (!s) throw new Error(`no session for workspace ${workspaceId}`);
    return s;
  }

  has(workspaceId: string): boolean {
    return this.sessions.has(workspaceId);
  }

  list(): string[] {
    return [...this.sessions.keys()];
  }

  /** Push a new workspace context to a single session if present. No-op
   *  when no session exists (the next agent.create will pick up the new
   *  value from the persisted DB). */
  applyWorkspaceContext(workspaceId: string, text: string): void {
    this.sessions.get(workspaceId)?.setWorkspaceContext(text);
  }

  /** Push a new project context to every session whose projectId matches.
   *  O(N) over the in-memory registry; N is small (single-host, single-user). */
  applyProjectContext(projectId: string, text: string): void {
    for (const s of this.sessions.values()) {
      if (s.projectId === projectId) {
        s.setProjectContext(text);
      }
    }
  }

  async dispose(workspaceId: string): Promise<void> {
    const s = this.sessions.get(workspaceId);
    if (!s) return;
    await s.dispose();
    this.sessions.delete(workspaceId);
  }

  async disposeAll(): Promise<void> {
    for (const id of [...this.sessions.keys()]) await this.dispose(id);
  }

  /** Push a synthetic error event through the sink so the UI can stop showing
   *  "Streaming…" forever when a prompt fails before any agent_end fires. */
  emitError(workspaceId: string, message: string): void {
    this.sink(workspaceId, {
      type: "agent_error",
      message,
    } as unknown as Parameters<EventSink>[1]);
    // Also synthesize agent_end so the UI's isStreaming flag clears.
    this.sink(workspaceId, {
      type: "agent_end",
      messages: [],
    } as unknown as Parameters<EventSink>[1]);
  }
}
```

- [ ] **Step 2: Update existing test for required `projectId`**

Existing `agentRegistry.test.ts` calls `reg.create({ workspaceId, worktreePath, buildMode, providerConfig })` without `projectId`. Since it's now required, edit each create call to add `projectId: "p1"`:

```typescript
await reg.create({
  workspaceId: "w1",
  projectId: "p1",
  worktreePath: worktree,
  buildMode: "primary",
  providerConfig: {
    kind: "openai-compatible",
    modelId: "x",
    baseUrl: "http://localhost:1234/v1",
  },
});
```

Apply the same change to **all** `create` calls in `sidecar/test/agentRegistry.test.ts`.

- [ ] **Step 3: Add fan-out tests**

Append to `sidecar/test/agentRegistry.test.ts` (inside the existing `describe("AgentRegistry", () => { ... })` block):

```typescript
  it("applyProjectContext updates only sessions in matching project", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    const cfg = {
      kind: "openai-compatible" as const,
      modelId: "x",
      baseUrl: "http://localhost:1234/v1",
    };
    await reg.create({
      workspaceId: "wA1",
      projectId: "pA",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    await reg.create({
      workspaceId: "wA2",
      projectId: "pA",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    await reg.create({
      workspaceId: "wB1",
      projectId: "pB",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    reg.applyProjectContext("pA", "use pnpm");
    expect(reg.get("wA1").currentSystemPrompt()).toContain("use pnpm");
    expect(reg.get("wA2").currentSystemPrompt()).toContain("use pnpm");
    expect(reg.get("wB1").currentSystemPrompt()).not.toContain("use pnpm");
    await reg.disposeAll();
  });

  it("applyWorkspaceContext updates a single session", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    const cfg = {
      kind: "openai-compatible" as const,
      modelId: "x",
      baseUrl: "http://localhost:1234/v1",
    };
    await reg.create({
      workspaceId: "w1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    reg.applyWorkspaceContext("w1", "prefer SwiftUI");
    expect(reg.get("w1").currentSystemPrompt()).toContain("prefer SwiftUI");
    expect(reg.get("w1").currentSystemPrompt()).toContain("workspace_instructions");
    await reg.disposeAll();
  });

  it("applyWorkspaceContext on missing session is a no-op", () => {
    const reg = new AgentRegistry(dataDir, () => {});
    expect(() => reg.applyWorkspaceContext("none", "x")).not.toThrow();
  });
```

- [ ] **Step 4: Run tests**

Run: `cd sidecar && bun test test/agentRegistry.test.ts`
Expected: all tests pass, including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add sidecar/src/agentRegistry.ts sidecar/test/agentRegistry.test.ts
git commit -m "Add applyProjectContext and applyWorkspaceContext to AgentRegistry"
```

---

## Task 7: AgentSession unit tests for system-prompt composition

**Files:**
- Create: `sidecar/test/agentSession.test.ts`

- [ ] **Step 1: Create the test file**

```typescript
import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentSession } from "../src/agentSession.js";

let dataDir: string;
let worktree: string;
beforeEach(() => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-data-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-wt-")));
});

const baseOpts = (overrides: Partial<Parameters<typeof makeOpts>[0]> = {}) =>
  makeOpts({
    workspaceId: "w1",
    projectId: "p1",
    worktreePath: worktree,
    buildMode: "primary" as const,
    jsonlPath: join(dataDir, "messages.jsonl"),
    sink: () => {},
    ...overrides,
  });

function makeOpts(o: any) {
  return {
    workspaceId: o.workspaceId,
    projectId: o.projectId,
    worktreePath: o.worktreePath,
    buildMode: o.buildMode,
    providerConfig: {
      kind: "openai-compatible" as const,
      modelId: "x",
      baseUrl: "http://localhost:1234/v1",
    },
    jsonlPath: o.jsonlPath,
    sink: o.sink,
    projectContext: o.projectContext,
    workspaceContext: o.workspaceContext,
  };
}

describe("AgentSession composeSystemPrompt", () => {
  it("uses the build-mode base prompt when both overlays empty", async () => {
    const s = new AgentSession(baseOpts());
    expect(s.currentSystemPrompt()).toContain("helpful coding agent");
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("appends only the project block when workspace overlay empty", async () => {
    const s = new AgentSession(baseOpts({ projectContext: "use pnpm" }));
    expect(s.currentSystemPrompt()).toContain("<project_instructions>\nuse pnpm\n</project_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("appends only the workspace block when project overlay empty", async () => {
    const s = new AgentSession(baseOpts({ workspaceContext: "prefer SwiftUI" }));
    expect(s.currentSystemPrompt()).toContain("<workspace_instructions>\nprefer SwiftUI\n</workspace_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    await s.dispose();
  });

  it("appends both blocks in project-then-workspace order", async () => {
    const s = new AgentSession(baseOpts({ projectContext: "P", workspaceContext: "W" }));
    const text = s.currentSystemPrompt();
    expect(text).toContain("<project_instructions>");
    expect(text).toContain("<workspace_instructions>");
    expect(text.indexOf("<project_instructions>")).toBeLessThan(text.indexOf("<workspace_instructions>"));
    await s.dispose();
  });

  it("treats whitespace-only overlays as empty", async () => {
    const s = new AgentSession(baseOpts({ projectContext: "   \n  ", workspaceContext: "\t" }));
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("setWorkspaceContext updates state.systemPrompt live", async () => {
    const s = new AgentSession(baseOpts());
    expect(s.currentSystemPrompt()).not.toContain("workspace_instructions");
    s.setWorkspaceContext("v1");
    expect(s.currentSystemPrompt()).toContain("v1");
    s.setWorkspaceContext("v2");
    expect(s.currentSystemPrompt()).toContain("v2");
    expect(s.currentSystemPrompt()).not.toContain("v1");
    await s.dispose();
  });

  it("setProjectContext updates state.systemPrompt live", async () => {
    const s = new AgentSession(baseOpts());
    s.setProjectContext("project rule");
    expect(s.currentSystemPrompt()).toContain("project rule");
    s.setProjectContext("");
    expect(s.currentSystemPrompt()).not.toContain("project_instructions");
    await s.dispose();
  });
});
```

- [ ] **Step 2: Run the test**

Run: `cd sidecar && bun test test/agentSession.test.ts`
Expected: all 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add sidecar/test/agentSession.test.ts
git commit -m "Add AgentSession composeSystemPrompt and live-update tests"
```

---

## Task 8: Sidecar — register new RPC methods

**Files:**
- Modify: `sidecar/src/methods.ts`

- [ ] **Step 1: Replace the file**

Replace the entire contents of `sidecar/src/methods.ts` with:

```typescript
import type { Dispatcher } from "./dispatcher.js";
import type { AgentRegistry } from "./agentRegistry.js";
import type { ProviderConfig } from "./providers.js";
import { listModels } from "./providers.js";
import { resolveConflictHunk } from "./conflictResolver.js";
import { log } from "./logger.js";
import { DataReader } from "./dataReader.js";
import type { Relay } from "./relay.js";
import {
  hasAnthropicCreds,
  hasOpenAICodexCreds,
  startAnthropicLogin,
  startOpenAICodexLogin,
  type OAuthStore,
} from "./oauthStore.js";

const VERSION = "0.1.0";

type EventEmit = (workspaceId: string, ev: { type: string; [k: string]: unknown }) => void;

export function registerMethods(
  d: Dispatcher,
  registry: AgentRegistry,
  dataDir: string,
  relay: Relay,
  oauthStore: OAuthStore,
  sink: EventEmit,
): void {
  const reader = new DataReader(dataDir);
  d.register("health.ping", () => ({ pong: true, version: VERSION }));

  d.register("agent.create", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const projectId = requireString(p, "projectId");
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
    const projectContext = typeof p.projectContext === "string" ? p.projectContext : "";
    const workspaceContext = typeof p.workspaceContext === "string" ? p.workspaceContext : "";
    await registry.create({
      workspaceId,
      projectId,
      worktreePath,
      buildMode,
      providerConfig,
      projectContext,
      workspaceContext,
    });
    return { ok: true };
  });

  d.register("agent.prompt", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const message = requireString(p, "message");
    registry.get(workspaceId).prompt(message).catch((err) => {
      const reason = err instanceof Error ? err.message : String(err);
      log.error("agent.prompt failed", { workspaceId, err: reason });
      registry.emitError(workspaceId, reason);
    });
    return { ok: true };
  });

  d.register("agent.continue", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    registry.get(workspaceId).continueRun().catch((err) => {
      const reason = err instanceof Error ? err.message : String(err);
      log.error("agent.continue failed", { workspaceId, err: reason });
      registry.emitError(workspaceId, reason);
    });
    return { ok: true };
  });

  d.register("agent.abort", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    registry.get(workspaceId).abort();
    return { ok: true };
  });

  d.register("agent.dispose", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    await registry.dispose(workspaceId);
    return { ok: true };
  });

  d.register("agent.list", () => ({ workspaceIds: registry.list() }));

  d.register("agent.resolveConflictHunk", async (p) => {
    const filePath = requireString(p, "filePath");
    const fileContext = requireString(p, "fileContext");
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    return await resolveConflictHunk({
      providerConfig,
      filePath,
      fileContext,
      oauthStore,
    });
  });

  // Push a context update to any live session. No-op when no session exists.
  d.register("agent.applyWorkspaceContext", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const text = typeof p.contextInstructions === "string" ? p.contextInstructions : "";
    registry.applyWorkspaceContext(workspaceId, text);
    return { ok: true };
  });

  d.register("agent.applyProjectContext", async (p) => {
    const projectId = requireString(p, "projectId");
    const text = typeof p.contextInstructions === "string" ? p.contextInstructions : "";
    registry.applyProjectContext(projectId, text);
    return { ok: true };
  });

  // Read-only views into the Mac app's persisted state, served to iOS.
  d.register("remote.workspaces", () => ({
    workspaces: reader.listWorkspaces(),
    projects: reader.listProjects(),
    providers: reader.listProviders(),
  }));

  d.register("remote.history", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const turns = await reader.historyTurns(workspaceId);
    return { turns };
  });

  d.register("models.list", async (p) => {
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    const models = await listModels(providerConfig);
    return { models };
  });

  // ── OAuth ───────────────────────────────────────────────────────────────
  d.register("auth.anthropic.status", async () => ({
    loggedIn: await hasAnthropicCreds(oauthStore),
  }));

  d.register("auth.anthropic.start", async () => {
    try {
      await startAnthropicLogin(oauthStore, (url) => {
        sink("", { type: "anthropic_auth_url", url });
      });
      sink("", { type: "anthropic_auth_complete", ok: true });
      return { ok: true };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("anthropic oauth login failed", { reason });
      sink("", { type: "anthropic_auth_complete", ok: false, error: reason });
      throw e;
    }
  });

  d.register("auth.openai.status", async () => ({
    loggedIn: await hasOpenAICodexCreds(oauthStore),
  }));

  d.register("auth.openai.start", async () => {
    try {
      await startOpenAICodexLogin(oauthStore, (url) => {
        sink("", { type: "openai_auth_url", url });
      });
      sink("", { type: "openai_auth_complete", ok: true });
      return { ok: true };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("openai-codex oauth login failed", { reason });
      sink("", { type: "openai_auth_complete", ok: false, error: reason });
      throw e;
    }
  });

  // ── Relayed methods ─────────────────────────────────────────────────────
  for (const m of [
    "workspace.create",
    "workspace.setContext",
    "project.scan",
    "project.create",
    "project.setContext",
    "models.listForProvider",
    "fs.list",
  ]) {
    d.register(m, async (params) => {
      return await relay.dispatch(m, params);
    });
  }
}

function requireString(p: Record<string, unknown>, name: string): string {
  const v = p[name];
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return v;
}
```

- [ ] **Step 2: Typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors.

- [ ] **Step 3: Run all sidecar tests**

Run: `cd sidecar && bun test`
Expected: every test passes.

- [ ] **Step 4: Commit**

```bash
git add sidecar/src/methods.ts
git commit -m "Register agent.applyContext and relay workspace/project setContext"
```

---

## Task 9: Update `dataReader` to surface `context_instructions` to iOS

**Files:**
- Modify: `sidecar/src/dataReader.ts`

- [ ] **Step 1: Add the column to the SQL projections**

In `sidecar/src/dataReader.ts`, update `listProjects` and `listWorkspaces`:

Replace `listProjects`:

```typescript
listProjects(): Array<{
  id: string;
  name: string;
  defaultBuildMode: string | null;
  contextInstructions: string;
}> {
  if (!this.db) return [];
  const rows = this.db
    .query(
      "SELECT id, name, default_build_mode AS defaultBuildMode, context_instructions AS contextInstructions FROM projects ORDER BY created_at ASC;",
    )
    .all() as Array<{
      id: string;
      name: string;
      defaultBuildMode: string | null;
      contextInstructions: string;
    }>;
  return rows;
}
```

Replace `listWorkspaces`:

```typescript
listWorkspaces(): Array<{
  id: string;
  name: string;
  branchName: string;
  baseBranch: string;
  lifecycleState: string;
  projectId: string;
  contextInstructions: string;
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
        context_instructions AS contextInstructions
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
    }>;
  return rows;
}
```

- [ ] **Step 2: Typecheck + tests**

Run: `cd sidecar && bun run typecheck && bun test`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add sidecar/src/dataReader.ts
git commit -m "Surface contextInstructions through dataReader projections"
```

---

## Task 10: Mac — pass context to `agent.create` + new `setContext` helpers

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/AppStore.swift`

- [ ] **Step 1: Update `createAgentSession` to send projectId + contexts**

Find `createAgentSession` (line ~71). Replace the `params` dictionary so it sends the new fields, and add a guard that builds `params` from the project's `contextInstructions`:

Change the `params` block (currently lines 83–88) to:

```swift
        let cfg = providerConfig(provider: provider, modelId: workspace.modelId)
        let mode = workspace.effectiveBuildMode(in: project)
        let params: [String: Any] = [
            "workspaceId": workspace.id.uuidString,
            "projectId": project.id.uuidString,
            "worktreePath": workspace.worktreePath,
            "buildMode": mode.rawValue,
            "providerConfig": cfg,
            "projectContext": project.contextInstructions,
            "workspaceContext": workspace.contextInstructions,
        ]
```

- [ ] **Step 2: Add `setWorkspaceContext` + `setProjectContext` helpers**

Append the following methods to `AppStore` (right after `setProjectDefaultBuildMode`, around line 106):

```swift
    /// Persist a new workspace-level context override and push it to the
    /// live agent session if one is running. Safe to call when the workspace
    /// has no live session — the next `agent.create` will pick up the new
    /// value from the persisted DB.
    @MainActor
    public func setWorkspaceContext(workspaceId: UUID, text: String) async throws {
        var loaded = try env.persistence.listWorkspaces(projectId: nil)
        guard let idx = loaded.firstIndex(where: { $0.id == workspaceId }) else { return }
        loaded[idx].contextInstructions = text
        try env.persistence.upsertWorkspace(loaded[idx])
        if let client = env.control {
            _ = try? await client.call(
                method: "agent.applyWorkspaceContext",
                params: [
                    "workspaceId": workspaceId.uuidString,
                    "contextInstructions": text,
                ]
            )
        }
    }

    /// Persist a new project-level context override and push it to every
    /// live agent session inside that project.
    @MainActor
    public func setProjectContext(projectId: UUID, text: String) async throws {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        var updated = projects[idx]
        updated.contextInstructions = text
        try env.persistence.upsertProject(updated)
        projects[idx] = updated
        if let client = env.control {
            _ = try? await client.call(
                method: "agent.applyProjectContext",
                params: [
                    "projectId": projectId.uuidString,
                    "contextInstructions": text,
                ]
            )
        }
    }
```

Note: workspace mutations don't currently flow through `AppStore.projects`/`workspaces` because `WorkspaceStore` owns the workspace list. The DB write is the source of truth; UI components re-read after the call. We could add an in-memory hook later if perf becomes an issue.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/MultiharnessCore/Stores/AppStore.swift
git commit -m "Plumb context overlays through agent.create and AppStore"
```

---

## Task 11: Mac — relay handlers for `workspace.setContext` + `project.setContext`

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift`

- [ ] **Step 1: Register the new handlers**

In `RemoteHandlers.register(...)` (the `static func register` at line 9), append two more `relay.register` calls inside the function body, alongside the existing `workspace.create` / `project.create` registrations:

```swift
        await relay.register(method: "workspace.setContext") { params in
            try await Self.workspaceSetContext(
                params: params, env: env, appStore: appStore
            )
        }
        await relay.register(method: "project.setContext") { params in
            try await Self.projectSetContext(
                params: params, env: env, appStore: appStore
            )
        }
```

- [ ] **Step 2: Add the two static handler methods**

Insert these methods inside the `RemoteHandlers` enum body (e.g. after `projectCreate` and before the closing `}` of the enum):

```swift
    // MARK: - workspace.setContext

    @MainActor
    private static func workspaceSetContext(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore
    ) async throws -> Any? {
        guard let idStr = params["workspaceId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("workspaceId required (UUID string)")
        }
        let text = (params["contextInstructions"] as? String) ?? ""
        try await appStore.setWorkspaceContext(workspaceId: id, text: text)
        return ["ok": true]
    }

    // MARK: - project.setContext

    @MainActor
    private static func projectSetContext(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore
    ) async throws -> Any? {
        guard let idStr = params["projectId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        let text = (params["contextInstructions"] as? String) ?? ""
        try await appStore.setProjectContext(projectId: id, text: text)
        return ["ok": true]
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/Multiharness/RemoteHandlers.swift
git commit -m "Add relay handlers for workspace.setContext and project.setContext"
```

---

## Task 12: Mac UI — Inspector becomes a TabView (Files / Context)

**Files:**
- Modify: `Sources/Multiharness/Views/WorkspaceDetailView.swift`
- Create: `Sources/Multiharness/Views/ContextTab.swift`

- [ ] **Step 1: Refactor `Inspector` to a TabView**

In `Sources/Multiharness/Views/WorkspaceDetailView.swift` find the `Inspector` struct (line 371). Replace its `body` so the existing files-and-preview UI moves into a private subview (`FilesTab`) and the new tab is added. The supporting state and methods stay; only `body` and the new wrapper change.

Replace the existing `Inspector` struct (lines 371–458) with:

```swift
private struct Inspector: View {
    let workspace: Workspace
    let env: AppEnvironment
    @Bindable var appStore: AppStore

    var body: some View {
        TabView {
            FilesTab(workspace: workspace, env: env)
                .tabItem { Label("Files", systemImage: "doc.text") }
            ContextTab(workspace: workspace, appStore: appStore)
                .tabItem { Label("Context", systemImage: "text.alignleft") }
        }
    }
}

private struct FilesTab: View {
    let workspace: Workspace
    let env: AppEnvironment
    @State private var status: WorktreeStatus?
    @State private var statusError: String?
    @State private var fileText: String = ""
    @State private var selectedFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if let err = statusError {
                Text(err).font(.caption).foregroundStyle(.red).padding(12)
            }
            if let s = status {
                List(selection: $selectedFile) {
                    if !s.modifiedFiles.isEmpty {
                        Section("Changed") {
                            ForEach(s.modifiedFiles, id: \.self) { f in
                                Text(f).tag(Optional(f))
                            }
                        }
                    }
                    if !s.untrackedFiles.isEmpty {
                        Section("Untracked") {
                            ForEach(s.untrackedFiles, id: \.self) { f in
                                Text(f).tag(Optional(f))
                            }
                        }
                    }
                    if s.modifiedFiles.isEmpty && s.untrackedFiles.isEmpty {
                        Section { Text("No changes vs \(workspace.baseBranch)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 200)
                Divider()
                ScrollView {
                    Text(fileText).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .textSelection(.enabled)
                }
            } else {
                Spacer()
                ProgressView().padding()
                Spacer()
            }
        }
        .task(id: workspace.id) { await refresh() }
        .onChange(of: selectedFile) { _, _ in
            Task { await loadFile() }
        }
    }

    @MainActor
    private func refresh() async {
        statusError = nil
        do {
            self.status = try env.worktree.status(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch
            )
        } catch {
            statusError = String(describing: error)
        }
    }

    @MainActor
    private func loadFile() async {
        guard let f = selectedFile else { fileText = ""; return }
        let path = (workspace.worktreePath as NSString).appendingPathComponent(f)
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            fileText = data.count > 100_000 ? "(file too large to preview)" : data
        } else {
            fileText = "(unable to read \(path))"
        }
    }
}
```

- [ ] **Step 2: Update the `Inspector(...)` call site to pass `appStore`**

Earlier in the same file (around line 46), change:

```swift
Inspector(workspace: workspace, env: env)
    .frame(minWidth: 320, idealWidth: 380, maxWidth: 600)
```

to:

```swift
Inspector(workspace: workspace, env: env, appStore: appStore)
    .frame(minWidth: 320, idealWidth: 380, maxWidth: 600)
```

- [ ] **Step 3: Create `ContextTab.swift`**

Write a new file `Sources/Multiharness/Views/ContextTab.swift`:

```swift
import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ContextTab: View {
    let workspace: Workspace
    @Bindable var appStore: AppStore

    @State private var workspaceText: String = ""
    @State private var savingWorkspace: SaveState = .idle
    @State private var workspaceDebounceTask: Task<Void, Never>?
    @State private var showProjectSettings = false

    enum SaveState { case idle, saving, saved, error(String) }

    private var project: Project? {
        appStore.projects.first(where: { $0.id == workspace.projectId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Context").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSection
                    workspaceSection
                }
                .padding(12)
            }
        }
        .task(id: workspace.id) {
            workspaceText = workspace.contextInstructions
            savingWorkspace = .idle
        }
        .sheet(isPresented: $showProjectSettings) {
            if let p = project {
                ProjectSettingsSheet(
                    project: p,
                    appStore: appStore,
                    onClose: { showProjectSettings = false }
                )
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Project").font(.subheadline).bold()
                Spacer()
                Button("Edit in project settings →") {
                    showProjectSettings = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            let projectText = project?.contextInstructions ?? ""
            if projectText.isEmpty {
                Text("No project-wide instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(projectText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Workspace").font(.subheadline).bold()
                Spacer()
                statusLabel
            }
            TextEditor(text: $workspaceText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .padding(4)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: workspaceText) { _, new in
                    scheduleSave(new)
                }
            HStack {
                Button("Copy from CLAUDE.md") { copyFromClaudeMd() }
                    .disabled(!claudeMdExists)
                    .help(claudeMdExists ? "Replace the workspace context with this worktree's CLAUDE.md" : "No CLAUDE.md found in this worktree")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch savingWorkspace {
        case .idle: EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved:
            Text("Saved").font(.caption).foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    private var claudeMdPath: String {
        (workspace.worktreePath as NSString).appendingPathComponent("CLAUDE.md")
    }

    private var claudeMdExists: Bool {
        FileManager.default.fileExists(atPath: claudeMdPath)
    }

    private func copyFromClaudeMd() {
        guard let data = try? String(contentsOfFile: claudeMdPath, encoding: .utf8) else {
            savingWorkspace = .error("Could not read CLAUDE.md")
            return
        }
        workspaceText = data
        scheduleSave(data)
    }

    private func scheduleSave(_ text: String) {
        workspaceDebounceTask?.cancel()
        savingWorkspace = .saving
        workspaceDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                try await appStore.setWorkspaceContext(workspaceId: workspace.id, text: text)
                savingWorkspace = .saved
            } catch {
                savingWorkspace = .error(String(describing: error))
            }
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds. There will be a missing `ProjectSettingsSheet` symbol — that's the next task.

If you get *only* `cannot find 'ProjectSettingsSheet' in scope`, proceed. Any other error must be fixed first.

- [ ] **Step 5: Commit**

```bash
git add Sources/Multiharness/Views/WorkspaceDetailView.swift Sources/Multiharness/Views/ContextTab.swift
git commit -m "Tab the Inspector with a Context tab; workspace context editor"
```

---

## Task 13: Mac UI — `ProjectSettingsSheet`

**Files:**
- Create: `Sources/Multiharness/Views/ProjectSettingsSheet.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ProjectSettingsSheet: View {
    let project: Project
    @Bindable var appStore: AppStore
    var onClose: () -> Void

    @State private var text: String = ""
    @State private var saveState: SaveState = .idle
    @State private var debounceTask: Task<Void, Never>?

    enum SaveState { case idle, saving, saved, error(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project settings").font(.title3).bold()
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            Text(project.name).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context").font(.subheadline).bold()
                    Spacer()
                    statusLabel
                }
                Text("Applies to every workspace in this project. Injected on every turn.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding(4)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: text) { _, new in
                        scheduleSave(new)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
        .task(id: project.id) {
            text = project.contextInstructions
            saveState = .idle
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch saveState {
        case .idle: EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved:
            Text("Saved").font(.caption).foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    private func scheduleSave(_ value: String) {
        debounceTask?.cancel()
        saveState = .saving
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                try await appStore.setProjectContext(projectId: project.id, text: value)
                saveState = .saved
            } catch {
                saveState = .error(String(describing: error))
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/Multiharness/Views/ProjectSettingsSheet.swift
git commit -m "Add ProjectSettingsSheet to edit project-wide context"
```

---

## Task 14: Sidebar — "Project settings…" menu entry

**Files:**
- Modify: `Sources/Multiharness/Views/WorkspaceSidebar.swift`

- [ ] **Step 1: Add a `@State` flag and sheet binding to `ProjectDisclosure`**

Find the `ProjectDisclosure` struct (around line 110+) in `Sources/Multiharness/Views/WorkspaceSidebar.swift`. Add this stored property next to the other `@State` declarations (e.g. next to `@State private var groupByStatus`):

```swift
    @State private var showSettings = false
```

Locate the `init` at line 119+ — no init changes are needed.

Locate the `body` at line 138+. Replace the existing `body` with a version that adds a `.sheet` modifier:

```swift
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            header
        }
        .onChange(of: isExpanded) { _, new in
            UserDefaults.standard.set(new, forKey: Self.expandedKey(project.id))
        }
        .onChange(of: groupByStatus) { _, new in
            UserDefaults.standard.set(new, forKey: Self.groupKey(project.id))
        }
        .sheet(isPresented: $showSettings) {
            ProjectSettingsSheet(
                project: currentProject,
                appStore: appStore,
                onClose: { showSettings = false }
            )
        }
    }

    private var currentProject: Project {
        appStore.projects.first(where: { $0.id == project.id }) ?? project
    }
```

- [ ] **Step 2: Add `@Bindable var appStore: AppStore` to `ProjectDisclosure`**

`ProjectDisclosure` does not currently take `appStore`. Add the property and an init parameter. At the top of the struct, add:

```swift
    @Bindable var appStore: AppStore
```

Update the `init` signature to accept and store `appStore`. The init (currently lines 119-136 region) should become:

```swift
    init(
        project: Project,
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        onQuickCreate: @escaping () -> Void,
        onReconcile: @escaping () -> Void
    ) {
        self.project = project
        self.appStore = appStore
        self.workspaceStore = workspaceStore
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
```

- [ ] **Step 3: Update every `ProjectDisclosure(...)` call site**

Search the file for `ProjectDisclosure(` and add `appStore: appStore,` to each call:

```swift
ProjectDisclosure(
    project: proj,
    appStore: appStore,
    workspaceStore: workspaceStore,
    onQuickCreate: { ... },
    onReconcile: { ... }
)
```

If the parent view (`WorkspaceSidebar` itself) doesn't already take `appStore`, find its `body` / property list — the sidebar already accesses `appStore` (it lives in the same file as projects iteration). Add `@Bindable var appStore: AppStore` to `WorkspaceSidebar` too if missing, and update the sidebar's call sites in `MainView.swift` / wherever `WorkspaceSidebar` is instantiated to pass `appStore`. Run `swift build` after to find missed call sites.

- [ ] **Step 4: Add the menu item**

Locate `header` (line 152). Inside the existing `Menu { Toggle(...) }` block, add a Divider and a Button:

```swift
            Menu {
                Toggle("Group by status", isOn: $groupByStatus)
                Divider()
                Button("Project settings…") {
                    showSettings = true
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: success. If a call site of `ProjectDisclosure` or `WorkspaceSidebar` is missed the compiler will say so — wire `appStore` through and rebuild.

- [ ] **Step 6: Commit**

```bash
git add Sources/Multiharness/Views/WorkspaceSidebar.swift
# plus any other files where you wired appStore through
git commit -m "Add Project settings menu entry to sidebar"
```

---

## Task 15: Mac smoke test — full build runs

**Files:**
- (none — verification only)

- [ ] **Step 1: Run the Swift test suite**

Run: `swift test`
Expected: all tests pass, including the new persistence tests from Task 4.

- [ ] **Step 2: Build the Mac .app bundle**

Run: `bash scripts/build-app.sh`
Expected: produces `dist/Multiharness.app`. No errors.

- [ ] **Step 3: Commit any incidental fixes**

If the build surfaces issues that required code changes, commit them under a descriptive message; otherwise no commit is needed.

---

## Task 16: iOS — surface `contextInstructions` in `RemoteWorkspace` / `RemoteProject`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`

- [ ] **Step 1: Update `RemoteWorkspace`**

Find `public struct RemoteWorkspace` (line 208). Add a stored property and parse it from JSON:

```swift
public struct RemoteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let branchName: String
    public let baseBranch: String
    public let lifecycleState: String
    public let projectId: String
    public let contextInstructions: String

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
    }
}
```

- [ ] **Step 2: Update `RemoteProject`**

```swift
public struct RemoteProject: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let defaultBuildMode: BuildMode?
    public let contextInstructions: String
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.defaultBuildMode = (json["defaultBuildMode"] as? String).flatMap(BuildMode.init(rawValue:))
        self.contextInstructions = json["contextInstructions"] as? String ?? ""
    }
}
```

- [ ] **Step 3: Build iOS**

Run: `bash scripts/build-ios.sh`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "Decode contextInstructions on iOS RemoteWorkspace and RemoteProject"
```

---

## Task 17: iOS — read-only Context disclosure on workspace detail

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`

- [ ] **Step 1: Add a Context disclosure section above the conversation**

Replace the body of `WorkspaceDetailView` with one that includes a top section containing the Context disclosure (collapsed by default, hidden when both fields are empty):

```swift
struct WorkspaceDetailView: View {
    @Bindable var connection: ConnectionStore
    let workspace: RemoteWorkspace
    @State private var draft = ""
    @State private var contextExpanded = false

    private var project: RemoteProject? {
        connection.projects.first(where: { $0.id == workspace.projectId })
    }

    private var hasContext: Bool {
        !workspace.contextInstructions.isEmpty
            || !(project?.contextInstructions.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasContext {
                contextDisclosure
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Divider()
            }
            if let agent = connection.agents[workspace.id] {
                ConversationList(agent: agent, workspaceId: workspace.id)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            Divider()
            Composer(
                draft: $draft,
                isStreaming: connection.agents[workspace.id]?.isStreaming ?? false,
                onSend: { text in
                    Task { await connection.sendPrompt(workspaceId: workspace.id, message: text) }
                }
            )
            .padding(8)
        }
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workspace.id) {
            await connection.openWorkspace(workspace)
        }
    }

    @ViewBuilder
    private var contextDisclosure: some View {
        DisclosureGroup(isExpanded: $contextExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let p = project, !p.contextInstructions.isEmpty {
                    Text("Project").font(.caption).bold().foregroundStyle(.secondary)
                    Text(p.contextInstructions)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if !workspace.contextInstructions.isEmpty {
                    Text("Workspace").font(.caption).bold().foregroundStyle(.secondary)
                    Text(workspace.contextInstructions)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.caption)
                Text("Context").font(.caption).bold()
            }
        }
    }
}
```

The rest of the file (`ConversationList`, `TurnRow`, `ThinkingRow`, `Composer`) is unchanged.

- [ ] **Step 2: Build iOS**

Run: `bash scripts/build-ios.sh`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift
git commit -m "Show read-only Context disclosure on iOS workspace view"
```

---

## Task 18: Final verification

- [ ] **Step 1: Run all sidecar tests**

Run: `cd sidecar && bun test`
Expected: every test passes.

- [ ] **Step 2: Run all Swift tests**

Run: `swift test`
Expected: every test passes.

- [ ] **Step 3: Build the Mac app**

Run: `bash scripts/build-app.sh`
Expected: success, produces `dist/Multiharness.app`.

- [ ] **Step 4: Build iOS**

Run: `bash scripts/build-ios.sh`
Expected: success.

- [ ] **Step 5: Open a PR**

```bash
git push -u origin jerednel/context-injection
gh pr create --base main --title "Context injection (workspace + project)"
# fill out body summarizing the spec, the persistence change, and manual verification needed
```

---

## Self-review summary

- Spec section 1 (data model) → Tasks 1–4.
- Spec section 2 (wire protocol) → Tasks 8, 9, 10, 11.
- Spec section 3 (sidecar injection / live update) → Tasks 5, 6, 7.
- Spec section 4 (Mac UI: tabbed Inspector, project sheet, sidebar menu, copy-from-CLAUDE.md, debounced save) → Tasks 12, 13, 14.
- Spec section 5 (iOS read-only) → Tasks 16, 17.
- Final verification + PR → Tasks 15, 18.

No placeholders. All types and method names are consistent across tasks (`contextInstructions`, `setWorkspaceContext`, `setProjectContext`, `applyWorkspaceContext`, `applyProjectContext`, `composeSystemPrompt`).

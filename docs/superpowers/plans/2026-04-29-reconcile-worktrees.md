# Reconcile Worktrees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a project-level "Reconcile" button on the Mac that takes all workspaces in `.done` or `.inReview` lifecycle states and sequentially merges their branches into a fresh integration workspace, with one-shot LLM conflict resolution per file.

**Architecture:** A new Mac-side `ReconcileCoordinator` actor drives the run via the existing `WorktreeService` (extended with `merge`, `mergeAbort`, `unmergedFiles`, `stage`, `commit`, `isLikelyBinary`). Conflict resolution goes through a new sidecar RPC `agent.resolveConflictHunk` that calls `pi-ai`'s `complete()` directly — no `Agent` wrapper. The integration result is a regular `Workspace` row created via the existing `WorkspaceStore.create(...)` path; no new persistence schema. UI is a single `ReconcileSheet` that flips between trigger and progress views based on coordinator phase, triggered from buttons in `ProjectPickerHeader` and `ProjectDisclosure.header`.

**Tech Stack:** Swift (SwiftUI, XCTest, Foundation `Process` for git), TypeScript (Bun, `@mariozechner/pi-ai` `complete()` function).

**Spec:** `docs/superpowers/specs/2026-04-29-reconcile-worktrees-design.md`

---

## File Map

**Created:**
- `Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift` — actor + state machine.
- `Sources/Multiharness/Views/ReconcileSheet.swift` — trigger + progress UI.
- `sidecar/src/conflictResolver.ts` — `resolveConflictHunk` function.
- `sidecar/test/conflictResolver.test.ts` — unit tests with stubbed `complete`.
- `Tests/MultiharnessCoreTests/WorktreeServiceMergeTests.swift` — real-git tests for merge/abort/unmerged.
- `Tests/MultiharnessCoreTests/ReconcileCoordinatorTests.swift` — state-machine tests with stubs.

**Modified:**
- `Sources/MultiharnessCore/Worktree/WorktreeService.swift` — add merge methods.
- `sidecar/src/methods.ts` — register `agent.resolveConflictHunk`.
- `Sources/Multiharness/Views/RootView.swift` — add Reconcile button to `ProjectPickerHeader`.
- `Sources/Multiharness/Views/WorkspaceSidebar.swift` — add Reconcile button to `ProjectDisclosure.header`.

---

## Task 1: Extend `WorktreeService` with merge primitives

**Files:**
- Modify: `Sources/MultiharnessCore/Worktree/WorktreeService.swift`

- [ ] **Step 1.1: Add `MergeResult` enum and the new methods**

Append to `WorktreeService` (before its closing `}` brace, currently around line 110):

```swift
    public enum MergeResult: Equatable, Sendable {
        case clean
        case conflicts(unmergedFiles: [String])
    }

    /// Runs `git merge --no-ff --no-commit <sourceBranch>` in `worktreePath`.
    /// On a clean merge with no conflicts, returns `.clean` and the caller
    /// commits explicitly. On conflicts, parses unmerged paths and returns
    /// them; caller is responsible for resolving + staging + committing or
    /// calling `mergeAbort`.
    public func merge(worktreePath: URL, sourceBranch: String) throws -> MergeResult {
        do {
            _ = try runGit(at: worktreePath.path, args: [
                "merge", "--no-ff", "--no-commit", sourceBranch,
            ])
            return .clean
        } catch let WorktreeError.gitFailed(_, _, _) {
            // git merge exits non-zero on conflicts. Distinguish "had
            // conflicts" from "couldn't run at all" by checking unmerged.
            let unmerged = try unmergedFiles(worktreePath: worktreePath)
            if unmerged.isEmpty {
                // No unmerged paths but merge failed → genuine error.
                throw WorktreeError.gitFailed(
                    args: ["merge", "--no-ff", "--no-commit", sourceBranch],
                    exitCode: -1,
                    stderr: "merge failed without conflicts"
                )
            }
            return .conflicts(unmergedFiles: unmerged)
        }
    }

    /// Runs `git merge --abort`. Idempotent — silently succeeds if no merge
    /// is in progress.
    public func mergeAbort(worktreePath: URL) throws {
        _ = try? runGit(at: worktreePath.path, args: ["merge", "--abort"])
    }

    /// Returns paths of currently unmerged files.
    /// Output of `git diff --name-only --diff-filter=U`.
    public func unmergedFiles(worktreePath: URL) throws -> [String] {
        let out = try runGit(at: worktreePath.path, args: [
            "diff", "--name-only", "--diff-filter=U",
        ])
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Stage a path (`git add <path>`).
    public func stage(worktreePath: URL, path: String) throws {
        _ = try runGit(at: worktreePath.path, args: ["add", "--", path])
    }

    /// Commit staged changes with `message`.
    public func commit(worktreePath: URL, message: String) throws {
        _ = try runGit(at: worktreePath.path, args: ["commit", "-m", message])
    }

    /// Returns true if the file looks binary. We rely on git's own
    /// detection: `git diff --numstat` shows "-\t-\t<path>" for binary
    /// files. For files that don't exist or aren't tracked, returns false.
    public func isLikelyBinary(worktreePath: URL, path: String) -> Bool {
        guard let out = try? runGit(at: worktreePath.path, args: [
            "diff", "--numstat", "HEAD", "--", path,
        ]) else { return false }
        return out.contains("-\t-\t")
    }
```

- [ ] **Step 1.2: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 1.3: Commit**

```bash
git add Sources/MultiharnessCore/Worktree/WorktreeService.swift
git commit -m "WorktreeService: add merge primitives"
```

---

## Task 2: Real-git tests for the merge primitives

**Files:**
- Create: `Tests/MultiharnessCoreTests/WorktreeServiceMergeTests.swift`

- [ ] **Step 2.1: Write the failing test file**

```swift
import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class WorktreeServiceMergeTests: XCTestCase {
    var repoDir: URL!
    var worktreeDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-merge-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testCleanMerge() throws {
        // branch A: append line
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-a"])
        try "hello\nfrom a\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "a"])
        // back to main, create integration branch
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "integration"])
        // merge feature-a into integration; expect clean
        let result = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-a")
        XCTAssertEqual(result, .clean)
        try svc.commit(worktreePath: repoDir, message: "Reconcile: merge feature-a")
    }

    func testConflictingMerge() throws {
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-a"])
        try "hello\nfrom a\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "a"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-b"])
        try "hello\nfrom b\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "b"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "integration"])
        _ = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-a")
        try svc.commit(worktreePath: repoDir, message: "Reconcile: merge feature-a")
        let result = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-b")
        guard case .conflicts(let files) = result else {
            return XCTFail("expected .conflicts, got \(result)")
        }
        XCTAssertEqual(files, ["a.txt"])
    }

    func testMergeAbortRestoresClean() throws {
        try testConflictingMerge()
        try svc.mergeAbort(worktreePath: repoDir)
        let unmerged = try svc.unmergedFiles(worktreePath: repoDir)
        XCTAssertEqual(unmerged, [])
    }

    func testStageAndCommit() throws {
        try "manually resolved\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        try svc.stage(worktreePath: repoDir, path: "a.txt")
        try svc.commit(worktreePath: repoDir, message: "manual fix")
        let log = try svc.runGit(at: repoDir.path, args: ["log", "--oneline", "-1"])
        XCTAssertTrue(log.contains("manual fix"))
    }
}
```

- [ ] **Step 2.2: Run tests**

Run: `swift test --filter WorktreeServiceMergeTests`
Expected: 4 tests pass.

- [ ] **Step 2.3: Commit**

```bash
git add Tests/MultiharnessCoreTests/WorktreeServiceMergeTests.swift
git commit -m "Test WorktreeService merge primitives"
```

---

## Task 3: Sidecar conflict resolver — pure function + DI

**Files:**
- Create: `sidecar/src/conflictResolver.ts`
- Create: `sidecar/test/conflictResolver.test.ts`

- [ ] **Step 3.1: Write the failing test**

Create `sidecar/test/conflictResolver.test.ts`:

```typescript
import { describe, it, expect } from "bun:test";
import {
  resolveConflictHunk,
  type CompleteFn,
} from "../src/conflictResolver.js";
import type { ProviderConfig } from "../src/providers.js";

const cfg: ProviderConfig = {
  kind: "openai-compatible",
  modelId: "mock",
  baseUrl: "http://localhost:0/v1",
  apiKey: "sk-mock",
};

function fakeComplete(text: string): CompleteFn {
  return async () => ({
    role: "assistant",
    content: [{ type: "text", text }],
    api: "openai-completions",
    provider: "openai-compatible",
    model: "mock",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: "stop",
    timestamp: Date.now(),
  } as any);
}

describe("resolveConflictHunk", () => {
  const fileContext = "line 1\n<<<<<<< HEAD\nfrom a\n=======\nfrom b\n>>>>>>> feature-b\nline 3\n";

  it("returns resolved text when the model produces a clean response", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("line 1\nfrom a and from b\nline 3\n"),
    );
    expect(out.outcome).toBe("resolved");
    if (out.outcome === "resolved") {
      expect(out.content).toContain("from a and from b");
    }
  });

  it("parses __DECLINED__ as a decline with reason", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("__DECLINED__ ambiguous semantic intent"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("ambiguous");
    }
  });

  it("declines responses that still contain conflict markers", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("line 1\n<<<<<<< HEAD\nfrom a\n=======\nfrom b\n>>>>>>> feature-b\nline 3\n"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("markers");
    }
  });

  it("declines responses that are too short", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("ok"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("too short");
    }
  });

  it("declines empty responses", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete(""),
    );
    expect(out.outcome).toBe("declined");
  });
});
```

- [ ] **Step 3.2: Run test to verify it fails**

Run: `cd sidecar && bun test test/conflictResolver.test.ts`
Expected: FAIL — module `../src/conflictResolver.js` not found.

- [ ] **Step 3.3: Implement `conflictResolver.ts`**

Create `sidecar/src/conflictResolver.ts`:

```typescript
import { complete } from "@mariozechner/pi-ai";
import { buildModel, type ProviderConfig } from "./providers.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";

export type ResolveOutcome =
  | { outcome: "resolved"; content: string }
  | { outcome: "declined"; reason: string };

export type CompleteFn = typeof complete;

const SYSTEM_PROMPT =
  "You are resolving a 3-way merge conflict. The user has shown you the full text of one file containing one or more `<<<<<<<` / `=======` / `>>>>>>>` conflict markers. Output the complete file with all conflicts resolved — no commentary, no markdown fences, no explanation. If you cannot resolve a conflict because the two sides express incompatible intent that requires human judgment, instead output the literal token `__DECLINED__` followed by a single short sentence explaining why.";

export async function resolveConflictHunk(
  args: {
    providerConfig: ProviderConfig;
    filePath: string;
    fileContext: string;
    oauthStore?: OAuthStore;
    signal?: AbortSignal;
  },
  completeFn: CompleteFn = complete,
): Promise<ResolveOutcome> {
  const { providerConfig, fileContext, oauthStore, signal } = args;
  const apiKey = await resolveApiKey(providerConfig, oauthStore);
  const model = buildModel(providerConfig);
  const result = await completeFn(
    model as any,
    {
      systemPrompt: SYSTEM_PROMPT,
      messages: [
        { role: "user", content: [{ type: "text", text: fileContext }] },
      ],
    },
    { apiKey, signal, maxTokens: 8192 },
  );
  const text = extractText(result);
  if (!text) return { outcome: "declined", reason: "model returned no text" };
  if (text.startsWith("__DECLINED__")) {
    const reason =
      text.slice("__DECLINED__".length).trim() || "no reason given";
    return { outcome: "declined", reason };
  }
  if (text.length < fileContext.length * 0.5) {
    return { outcome: "declined", reason: "malformed response (too short)" };
  }
  if (text.includes("<<<<<<<")) {
    return {
      outcome: "declined",
      reason: "malformed response (unresolved markers)",
    };
  }
  return { outcome: "resolved", content: text };
}

async function resolveApiKey(
  cfg: ProviderConfig,
  oauthStore?: OAuthStore,
): Promise<string | undefined> {
  if (cfg.kind === "anthropic-oauth") {
    if (!oauthStore) throw new Error("anthropic-oauth requires oauthStore");
    return await getAnthropicAccessToken(oauthStore);
  }
  if (cfg.kind === "openai-codex-oauth") {
    if (!oauthStore) throw new Error("openai-codex-oauth requires oauthStore");
    return await getOpenAICodexAccessToken(oauthStore);
  }
  return cfg.apiKey;
}

function extractText(msg: { content: any[] }): string {
  return msg.content
    .filter((p) => p.type === "text")
    .map((p) => p.text as string)
    .join("");
}
```

- [ ] **Step 3.4: Run test to verify it passes**

Run: `cd sidecar && bun test test/conflictResolver.test.ts`
Expected: 5 tests pass.

- [ ] **Step 3.5: Typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors.

- [ ] **Step 3.6: Commit**

```bash
git add sidecar/src/conflictResolver.ts sidecar/test/conflictResolver.test.ts
git commit -m "sidecar: add conflict resolver pure function + tests"
```

---

## Task 4: Sidecar — register `agent.resolveConflictHunk` RPC

**Files:**
- Modify: `sidecar/src/methods.ts`

- [ ] **Step 4.1: Add the import and registration**

In `sidecar/src/methods.ts`:

After the existing imports, add:

```typescript
import { resolveConflictHunk } from "./conflictResolver.js";
```

Inside `registerMethods` (right after the `agent.list` registration around line 56, before the `remote.workspaces` block), add:

```typescript
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
```

- [ ] **Step 4.2: Run all sidecar tests**

Run: `cd sidecar && bun run typecheck && bun test`
Expected: all green (47 + 5 = 52 tests).

- [ ] **Step 4.3: Commit**

```bash
git add sidecar/src/methods.ts
git commit -m "sidecar: register agent.resolveConflictHunk RPC"
```

---

## Task 5: `ReconcileError` enum + `ReconcileCoordinator` skeleton

**Files:**
- Create: `Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift`

- [ ] **Step 5.1: Create the file with skeleton + enums + state**

```swift
import Foundation
import Observation
import MultiharnessClient

public enum ReconcileError: Error, CustomStringConvertible {
    case noEligibleWorkspaces
    case projectNotFound
    case noDefaultModelForProject
    case providerNotFound(UUID)
    case integrationCreateFailed(String)

    public var description: String {
        switch self {
        case .noEligibleWorkspaces:
            return "No workspaces are in Done or In review."
        case .projectNotFound:
            return "Project not found."
        case .noDefaultModelForProject:
            return "Set a default provider/model on the project before reconciling."
        case .providerNotFound(let id):
            return "Provider \(id) not found."
        case .integrationCreateFailed(let msg):
            return "Failed to create integration workspace: \(msg)"
        }
    }
}

@MainActor
@Observable
public final class ReconcileCoordinator {
    public enum Phase: Equatable {
        case ready
        case running(currentWorkspaceId: UUID?)
        case completed(integrationWorkspaceId: UUID)
        case aborted(integrationWorkspaceId: UUID?)
        case failed(message: String, integrationWorkspaceId: UUID?)
    }

    public struct WorkspaceProgress: Identifiable, Equatable {
        public let id: UUID
        public var name: String
        public var state: State
        public var log: [String]

        public enum State: Equatable {
            case pending
            case merging
            case resolving
            case committed
            case failed(String)
        }
    }

    public private(set) var phase: Phase = .ready
    public private(set) var rows: [WorkspaceProgress] = []

    private let env: AppEnvironment
    private let appStore: AppStore
    private let workspaceStore: WorkspaceStore
    private var aborted: Bool = false

    public init(env: AppEnvironment, appStore: AppStore, workspaceStore: WorkspaceStore) {
        self.env = env
        self.appStore = appStore
        self.workspaceStore = workspaceStore
    }

    public func prepare(project: Project) throws {
        let eligible = appStore.workspaces
            .filter { $0.projectId == project.id }
            .filter { $0.archivedAt == nil }
            .filter { $0.lifecycleState == .done || $0.lifecycleState == .inReview }
            .sorted { $0.createdAt < $1.createdAt }
        guard !eligible.isEmpty else { throw ReconcileError.noEligibleWorkspaces }
        rows = eligible.map {
            WorkspaceProgress(id: $0.id, name: $0.name, state: .pending, log: [])
        }
        phase = .ready
    }

    public func abort() {
        aborted = true
    }

    public func start(project: Project) async {
        // Implemented in Task 6.
    }
}
```

- [ ] **Step 5.2: Build verifies**

Run: `swift build`
Expected: builds clean.

(Note: `appStore.workspaces` is `[Workspace]` — confirm by checking. If `AppStore` doesn't have a `workspaces` property, use `workspaceStore.workspaces` instead.)

- [ ] **Step 5.3: Verify the property used in `prepare` exists**

Run:
```bash
grep -n "var workspaces" Sources/MultiharnessCore/Stores/AppStore.swift
grep -n "var workspaces" Sources/MultiharnessCore/Stores/WorkspaceStore.swift
```

If `AppStore` lacks a `workspaces` property, change `appStore.workspaces` to `workspaceStore.workspaces` in `prepare(...)` above. (Both stores already exist; pick whichever holds the live list.)

- [ ] **Step 5.4: Commit**

```bash
git add Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift
git commit -m "ReconcileCoordinator: skeleton + prepare()"
```

---

## Task 6: `ReconcileCoordinator.start()` — the main loop

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift`

- [ ] **Step 6.1: Replace `start()` with the full implementation**

Replace the `public func start(project: Project) async { ... }` stub with:

```swift
    public func start(project: Project) async {
        guard !rows.isEmpty else {
            phase = .failed(message: "No eligible workspaces.", integrationWorkspaceId: nil)
            return
        }

        // Resolve provider + model for the integration workspace.
        guard let providerId = project.defaultProviderId,
              let provider = appStore.providers.first(where: { $0.id == providerId }),
              let modelId = project.defaultModelId, !modelId.isEmpty else {
            phase = .failed(message: ReconcileError.noDefaultModelForProject.description, integrationWorkspaceId: nil)
            return
        }

        let integrationName = "_reconcile-\(Self.timestamp())"
        let integrationWorkspace: Workspace
        do {
            integrationWorkspace = try workspaceStore.create(
                project: project,
                name: integrationName,
                baseBranch: project.defaultBaseBranch,
                provider: provider,
                modelId: modelId,
                gitUserName: NSUserName(),
                buildMode: nil
            )
            // Mark it `.inReview` immediately.
            workspaceStore.setLifecycle(integrationWorkspace, .inReview)
        } catch {
            phase = .failed(
                message: ReconcileError.integrationCreateFailed(String(describing: error)).description,
                integrationWorkspaceId: nil
            )
            return
        }

        let worktreePath = URL(fileURLWithPath: integrationWorkspace.worktreePath)
        let providerCfg = appStore.providerConfig(provider: provider, modelId: modelId)

        for i in rows.indices {
            if aborted {
                phase = .aborted(integrationWorkspaceId: integrationWorkspace.id)
                return
            }
            phase = .running(currentWorkspaceId: rows[i].id)
            await mergeOne(
                rowIndex: i,
                source: appStore.workspaces.first(where: { $0.id == rows[i].id })!,
                worktreePath: worktreePath,
                providerCfg: providerCfg
            )
        }

        // After all rows: bootstrap an agent session for the integration workspace
        // (existing flow).
        await appStore.bootstrapAllSessions(workspaces: [integrationWorkspace])
        appStore.selectedProjectId = project.id
        workspaceStore.selectedWorkspaceId = integrationWorkspace.id
        phase = .completed(integrationWorkspaceId: integrationWorkspace.id)
    }

    private func mergeOne(
        rowIndex: Int,
        source: Workspace,
        worktreePath: URL,
        providerCfg: [String: Any]
    ) async {
        rows[rowIndex].state = .merging

        let mergeResult: WorktreeService.MergeResult
        do {
            mergeResult = try env.worktree.merge(worktreePath: worktreePath, sourceBranch: source.branchName)
        } catch {
            rows[rowIndex].state = .failed("merge failed: \(error)")
            return
        }

        switch mergeResult {
        case .clean:
            do {
                try env.worktree.commit(worktreePath: worktreePath, message: "Reconcile: merge \(source.branchName)")
                rows[rowIndex].state = .committed
                rows[rowIndex].log.append("merged clean")
            } catch {
                rows[rowIndex].state = .failed("commit failed: \(error)")
            }

        case .conflicts(let unmergedFiles):
            rows[rowIndex].state = .resolving
            rows[rowIndex].log.append("\(unmergedFiles.count) files conflict")

            for file in unmergedFiles {
                if env.worktree.isLikelyBinary(worktreePath: worktreePath, path: file) {
                    rows[rowIndex].log.append("\(file): skipped (binary)")
                    continue
                }
                let absURL = worktreePath.appendingPathComponent(file)
                let content: String
                do {
                    content = try String(contentsOf: absURL, encoding: .utf8)
                } catch {
                    rows[rowIndex].log.append("\(file): unreadable")
                    continue
                }
                guard let client = env.control else {
                    rows[rowIndex].log.append("\(file): control client unavailable")
                    continue
                }
                let params: [String: Any] = [
                    "filePath": file,
                    "fileContext": content,
                    "providerConfig": providerCfg,
                ]
                do {
                    let raw = try await client.call(method: "agent.resolveConflictHunk", params: params)
                    guard let dict = raw as? [String: Any],
                          let outcome = dict["outcome"] as? String else {
                        rows[rowIndex].log.append("\(file): malformed RPC reply")
                        continue
                    }
                    if outcome == "resolved", let resolved = dict["content"] as? String {
                        try resolved.write(to: absURL, atomically: true, encoding: .utf8)
                        try env.worktree.stage(worktreePath: worktreePath, path: file)
                        rows[rowIndex].log.append("\(file): resolved")
                    } else if outcome == "declined" {
                        let reason = (dict["reason"] as? String) ?? "no reason"
                        rows[rowIndex].log.append("\(file): declined — \(reason)")
                    } else {
                        rows[rowIndex].log.append("\(file): unexpected outcome \(outcome)")
                    }
                } catch {
                    rows[rowIndex].log.append("\(file): RPC error \(error)")
                }
            }

            // After processing all files, check for any remaining conflicts.
            let stillUnmerged: [String]
            do {
                stillUnmerged = try env.worktree.unmergedFiles(worktreePath: worktreePath)
            } catch {
                stillUnmerged = []
            }
            if stillUnmerged.isEmpty {
                do {
                    try env.worktree.commit(worktreePath: worktreePath, message: "Reconcile: merge \(source.branchName)")
                    rows[rowIndex].state = .committed
                } catch {
                    rows[rowIndex].state = .failed("commit failed: \(error)")
                }
            } else {
                try? env.worktree.mergeAbort(worktreePath: worktreePath)
                rows[rowIndex].state = .failed("\(stillUnmerged.count) files need manual resolution")
            }
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
```

- [ ] **Step 6.2: Build verifies**

Run: `swift build`
Expected: builds clean. If `appStore.providerConfig(provider:modelId:)` is named differently or returns a different type, adjust the cast/type for `providerCfg`.

(Note: This implementation refers to `env.control` — confirm this is the property holding the `ControlClient` on `AppEnvironment`. If not, find the actual name by `grep -n "control" Sources/MultiharnessCore/AppEnvironment.swift` and adjust.)

- [ ] **Step 6.3: Commit**

```bash
git add Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift
git commit -m "ReconcileCoordinator: implement merge loop"
```

---

## Task 7: `ReconcileCoordinator` unit tests

**Files:**
- Create: `Tests/MultiharnessCoreTests/ReconcileCoordinatorTests.swift`

- [ ] **Step 7.1: Write the test file**

Note: This test exercises only the synchronous parts of the coordinator that don't require live git or a sidecar — specifically `prepare(...)` and `abort()`. The full async `start(...)` flow is integration-tested via the manual smoke at the end of the plan, since stubbing `env.worktree`, `env.control`, and `workspaceStore.create` cleanly is a larger investment than the v1 scope justifies.

```swift
import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class ReconcileCoordinatorTests: XCTestCase {
    func testPrepareRequiresEligibleWorkspaces() throws {
        let (env, app, ws) = try makeStores()
        let proj = try seedProject(app: app, store: ws.persistenceProxy())
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        XCTAssertThrowsError(try coord.prepare(project: proj)) { err in
            XCTAssertTrue(err is ReconcileError)
            if case ReconcileError.noEligibleWorkspaces = err as! ReconcileError { return }
            XCTFail("expected .noEligibleWorkspaces, got \(err)")
        }
    }

    func testPreparePopulatesRowsForDoneAndInReview() throws {
        let (env, app, ws) = try makeStores()
        let proj = try seedProject(app: app, store: ws.persistenceProxy())
        let prov = try seedProvider(app: app, store: ws.persistenceProxy())
        // Create three workspaces with different lifecycle states.
        for (state, name) in [
            (LifecycleState.done, "alpha"),
            (LifecycleState.inReview, "bravo"),
            (LifecycleState.inProgress, "charlie"),
        ] {
            let row = Workspace(
                projectId: proj.id, name: name, slug: name,
                branchName: "u/\(name)", baseBranch: "main",
                worktreePath: "/tmp/\(name)",
                lifecycleState: state, providerId: prov.id, modelId: "m"
            )
            try ws.persistenceProxy().upsertWorkspace(row)
        }
        ws.load(projectId: proj.id)
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        try coord.prepare(project: proj)
        let names = coord.rows.map(\.name).sorted()
        XCTAssertEqual(names, ["alpha", "bravo"])  // charlie is .inProgress, excluded.
        XCTAssertTrue(coord.rows.allSatisfy { $0.state == .pending })
    }

    func testAbortFlagFlips() throws {
        let (env, app, ws) = try makeStores()
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        coord.abort()  // Before any run; idempotent.
        // No public surface to read the flag; behavior is integration-tested by
        // manual smoke. This test just verifies abort() is callable and doesn't
        // throw.
    }

    // MARK: - helpers

    private func makeStores() throws -> (AppEnvironment, AppStore, WorkspaceStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = AppEnvironment(dataDir: dir)
        let app = AppStore(env: env)
        let ws = WorkspaceStore(env: env)
        return (env, app, ws)
    }

    private func seedProject(app: AppStore, store: PersistenceService) throws -> Project {
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultProviderId: nil, defaultModelId: "model",
            defaultBaseBranch: "main"
        )
        try store.upsertProject(proj)
        app.projects = try store.listProjects()
        app.selectedProjectId = proj.id
        return proj
    }

    private func seedProvider(app: AppStore, store: PersistenceService) throws -> ProviderRecord {
        let prov = ProviderRecord(
            name: "Local", kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1"
        )
        try store.upsertProvider(prov)
        app.providers = try store.listProviders()
        return prov
    }
}

// Tiny helper so we can reach the persistence service from WorkspaceStore in
// tests. WorkspaceStore.env is internal; expose a controlled accessor.
fileprivate extension WorkspaceStore {
    func persistenceProxy() -> PersistenceService {
        // The env is stored on the store; reach it via the same pattern
        // PersistenceTests uses (constructor takes env, env has persistence).
        // Implementation note: if `env` is private, add a small `_persistenceForTests`
        // var or use `Mirror`. Simplest: rebuild a service from the same dataDir.
        let mirror = Mirror(reflecting: self)
        if let envVal = mirror.descendant("env") as? AppEnvironment {
            return envVal.persistence
        }
        fatalError("could not access env.persistence")
    }
}
```

- [ ] **Step 7.2: Run tests**

Run: `swift test --filter ReconcileCoordinatorTests`
Expected: 3 tests pass.

(If the `Mirror`-based `persistenceProxy()` helper doesn't compile because the property names differ in the live code, replace it with a direct access to whatever the actual property is named, found via `grep -n "let env" Sources/MultiharnessCore/Stores/WorkspaceStore.swift`.)

- [ ] **Step 7.3: Commit**

```bash
git add Tests/MultiharnessCoreTests/ReconcileCoordinatorTests.swift
git commit -m "Test ReconcileCoordinator prepare and abort"
```

---

## Task 8: `ReconcileSheet` SwiftUI view

**Files:**
- Create: `Sources/Multiharness/Views/ReconcileSheet.swift`

- [ ] **Step 8.1: Write the view**

```swift
import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ReconcileSheet: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let project: Project
    @Binding var isPresented: Bool

    @State private var coordinator: ReconcileCoordinator?
    @State private var prepareError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reconcile workspaces").font(.title2).bold()
            Text("Project: \(project.name)").foregroundStyle(.secondary)
            Divider()
            content
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 520, height: 540)
        .onAppear {
            let c = ReconcileCoordinator(env: appStore.env, appStore: appStore, workspaceStore: workspaceStore)
            do {
                try c.prepare(project: project)
                coordinator = c
            } catch {
                prepareError = String(describing: error)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = prepareError {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(err)
            }
        } else if let c = coordinator {
            switch c.phase {
            case .ready:
                triggerScreen(c)
            case .running, .completed, .aborted, .failed:
                progressScreen(c)
            }
        } else {
            ProgressView()
        }
    }

    private func triggerScreen(_ c: ReconcileCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The following workspaces will merge into a new integration workspace, in this order:")
                .font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(c.rows.enumerated()), id: \.element.id) { idx, row in
                        Text("\(idx + 1). \(row.name)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Text("Conflicts will be resolved by your project's chosen model. Original workspaces are not modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressScreen(_ c: ReconcileCoordinator) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(c.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            stateGlyph(row.state)
                            Text(row.name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(stateLabel(row.state)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(row.log, id: \.self) { line in
                            Text("    • \(line)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func stateGlyph(_ state: ReconcileCoordinator.WorkspaceProgress.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .merging, .resolving: ProgressView().controlSize(.small)
        case .committed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func stateLabel(_ state: ReconcileCoordinator.WorkspaceProgress.State) -> String {
        switch state {
        case .pending: return "pending"
        case .merging: return "merging…"
        case .resolving: return "resolving…"
        case .committed: return "merged"
        case .failed(let r): return "failed: \(r)"
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if let c = coordinator {
                switch c.phase {
                case .ready:
                    Button("Cancel") { isPresented = false }
                    Button("Reconcile") {
                        Task { await c.start(project: project) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(c.rows.isEmpty)
                case .running:
                    Button("Abort") { c.abort() }
                case .completed(let id):
                    Button("Open integrated workspace") {
                        workspaceStore.selectedWorkspaceId = id
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Close") { isPresented = false }
                case .aborted, .failed:
                    Button("Close") { isPresented = false }
                }
            } else {
                Button("Cancel") { isPresented = false }
            }
        }
    }
}
```

- [ ] **Step 8.2: Build verifies**

Run: `swift build`
Expected: builds clean.

If `appStore.env` isn't a public property, expose it. Add to `AppStore`:

```swift
public var env: AppEnvironment { _env }
```

(or whichever name the existing private storage uses — check with `grep -n "let env" Sources/MultiharnessCore/Stores/AppStore.swift`).

- [ ] **Step 8.3: Commit**

```bash
git add Sources/Multiharness/Views/ReconcileSheet.swift
git commit -m "Mac UI: ReconcileSheet (trigger + progress)"
```

---

## Task 9: Add Reconcile button to `ProjectPickerHeader` (single-project mode)

**Files:**
- Modify: `Sources/Multiharness/Views/RootView.swift`
- Modify: any caller that owns the sheet presentation state (likely `RootView` body — find it with `grep -n "showingNewProject" Sources/Multiharness/Views/RootView.swift`).

- [ ] **Step 9.1: Add a `showingReconcile` state and Reconcile button to `ProjectPickerHeader`**

Update `ProjectPickerHeader` (lines 200–249) to add a Reconcile binding + button:

```swift
private struct ProjectPickerHeader: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var showingNewProject: Bool
    @Binding var showingReconcile: Bool
    var onQuickCreate: (Project) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // …existing Menu(…) and Text label code unchanged…
            // (keep lines 208-237 as-is; only the trailing buttons section changes.)
            if let proj = appStore.selectedProject {
                Button {
                    onQuickCreate(proj)
                } label: {
                    Image(systemName: "plus").font(.body)
                }
                .buttonStyle(.borderless)
                .disabled(appStore.providers.isEmpty)
                .help("Quick-create workspace")

                Button {
                    showingReconcile = true
                } label: {
                    Image(systemName: "arrow.triangle.merge").font(.body)
                }
                .buttonStyle(.borderless)
                .disabled(!eligibleWorkspacesExist(in: proj))
                .help("Reconcile workspaces")
            }
        }
    }

    private func eligibleWorkspacesExist(in proj: Project) -> Bool {
        workspaceStore.workspaces.contains { ws in
            ws.projectId == proj.id
                && ws.archivedAt == nil
                && (ws.lifecycleState == .done || ws.lifecycleState == .inReview)
        }
    }
}
```

- [ ] **Step 9.2: Wire `showingReconcile` in `RootView`'s body**

Find the call site that constructs `ProjectPickerHeader` (search for `ProjectPickerHeader(`) and add a new `@State private var showingReconcile: Bool = false` to that view, plus pass `$showingReconcile` to the header. Then add a `.sheet(isPresented: $showingReconcile)` that presents `ReconcileSheet` (only when a project is selected):

```swift
// inside RootView (or whichever view holds the sidebar)
@State private var showingReconcile: Bool = false

// inside its body, near the existing sheets:
.sheet(isPresented: $showingReconcile) {
    if let proj = appStore.selectedProject {
        ReconcileSheet(
            appStore: appStore,
            workspaceStore: workspaceStore,
            project: proj,
            isPresented: $showingReconcile
        )
    }
}
```

(Match style of the existing `.sheet(isPresented: $showingNewProject)` invocation — same closure pattern.)

- [ ] **Step 9.3: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 9.4: Commit**

```bash
git add Sources/Multiharness/Views/RootView.swift
git commit -m "Mac UI: Reconcile button in ProjectPickerHeader"
```

---

## Task 10: Add Reconcile button to `ProjectDisclosure.header` (all-projects mode)

**Files:**
- Modify: `Sources/Multiharness/Views/WorkspaceSidebar.swift`

- [ ] **Step 10.1: Add a Reconcile button to `ProjectDisclosure.header`**

Replace the `header` body (around lines 130–144) with:

```swift
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(project.name).font(.body)
            Spacer()
            Menu {
                Toggle("Group by status", isOn: $groupByStatus)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(action: onReconcile) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!hasEligibleWorkspaces)
            .help("Reconcile workspaces")
            Button(action: onQuickCreate) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Quick-create workspace")
        }
    }

    private var hasEligibleWorkspaces: Bool {
        workspaceStore.workspaces.contains { ws in
            ws.projectId == project.id
                && ws.archivedAt == nil
                && (ws.lifecycleState == .done || ws.lifecycleState == .inReview)
        }
    }
```

- [ ] **Step 10.2: Add `onReconcile` parameter to `ProjectDisclosure`'s init**

Update the struct's stored properties + initializer:

```swift
private struct ProjectDisclosure: View {
    let project: Project
    @Bindable var workspaceStore: WorkspaceStore
    let onQuickCreate: () -> Void
    let onReconcile: () -> Void

    @State private var isExpanded: Bool
    @State private var groupByStatus: Bool

    init(
        project: Project,
        workspaceStore: WorkspaceStore,
        onQuickCreate: @escaping () -> Void,
        onReconcile: @escaping () -> Void
    ) {
        self.project = project
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

- [ ] **Step 10.3: Wire `onReconcile` at the call site**

Find `ProjectDisclosure(` callers in `WorkspaceSidebar.swift` and update each to pass an `onReconcile:` closure that triggers a parent-owned `showingReconcile` binding (similar pattern to `onQuickCreate`). Specifically, `WorkspaceSidebar`'s body needs a `@Binding var pendingReconcileProject: Project?` (or a similar mechanism) that the parent uses to drive `ReconcileSheet`. Match how `onQuickCreate` is currently threaded.

If the existing `WorkspaceSidebar` doesn't already accept an `onQuickCreate` closure for the all-projects sidebar mode, this scaffolding will need a small extension. The cleanest approach: add `let onReconcile: (Project) -> Void` to `WorkspaceSidebar` itself, propagate to each `ProjectDisclosure`, and have the parent view present `ReconcileSheet` via a `pendingReconcileProject: Project?` state.

- [ ] **Step 10.4: Build verifies**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 10.5: Commit**

```bash
git add Sources/Multiharness/Views/WorkspaceSidebar.swift
git commit -m "Mac UI: Reconcile button in ProjectDisclosure header"
```

---

## Task 11: End-to-end manual smoke

- [ ] **Step 11.1: Build and launch**

```bash
bash scripts/build-app.sh CONFIG=debug && open dist/Multiharness.app
```

- [ ] **Step 11.2: Smoke happy path**

1. Open a project with at least 2 workspaces. Mark them `.done` via the sidebar context menu.
2. Click the merge-arrow icon next to the project name.
3. The trigger sheet opens, listing the two workspaces in order.
4. Click Reconcile.
5. The progress panel shows each workspace's state. (You may not see conflicts — that's fine for the happy path.)
6. On completion, the new `_reconcile-…` workspace appears in the sidebar and is selected.
7. Click "Open integrated workspace" (if not auto-opened) and confirm the inspector shows the cumulative diff.

- [ ] **Step 11.3: Smoke a conflict**

1. Pick two workspaces that touch the same file. (If you don't have such a pair, create them: `quickCreate` two new workspaces, edit the same file in each, mark both `.done`.)
2. Trigger Reconcile.
3. Watch the progress panel show "resolving…" with per-file log entries.
4. At the end, inspect the integration workspace's diff. The conflict should be either resolved (no `<<<<<<<` markers in the file) or the row should be marked `.failed` with a "needs manual resolution" log entry.

- [ ] **Step 11.4: Smoke abort**

1. Trigger a reconcile with several workspaces.
2. Click Abort during the run.
3. Confirm the run halts and the partial integration workspace is preserved (visible in the sidebar).
4. Close the sheet.

- [ ] **Step 11.5: Run all tests once more**

```bash
swift test && (cd sidecar && bun test) && (cd sidecar && bun run typecheck)
```

Expected: all green.

- [ ] **Step 11.6: Commit any tweaks**

If smoke testing surfaced bugs, fix and commit individually. Otherwise no commit needed.

---

## Done

The reconcile-worktrees feature is now live end-to-end:

- Project header buttons trigger `ReconcileSheet`.
- `ReconcileCoordinator` drives the run, sequentially merging eligible workspaces into a fresh integration worktree.
- Conflicts route through `agent.resolveConflictHunk` to `pi-ai`'s `complete()`, with explicit decline handling and malformed-output detection.
- Progress is visible in real time; the user can abort.
- The integration result is a regular workspace in `.inReview`, with its own agent.
- Original workspaces and source branches are untouched.

Out of scope for this PR (will be follow-ups):

- iOS trigger.
- Streaming review per workspace.
- Side-by-side conflict viewer.
- Auto-build/test of the integration worktree.
- Persisted lineage record.
- Drag-to-reorder source workspaces.

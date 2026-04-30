# iOS Quick-Create Workspace + Global Default Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "+" button next to each project in the iOS app that instantly creates a workspace with inherited settings, falling back to a pre-filled `NewWorkspaceSheet` when inheritance can't resolve a provider+model. Add a global default provider+model on the Mac as a new fallback in the inheritance chain.

**Architecture:** Refactor `WorkspaceStore.quickCreate`'s resolution step into a shared helper (`resolveQuickCreateInputs`) that the existing Mac quick-create path and a new `workspace.quickCreate` relay handler both use. Add Mac-only persistence + UI for the global default. iOS calls the new relay method on tap; on `created` it just refreshes; on `needs_input` it opens the existing sheet pre-filled with whatever the server resolved.

**Tech Stack:** Swift 5 / SwiftUI (Mac + iOS), SQLite (existing `settings` k/v table), Bun + TypeScript (sidecar relay registration), XCTest.

**Spec:** `docs/superpowers/specs/2026-04-30-ios-quick-create-workspace-design.md`

---

## File map

**Modify:**
- `Sources/MultiharnessCore/Stores/AppStore.swift` — add `getGlobalDefault` / `setGlobalDefault`.
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — extract `resolveQuickCreateInputs`, plumb global-default fallback through `quickCreate`.
- `Sources/Multiharness/Views/RootView.swift` — pass `appStore.getGlobalDefault()` into `quickCreate`.
- `Sources/Multiharness/Views/Sheets.swift` — add a `Defaults` tab to `SettingsSheet`.
- `Sources/Multiharness/RemoteHandlers.swift` — register and implement `workspace.quickCreate`.
- `sidecar/src/methods.ts` — declare `workspace.quickCreate` as a relay method.
- `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — add `WorkspaceSuggestion`, `QuickCreateOutcome`, `quickCreateWorkspace`.
- `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` — `NewWorkspaceSheet` accepts an optional `suggestion`.
- `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift` — render the "+" button, handle the outcome.

**Create:**
- `Tests/MultiharnessCoreTests/QuickCreateTests.swift` — covers the resolution helper + the wrapper.
- `Tests/MultiharnessCoreTests/GlobalDefaultTests.swift` — covers the new AppStore APIs.

---

## Task 1: Persistence & accessor for global default

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/AppStore.swift`
- Test: `Tests/MultiharnessCoreTests/GlobalDefaultTests.swift`

The `settings` k/v table already exists (`Sources/MultiharnessCore/Persistence/Migrations.swift:44`). No schema migration. Two new keys: `default_provider_id` (UUID string) and `default_model_id` (string).

- [ ] **Step 1: Write the failing test**

Create `Tests/MultiharnessCoreTests/GlobalDefaultTests.swift`:

```swift
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
        // Stash only the model, no provider — partial state should read as nil.
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter GlobalDefaultTests
```

Expected: compilation error — `getGlobalDefault` / `setGlobalDefault` undefined.

- [ ] **Step 3: Implement `getGlobalDefault` / `setGlobalDefault`**

Append to `Sources/MultiharnessCore/Stores/AppStore.swift`, just before the closing `}` of the class:

```swift
    // MARK: - Global default provider+model

    /// Reads the global fallback (provider, model) pair used by quick-create
    /// when the project's previous workspace, project defaults, and provider
    /// default have all whiffed. Returns nil if either key is absent or the
    /// stored provider id is malformed. Provider-existence is not checked
    /// here — quickCreate's resolver is responsible for that, since the
    /// provider list lives on the same store and we want a single source
    /// of truth for "is this provider id still real."
    public func getGlobalDefault() -> (providerId: UUID, modelId: String)? {
        do {
            guard
                let providerStr = try env.persistence.getSetting("default_provider_id"),
                let providerId = UUID(uuidString: providerStr),
                let modelId = try env.persistence.getSetting("default_model_id"),
                !modelId.isEmpty
            else { return nil }
            return (providerId, modelId)
        } catch {
            return nil
        }
    }

    /// Persist or clear the global default. Pass nil for either to clear both
    /// — we only treat the pair as meaningful, never half-set.
    public func setGlobalDefault(providerId: UUID?, modelId: String?) throws {
        if let pid = providerId, let mid = modelId, !mid.isEmpty {
            try env.persistence.setSetting("default_provider_id", value: pid.uuidString)
            try env.persistence.setSetting("default_model_id", value: mid)
        } else {
            // Clear both keys atomically-enough — settings is a small k/v
            // table with no transactions exposed; two writes is fine.
            try env.persistence.setSetting("default_provider_id", value: "")
            try env.persistence.setSetting("default_model_id", value: "")
        }
    }
```

Adjust `getGlobalDefault` to also reject empty strings (since `setSetting` writes "" on clear rather than DELETE). The `!modelId.isEmpty` guard already handles model; add the provider-id empty case via the `UUID(uuidString:)` failure (UUID("") is nil), which already returns nil. ✓

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter GlobalDefaultTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Stores/AppStore.swift Tests/MultiharnessCoreTests/GlobalDefaultTests.swift
git commit -m "Add global default provider+model accessor on AppStore"
```

---

## Task 2: Extract `resolveQuickCreateInputs` helper + plumb global default

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/WorkspaceStore.swift:212-253`
- Test: `Tests/MultiharnessCoreTests/QuickCreateTests.swift`

Today, `quickCreate` does both the resolution (priority chain) and the side-effect (creating the worktree + persisting). The relay handler in Task 5 needs the resolution step to surface partial results when the chain whiffs, so split the resolution into a pure helper that returns a `QuickCreateResolution` value.

The new chain adds the global default as the last fallback:

| field | priority |
| --- | --- |
| `provider` | inherit workspace → project default → global default → first available |
| `model` | inherit workspace → project default → provider default → global default → error |
| `baseBranch` | inherit workspace → project default |
| `buildMode` | project default |
| `name` | `RandomName.generateUnique(avoiding:)` |

The "global default" is a pair `(providerId, modelId)`. Its provider id is only used when the provider chain hasn't already produced one; its model id is only used when the model chain hasn't. They don't have to come from the same step.

If the global default's provider id refers to a deleted provider, treat it as absent (the resolver verifies presence in `providers`). The global default's model is just a string — we don't validate it against any list; the resolver passes it through.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MultiharnessCoreTests/QuickCreateTests.swift`:

```swift
import XCTest
@testable import MultiharnessCore

@MainActor
final class QuickCreateTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-quickcreate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() throws -> (AppEnvironment, WorkspaceStore, Project, ProviderRecord) {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultBaseBranch: "main"
        )
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(
            name: "Local", kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1",
            defaultModelId: "qwen2.5-7b"
        )
        try env.persistence.upsertProvider(prov)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        return (env, store, proj, prov)
    }

    func testResolveUsesProviderDefaultModelWhenNoOtherSources() throws {
        let (_, store, proj, prov) = try makeFixture()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [prov],
            globalDefault: nil
        )
        XCTAssertEqual(res.providerId, prov.id)
        XCTAssertEqual(res.modelId, "qwen2.5-7b")
        XCTAssertEqual(res.baseBranch, "main")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveFallsBackToGlobalDefaultWhenNoProvider() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)

        let globalProviderId = UUID()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [],
            globalDefault: (globalProviderId, "global-model")
        )
        // No providers configured → resolver can't surface providerId.
        // The global default's provider id is only useful if it's still in
        // the providers list, which it isn't here.
        XCTAssertNil(res.providerId)
        XCTAssertEqual(res.modelId, "global-model")
        XCTAssertEqual(res.missing, ["provider"])
    }

    func testResolveUsesGlobalDefaultProviderWhenItExistsInList() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let provA = ProviderRecord(name: "A", kind: .openaiCompatible, baseUrl: "http://a")
        let provB = ProviderRecord(name: "B", kind: .openaiCompatible, baseUrl: "http://b")
        try env.persistence.upsertProvider(provA)
        try env.persistence.upsertProvider(provB)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)

        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [provA, provB],
            globalDefault: (provB.id, "global-model")
        )
        // Project has no default, no inherit — global default's provider
        // wins over "first available" because it exists in the list.
        XCTAssertEqual(res.providerId, provB.id)
        XCTAssertEqual(res.modelId, "global-model")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveIgnoresGlobalDefaultProviderIfDeleted() throws {
        let (_, store, proj, prov) = try makeFixture()
        let staleId = UUID()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [prov],
            globalDefault: (staleId, "global-model")
        )
        // Stale global provider id falls through to "first available".
        XCTAssertEqual(res.providerId, prov.id)
        // Model: provider's default wins over the global default because
        // the chain consults provider.defaultModelId first.
        XCTAssertEqual(res.modelId, "qwen2.5-7b")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveReportsMissingModelWhenNothingResolves() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(
            name: "P", kind: .openaiCompatible,
            baseUrl: "http://p", defaultModelId: nil
        )
        try env.persistence.upsertProvider(prov)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        let res = store.resolveQuickCreateInputs(
            project: proj, providers: [prov], globalDefault: nil
        )
        XCTAssertEqual(res.providerId, prov.id)
        XCTAssertNil(res.modelId)
        XCTAssertEqual(res.missing, ["model"])
    }

    func testQuickCreateThrowsWhenResolutionMissing() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        XCTAssertThrowsError(try store.quickCreate(
            project: proj, providers: [], gitUserName: "u",
            globalDefault: nil
        )) { err in
            guard case WorkspaceStore.QuickCreateError.noProviderAvailable = err else {
                return XCTFail("expected noProviderAvailable, got \(err)")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter QuickCreateTests
```

Expected: compilation error — `resolveQuickCreateInputs` undefined; `quickCreate` doesn't take `globalDefault`.

- [ ] **Step 3: Add the resolution struct and helper, refactor `quickCreate`**

Replace `WorkspaceStore.swift:197-253` with:

```swift
    public enum QuickCreateError: Error, LocalizedError {
        case noProviderAvailable
        public var errorDescription: String? {
            switch self {
            case .noProviderAvailable:
                return "No provider configured. Add one in Settings."
            }
        }
    }

    /// Output of the inheritance chain used by quick-create. The struct can
    /// describe a fully-resolved tuple, a partial one ("we got a provider
    /// but no model"), or nothing useful at all. `missing` is the list of
    /// fields the chain couldn't fill — empty means quick-create may proceed.
    public struct QuickCreateResolution: Sendable {
        public let providerId: UUID?
        public let modelId: String?
        public let baseBranch: String
        public let buildMode: BuildMode?
        public let name: String

        public var missing: [String] {
            var m: [String] = []
            if providerId == nil { m.append("provider") }
            if modelId == nil || modelId?.isEmpty == true { m.append("model") }
            return m
        }
    }

    /// Pure resolver — no side effects, no creation. Both `quickCreate` and
    /// the iOS relay handler call this and act on the result.
    public func resolveQuickCreateInputs(
        project: Project,
        providers: [ProviderRecord],
        globalDefault: (providerId: UUID, modelId: String)?
    ) -> QuickCreateResolution {
        let inherit = selected().flatMap { $0.projectId == project.id ? $0 : nil }

        // Provider chain: inherit → project default → global default →
        // first available. Each step only counts when the candidate id
        // still maps to a real entry in `providers`.
        let provider: ProviderRecord? = {
            let candidates: [UUID?] = [
                inherit?.providerId,
                project.defaultProviderId,
                globalDefault?.providerId,
            ]
            for c in candidates {
                if let pid = c, let p = providers.first(where: { $0.id == pid }) {
                    return p
                }
            }
            return providers.first
        }()

        // Model chain: inherit → project default → provider default →
        // global default. Only the last two depend on the resolved
        // provider; the first two are project-scoped.
        let modelId: String? = {
            if let m = inherit?.modelId, !m.isEmpty { return m }
            if let m = project.defaultModelId, !m.isEmpty { return m }
            if let p = provider, let m = p.defaultModelId, !m.isEmpty { return m }
            if let m = globalDefault?.modelId, !m.isEmpty { return m }
            return nil
        }()

        let baseBranch = inherit?.baseBranch ?? project.defaultBaseBranch
        let existingSlugs = Set(
            workspaces.filter { $0.projectId == project.id }.map { $0.slug }
        )
        return QuickCreateResolution(
            providerId: provider?.id,
            modelId: modelId,
            baseBranch: baseBranch,
            buildMode: project.defaultBuildMode,
            name: RandomName.generateUnique(avoiding: existingSlugs)
        )
    }

    /// One-click workspace creation. Inherits provider/model/baseBranch
    /// from the currently selected workspace (when it belongs to `project`)
    /// or falls back through project default → global default → provider
    /// default → first available. Generates a unique adjective-noun name.
    @discardableResult
    public func quickCreate(
        project: Project,
        providers: [ProviderRecord],
        gitUserName: String,
        globalDefault: (providerId: UUID, modelId: String)? = nil
    ) throws -> Workspace {
        let resolution = resolveQuickCreateInputs(
            project: project, providers: providers, globalDefault: globalDefault
        )
        guard resolution.missing.isEmpty,
              let pid = resolution.providerId,
              let provider = providers.first(where: { $0.id == pid }),
              let modelId = resolution.modelId, !modelId.isEmpty
        else {
            throw QuickCreateError.noProviderAvailable
        }
        return try create(
            project: project,
            name: resolution.name,
            baseBranch: resolution.baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: gitUserName,
            buildMode: resolution.buildMode,
            nameSource: .random
        )
    }
```

Note: `quickCreate` now also passes `buildMode: resolution.buildMode` through to `create`. Pre-refactor it didn't — but the spec's chain explicitly says buildMode comes from the project default, and `create(...)` already accepts it. This is a bugfix in passing.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter QuickCreateTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MultiharnessCore/Stores/WorkspaceStore.swift Tests/MultiharnessCoreTests/QuickCreateTests.swift
git commit -m "Extract quickCreate resolver, add global default fallback"
```

---

## Task 3: Wire the new `globalDefault` parameter into the Mac UI call site

**Files:**
- Modify: `Sources/Multiharness/Views/RootView.swift:192-205`

The Mac UI's `runQuickCreate` is the only existing caller of `quickCreate`. Now that the signature has a new optional parameter, pass `appStore.getGlobalDefault()` so the Mac's "+" button benefits from the same fallback iOS will use.

- [ ] **Step 1: Modify `runQuickCreate` to forward the global default**

Replace the body (lines 192-205) with:

```swift
    private func runQuickCreate(project: Project) {
        do {
            _ = try workspaceStore.quickCreate(
                project: project,
                providers: appStore.providers,
                gitUserName: NSUserName(),
                globalDefault: appStore.getGlobalDefault()
            )
            if appStore.sidebarMode == .allProjects {
                workspaceStore.loadAll()
            }
        } catch {
            quickCreateError = String(describing: error)
        }
    }
```

- [ ] **Step 2: Verify the build still compiles**

```bash
swift build
```

Expected: clean build.

- [ ] **Step 3: Verify existing tests still pass**

```bash
swift test
```

Expected: all green (this change doesn't add tests; covered by Task 2's resolver tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/Multiharness/Views/RootView.swift
git commit -m "Pass global default into Mac quick-create"
```

---

## Task 4: Add the "Defaults" tab to `SettingsSheet`

**Files:**
- Modify: `Sources/Multiharness/Views/Sheets.swift`

Adds a new `SettingsTab.defaults` case and a `DefaultsTab` view. The tab lets the user pick a provider and a model from that provider's discovered list. A "Clear" button resets both. `ModelPicker` (already in `Sources/Multiharness/Views/ModelPicker.swift`) handles the model selection.

- [ ] **Step 1: Find `ModelPicker`'s public init signature**

```bash
```

Run:
```bash
grep -n "public struct ModelPicker\|init(" Sources/Multiharness/Views/ModelPicker.swift | head -10
```

Expected: a `ModelPicker` view that takes a provider, a binding for the chosen model id, and an `AppStore` (or env). Use that signature in Step 3.

- [ ] **Step 2: Add `defaults` to `SettingsTab` and the tab strip**

In `Sources/Multiharness/Views/Sheets.swift:272`, change:

```swift
    enum SettingsTab: Hashable { case providers, remote, permissions, sidebar }
```

to:

```swift
    enum SettingsTab: Hashable { case providers, remote, permissions, sidebar, defaults }
```

In the `body` `HStack` (lines 276-282), add a fifth tab button before `Spacer()`:

```swift
                tabButton("Defaults", .defaults)
                Spacer()
```

In the `switch tab` (lines 284-293), add a fifth case:

```swift
            case .defaults:
                DefaultsTab(appStore: appStore)
```

- [ ] **Step 3: Add the `DefaultsTab` view**

Append to `Sources/Multiharness/Views/Sheets.swift` (just below the existing `SidebarTab`, before any preview helpers at the bottom of the file):

```swift
private struct DefaultsTab: View {
    @Bindable var appStore: AppStore

    @State private var draftProviderId: UUID? = nil
    @State private var draftModelId: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Defaults").font(.title3).bold()
            Text("Used when creating a workspace if the project has no default and there's no prior workspace to inherit from. iPhone quick-create uses this too.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Default provider", selection: $draftProviderId) {
                Text("None").tag(UUID?.none)
                ForEach(appStore.providers, id: \.id) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }

            if let pid = draftProviderId,
               let provider = appStore.providers.first(where: { $0.id == pid }) {
                ModelPicker(
                    appStore: appStore,
                    provider: provider,
                    selection: $draftModelId
                )
            } else {
                Text("Pick a provider to choose a default model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftProviderId == nil || draftModelId.isEmpty)
                Button("Clear", role: .destructive) { clear() }
                    .disabled(appStore.getGlobalDefault() == nil)
                Spacer()
            }
            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .onAppear {
            if let cur = appStore.getGlobalDefault() {
                draftProviderId = cur.providerId
                draftModelId = cur.modelId
            }
        }
    }

    private func save() {
        do {
            try appStore.setGlobalDefault(providerId: draftProviderId, modelId: draftModelId)
            saveError = nil
        } catch {
            saveError = String(describing: error)
        }
    }

    private func clear() {
        do {
            try appStore.setGlobalDefault(providerId: nil, modelId: nil)
            draftProviderId = nil
            draftModelId = ""
            saveError = nil
        } catch {
            saveError = String(describing: error)
        }
    }
}
```

If `ModelPicker`'s actual init signature differs from the one above (Step 1 will tell you), adapt the call. If `ModelPicker` requires a different binding type (e.g. `String?`), wrap accordingly:

```swift
ModelPicker(
    appStore: appStore,
    provider: provider,
    selection: Binding(
        get: { draftModelId.isEmpty ? nil : draftModelId },
        set: { draftModelId = $0 ?? "" }
    )
)
```

- [ ] **Step 4: Build and visually verify (manual)**

```bash
bash scripts/build-app.sh
open dist/Multiharness.app
```

Open the gear icon → Settings sheet. Confirm:
1. "Defaults" tab appears as the fifth tab.
2. Picker shows configured providers + "None".
3. Picking a provider reveals the model picker.
4. Save persists across app relaunch.
5. Clear empties both fields and the round-trip lookup returns nil.

- [ ] **Step 5: Commit**

```bash
git add Sources/Multiharness/Views/Sheets.swift
git commit -m "Add Defaults tab for global provider+model"
```

---

## Task 5: Mac-side relay handler `workspace.quickCreate`

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift`

The handler runs `resolveQuickCreateInputs` against the Mac's live `AppStore` and `WorkspaceStore`. On a complete resolution it calls `WorkspaceStore.create` directly (mirroring `workspace.create`'s codepath). On `missing != []` it returns a structured `needs_input` payload — *not* a JSON-RPC error, so iOS gets a single result-shaped path to parse.

- [ ] **Step 1: Register the handler**

In `Sources/Multiharness/RemoteHandlers.swift:9-54`, inside `register(...)`, add a new registration alongside `workspace.create`:

```swift
        await relay.register(method: "workspace.quickCreate") { params in
            try await Self.workspaceQuickCreate(
                params: params,
                env: env, appStore: appStore, workspaceStore: workspaceStore
            )
        }
```

- [ ] **Step 2: Implement the handler**

Add the implementation just after `workspaceCreate` (after line 250 in the original file):

```swift
    // MARK: - workspace.quickCreate

    @MainActor
    private static func workspaceQuickCreate(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let projectIdStr = params["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let project = appStore.projects.first(where: { $0.id == projectId }) else {
            throw RemoteError.bad("project not found")
        }

        let resolution = workspaceStore.resolveQuickCreateInputs(
            project: project,
            providers: appStore.providers,
            globalDefault: appStore.getGlobalDefault()
        )

        if !resolution.missing.isEmpty {
            // Partial resolution. iOS uses `suggested` to pre-fill the
            // recovery sheet; missing tells it which fields to focus on.
            var suggested: [String: Any] = [
                "name": resolution.name,
                "baseBranch": resolution.baseBranch,
            ]
            if let pid = resolution.providerId { suggested["providerId"] = pid.uuidString }
            if let mid = resolution.modelId { suggested["modelId"] = mid }
            if let bm = resolution.buildMode { suggested["buildMode"] = bm.rawValue }
            return [
                "status": "needs_input",
                "missing": resolution.missing,
                "suggested": suggested,
            ] as [String: Any]
        }

        // Resolution complete — proceed.
        guard let pid = resolution.providerId,
              let provider = appStore.providers.first(where: { $0.id == pid }),
              let modelId = resolution.modelId, !modelId.isEmpty else {
            // Defensive: missing is empty but the unwraps fail — shouldn't
            // happen given the resolver's invariants, but don't proceed
            // with garbage. Surface as bad_request so iOS can show an error.
            throw RemoteError.bad("resolution incomplete")
        }
        let userName = NSUserName()
        let workspace = try workspaceStore.create(
            project: project,
            name: resolution.name,
            baseBranch: resolution.baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: userName,
            buildMode: resolution.buildMode,
            nameSource: .random
        )
        await appStore.bootstrapAllSessions(workspaces: [workspace])

        let resolvedMode = workspace.effectiveBuildMode(
            in: appStore.projects.first(where: { $0.id == project.id }) ?? project
        )

        return [
            "status": "created",
            "workspace": [
                "id": workspace.id.uuidString,
                "name": workspace.name,
                "branchName": workspace.branchName,
                "worktreePath": workspace.worktreePath,
                "lifecycleState": workspace.lifecycleState.rawValue,
                "modelId": workspace.modelId,
                "buildMode": resolvedMode.rawValue,
                "projectId": workspace.projectId.uuidString,
                "baseBranch": workspace.baseBranch,
            ],
        ] as [String: Any]
    }
```

- [ ] **Step 3: Build the project to confirm no compile errors**

```bash
swift build
```

Expected: clean build.

- [ ] **Step 4: Verify existing tests still pass**

```bash
swift test
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Multiharness/RemoteHandlers.swift
git commit -m "Add workspace.quickCreate Mac relay handler"
```

---

## Task 6: Sidecar — declare `workspace.quickCreate` as a relay method

**Files:**
- Modify: `sidecar/src/methods.ts:223-235`

The sidecar relays a fixed list of method names to the registered Mac handler. Add `workspace.quickCreate` to that list — no other server-side logic is needed since the Mac handler does all the work.

- [ ] **Step 1: Add the method name to the relay list**

Change:

```typescript
  for (const m of [
    "workspace.create",
    "workspace.setContext",
    "project.scan",
    "project.create",
    "project.setContext",
    "models.listForProvider",
    "fs.list",
  ]) {
```

to:

```typescript
  for (const m of [
    "workspace.create",
    "workspace.quickCreate",
    "workspace.setContext",
    "project.scan",
    "project.create",
    "project.setContext",
    "models.listForProvider",
    "fs.list",
  ]) {
```

- [ ] **Step 2: Typecheck**

```bash
cd sidecar && bun run typecheck && cd ..
```

Expected: no errors.

- [ ] **Step 3: Run sidecar tests (if any cover the relay)**

```bash
cd sidecar && bun test && cd ..
```

Expected: all existing tests pass — this change just adds a name to a list.

- [ ] **Step 4: Rebuild the sidecar binary so the Mac app picks it up**

```bash
bash sidecar/scripts/build.sh
```

Expected: produces `sidecar/dist/multiharness-sidecar`.

- [ ] **Step 5: Commit**

```bash
git add sidecar/src/methods.ts
git commit -m "sidecar: relay workspace.quickCreate"
```

---

## Task 7: iOS — `WorkspaceSuggestion`, `QuickCreateOutcome`, `quickCreateWorkspace`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`

Add the three iOS-side types/methods that wire up the new relay. `WorkspaceSuggestion` is decoded directly from the relay response's `suggested` object; `QuickCreateOutcome` is the discriminator for the view layer.

- [ ] **Step 1: Add `WorkspaceSuggestion` and `QuickCreateOutcome` types**

Append to `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`, near the bottom alongside `RemoteProject` / `RemoteProvider`:

```swift
public struct WorkspaceSuggestion: Sendable, Equatable {
    public let name: String
    public let baseBranch: String?
    public let providerId: String?
    public let modelId: String?
    public let buildMode: BuildMode?

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        self.baseBranch = json["baseBranch"] as? String
        self.providerId = json["providerId"] as? String
        self.modelId = json["modelId"] as? String
        self.buildMode = (json["buildMode"] as? String).flatMap(BuildMode.init(rawValue:))
    }
}

public enum QuickCreateOutcome: Sendable, Equatable {
    case created
    case needsInput(WorkspaceSuggestion)
    case failed(String)
}
```

- [ ] **Step 2: Add `quickCreateWorkspace` to `ConnectionStore`**

Inside `ConnectionStore` (e.g. just after the existing `createWorkspace` method around line 100):

```swift
    /// One-tap workspace creation. Asks the Mac to resolve inheritance via
    /// `workspace.quickCreate`. On `created` the workspace appears via the
    /// existing `workspace_updated`/refresh path. On `needs_input` the caller
    /// (WorkspacesView) opens NewWorkspaceSheet pre-filled with the
    /// suggestion.
    public func quickCreateWorkspace(projectId: String) async -> QuickCreateOutcome {
        do {
            let result = try await client.call(
                method: "workspace.quickCreate",
                params: ["projectId": projectId]
            ) as? [String: Any]
            let status = result?["status"] as? String
            switch status {
            case "created":
                await refreshWorkspaces()
                return .created
            case "needs_input":
                guard let suggestedDict = result?["suggested"] as? [String: Any],
                      let suggestion = WorkspaceSuggestion(json: suggestedDict) else {
                    return .failed("malformed needs_input response")
                }
                return .needsInput(suggestion)
            default:
                return .failed("unexpected status: \(status ?? "nil")")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
```

- [ ] **Step 3: Build the iOS app to confirm no compile errors**

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "iOS: add quickCreateWorkspace + WorkspaceSuggestion"
```

---

## Task 8: iOS — `NewWorkspaceSheet` accepts `WorkspaceSuggestion`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift:4-130`

Extend the existing sheet to accept an optional suggestion that pre-fills name, branch, provider, model, and build mode. When the suggestion is provided, the `.onAppear` block uses those values instead of the current defaults. All fields stay editable. The "Create" button continues to call `workspace.create` (not `quickCreate`); once the user has filled gaps, this is a normal creation.

- [ ] **Step 1: Add `suggestion` parameter and seed state**

In `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`, inside `NewWorkspaceSheet`:

Add the parameter (line 7-8, just below `preselectedProjectId`):

```swift
    var preselectedProjectId: String? = nil
    var suggestion: WorkspaceSuggestion? = nil
```

Replace the `.onAppear` block (lines 111-116):

```swift
        .onAppear {
            // Seed projectId from the explicit pre-selection or the first
            // available project. Suggestion-derived fields override the
            // existing defaults below.
            projectId = preselectedProjectId ?? connection.projects.first?.id ?? ""
            if let s = suggestion {
                name = s.name
                if let b = s.baseBranch { baseBranch = b }
                if let pid = s.providerId { providerId = pid }
                if let mid = s.modelId, !mid.isEmpty {
                    modelId = mid
                    manualMode = true   // skip auto-load; we already have one
                }
                if let bm = s.buildMode { buildMode = bm }
            } else {
                providerId = connection.providers.first?.id ?? ""
                buildMode = effectiveProjectDefault()
            }
            // Always kick off model loading unless we already have a model
            // from the suggestion (which set manualMode above).
            if !manualMode {
                Task { await loadModels() }
            }
        }
```

The `manualMode = true` shortcut is intentional: the suggestion's `modelId` is a valid choice (it came from inheritance), so we don't need to round-trip the discovered list to render it. The user can still flip the toggle off and pick a different model.

- [ ] **Step 2: Build to confirm no compile errors**

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/CreateSheets.swift
git commit -m "iOS: pre-fill NewWorkspaceSheet from a suggestion"
```

---

## Task 9: iOS — "+" button on each project header, outcome handling

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift`

Adds the per-project plus button and the state plumbing for the `needs_input` recovery path. The button is disabled when no providers are configured (matching the toolbar menu's existing guard).

- [ ] **Step 1: Add suggestion state**

In `WorkspacesView`, add a new `@State` next to `preselectedProjectId` (around line 13):

```swift
    @State private var preselectedProjectId: String? = nil
    @State private var pendingSuggestion: WorkspaceSuggestion? = nil
```

- [ ] **Step 2: Wire the suggestion through to the sheet**

In the `.sheet(isPresented: $showingNewWorkspace)` block (lines 72-78), pass the suggestion:

```swift
        .sheet(isPresented: $showingNewWorkspace, onDismiss: {
            // Always clear once the sheet closes so the next open is clean.
            pendingSuggestion = nil
        }) {
            NewWorkspaceSheet(
                connection: connection,
                isPresented: $showingNewWorkspace,
                preselectedProjectId: preselectedProjectId,
                suggestion: pendingSuggestion
            )
        }
```

- [ ] **Step 3: Add the "+" button to the project header**

Inside the `DisclosureGroup` `label:` HStack (lines 191-202), insert a `Button` between the project name `Text` and the count capsule:

```swift
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.blue)
                                Text(group.project.name).font(.headline)
                                Spacer()
                                Button {
                                    Task { await runQuickCreate(projectId: group.project.id) }
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.body)
                                }
                                .buttonStyle(.borderless)
                                .disabled(connection.providers.isEmpty)
                                .accessibilityLabel("New workspace in \(group.project.name)")
                                Text("\(group.workspaces.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
```

`buttonStyle(.borderless)` is required so SwiftUI doesn't dispatch the `DisclosureGroup`'s expand/collapse on tap.

- [ ] **Step 4: Add the `runQuickCreate` helper**

Add at the bottom of `WorkspacesView`, just before the closing `}` of the struct (around line 247):

```swift
    @MainActor
    private func runQuickCreate(projectId: String) async {
        let outcome = await connection.quickCreateWorkspace(projectId: projectId)
        switch outcome {
        case .created:
            // Workspace appears via refreshWorkspaces() inside the call.
            break
        case .needsInput(let suggestion):
            preselectedProjectId = projectId
            pendingSuggestion = suggestion
            showingNewWorkspace = true
        case .failed(let msg):
            // Match the rename flow's inline-error behavior: surface via
            // the connection's existing error path so the user sees it on
            // the WorkspacesView's standard error overlay.
            connection.state = .error(msg)
        }
    }
```

If `connection.state` setter isn't accessible from outside (it's not on the public surface — re-check), use `connection` to surface this another way. Inspect `ConnectionStore` first:

```bash
grep -n "public var state\|public func.*Error" ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift | head -5
```

If `state` is `public var` — fine, the assignment compiles. If it's not public, add a public method on `ConnectionStore` or fall back to a local `@State` `var quickCreateError: String?` mirrored as a `.alert` modifier on `WorkspacesView` (similar to the Mac's `RootView.quickCreateError` pattern).

- [ ] **Step 5: Build the iOS app**

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift
git commit -m "iOS: per-project + button + needs_input fallback sheet"
```

---

## Task 10: End-to-end smoke test

**Files:** none (manual test).

Validates the full happy path and the `needs_input` recovery path against a live Mac+iOS pairing.

- [ ] **Step 1: Start a fresh Mac app build**

```bash
bash scripts/build-app.sh
open dist/Multiharness.app
```

- [ ] **Step 2: Configure a clean test scenario**

Inside the Mac app:
1. Add at least one project (any local git repo).
2. Add at least one provider (e.g. an OpenAI-compatible local one, or use existing OAuth).
3. **Do not** set the project's default provider/model. **Do not** create any workspace yet.
4. **Do not** set the global default yet.

Enable Remote access in Settings; pair the iOS sim or device.

- [ ] **Step 3: iOS — confirm `needs_input` recovery**

In the iOS app:
1. Tap the "+" on the project row.
2. Expected: `NewWorkspaceSheet` opens, name field is **pre-populated** with a random adjective-noun (e.g. "fluffy-otter"), branch field is "main".
3. Pick a provider and model, tap Create.
4. Expected: workspace appears in the list.

- [ ] **Step 4: iOS — confirm fully resolved quick-create after first success**

1. Tap the "+" again on the same project.
2. Expected: **no sheet** appears. A new workspace just shows up in the list within ~1s, with a different random name.

- [ ] **Step 5: Mac — configure global default and validate Mac quick-create**

1. Delete the workspaces just created (or pick a different project with no defaults).
2. Open Settings → Defaults → pick the same provider, pick a model, Save.
3. On the Mac sidebar, click the "+" next to the project. Expected: a new workspace is created, no error dialog.

- [ ] **Step 6: iOS — validate that global default unblocks the iOS path**

1. Delete the project's workspaces again so there's nothing to inherit from.
2. iOS: tap "+" on the project. Expected: workspace created instantly, **no sheet** (the global default resolved the model).

- [ ] **Step 7: Iterate until clean**

If any step fails, fix the underlying issue and re-run the affected step. No commit needed for this task — it's pure validation.

---

## Self-Review

Spec coverage:
- Section 1 (global default storage + accessor + UI) → Tasks 1, 4.
- Section 2 (updated inheritance chain) → Task 2.
- Section 3 (relay method `workspace.quickCreate`, response shapes, helper extraction) → Tasks 2, 5, 6.
- Section 4 (iOS UI: button, store, sheet, suggestion type, outcome enum) → Tasks 7, 8, 9.
- Section 5 (Mac parity: pass globalDefault into quickCreate) → Task 3.
- Test plan items → covered by Tasks 1, 2, 10. (No iOS unit tests — there is no XCTest target on the iOS package today, so behavior is validated via Task 10's smoke test.)

Type consistency:
- `QuickCreateResolution` defined in Task 2 is consumed unchanged in Task 5.
- `quickCreate`'s extended signature `globalDefault: (UUID, String)?` is used identically in Tasks 2, 3, 5.
- `WorkspaceSuggestion`'s field set matches the relay's `suggested` payload (Task 5 ↔ Task 7).
- `QuickCreateOutcome.needsInput(WorkspaceSuggestion)` cases are produced in Task 7 and consumed in Task 9.

Placeholder scan: none.

---

**Plan complete and saved to `docs/superpowers/plans/2026-04-30-ios-quick-create-workspace.md`.**

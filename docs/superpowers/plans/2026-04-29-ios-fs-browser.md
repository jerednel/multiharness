# iOS Add-Project FS Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iOS Add-project sheet's free-text path field with a folder navigator that drills the Mac filesystem over a new `fs.list` relay RPC.

**Architecture:** Pure listing helper in `MultiharnessCore` (testable). Mac wraps it in a `fs.list` relay handler. Sidecar adds the method to its relayed list. iOS gets a `ConnectionStore.listFolders` and a recursive `BrowseFolderView` pushed via `NavigationLink`. The form's `NavigationStack` gets a `NavigationPath` so "Use this folder" can pop straight back to the form root.

**Tech Stack:** Swift / SwiftUI (iOS + macOS), Bun + TypeScript (sidecar), XCTest, JSON-RPC over WebSocket.

**Spec:** `docs/superpowers/specs/2026-04-29-ios-fs-browser-design.md`

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `Sources/MultiharnessCore/RemoteFs.swift` | new | Pure listing helper (`RemoteFs.list(path:)`) — no `RelayHandler` deps; testable |
| `Tests/MultiharnessCoreTests/RemoteFsTests.swift` | new | XCTest cases against tmpdir trees |
| `Sources/Multiharness/RemoteHandlers.swift` | modify | Add `fsList` handler that wraps `RemoteFs.list` and shapes the JSON response |
| `sidecar/src/methods.ts` | modify | Append `"fs.list"` to the relayed-methods array |
| `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` | modify | New `FolderEntry`/`FolderListing` types + `listFolders(path:)` |
| `ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift` | new | Recursive SwiftUI navigator |
| `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` | modify | Restructure `NewProjectSheet` (Browse → Discovered → Details) |

---

### Task 1: Pure listing helper in `MultiharnessCore` (TDD)

**Files:**
- Create: `Sources/MultiharnessCore/RemoteFs.swift`
- Test: `Tests/MultiharnessCoreTests/RemoteFsTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Create `Tests/MultiharnessCoreTests/RemoteFsTests.swift`:

```swift
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
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `swift test --filter RemoteFsTests`
Expected: build failure (`RemoteFs` undefined).

- [ ] **Step 1.3: Implement the helper**

Create `Sources/MultiharnessCore/RemoteFs.swift`:

```swift
import Foundation

public struct FsEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isGitRepo: Bool

    public init(name: String, path: String, isGitRepo: Bool) {
        self.name = name
        self.path = path
        self.isGitRepo = isGitRepo
    }
}

public struct FsListing: Sendable, Equatable {
    public let path: String
    public let parent: String?
    public let entries: [FsEntry]

    public init(path: String, parent: String?, entries: [FsEntry]) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}

public enum RemoteFs {

    public enum ListError: Error, LocalizedError {
        case notADirectory(String)
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "path does not exist or is not a directory: \(p)"
            case .underlying(let m): return m
            }
        }
    }

    /// List the immediate subdirectories of `path`. Hidden (dot-prefixed)
    /// entries and regular files are filtered out. `isGitRepo` is true when
    /// the entry contains a `.git` (file or directory — worktrees use a file).
    public static func list(path: String) throws -> FsListing {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ListError.notADirectory(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonicalPath = url.path

        let raw: [URL]
        do {
            raw = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ListError.underlying((error as NSError).localizedDescription)
        }

        var entries: [FsEntry] = []
        entries.reserveCapacity(raw.count)
        for entry in raw {
            let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard entryIsDir else { continue }
            let gitPath = entry.appendingPathComponent(".git").path
            let isGitRepo = fm.fileExists(atPath: gitPath)
            entries.append(FsEntry(
                name: entry.lastPathComponent,
                path: entry.standardizedFileURL.path,
                isGitRepo: isGitRepo
            ))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let parent: String?
        if canonicalPath == "/" {
            parent = nil
        } else {
            parent = url.deletingLastPathComponent().standardizedFileURL.path
        }
        return FsListing(path: canonicalPath, parent: parent, entries: entries)
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

Run: `swift test --filter RemoteFsTests`
Expected: 7 tests pass.

- [ ] **Step 1.5: Run the full Swift test suite to confirm no regressions**

Run: `swift test`
Expected: all tests pass (existing 5 + new 7 = 12).

- [ ] **Step 1.6: Commit**

```bash
git add Sources/MultiharnessCore/RemoteFs.swift Tests/MultiharnessCoreTests/RemoteFsTests.swift
git commit -m "Add RemoteFs.list directory helper for fs.list RPC"
```

---

### Task 2: Mac `fs.list` handler + sidecar relay wiring

**Files:**
- Modify: `Sources/Multiharness/RemoteHandlers.swift`
- Modify: `sidecar/src/methods.ts`

- [ ] **Step 2.1: Add `fs.list` to sidecar relayed methods**

Edit `sidecar/src/methods.ts` lines 146–155. Append `"fs.list"` to the array:

```ts
  // ── Relayed methods ─────────────────────────────────────────────────────
  // These are forwarded to the registered Mac handler client (which has
  // SQLite, git, NSOpenPanel, etc.) and the Mac's response comes back here.
  for (const m of [
    "workspace.create",
    "project.scan",
    "project.create",
    "models.listForProvider",
    "fs.list",
  ]) {
    d.register(m, async (params) => {
      return await relay.dispatch(m, params);
    });
  }
```

- [ ] **Step 2.2: Add the `fsList` handler to `RemoteHandlers`**

Edit `Sources/Multiharness/RemoteHandlers.swift`. In `RemoteHandlers.register`, add the registration immediately after `models.listForProvider`:

```swift
        await relay.register(method: "models.listForProvider") { params in
            try await Self.modelsListForProvider(params: params, env: env, appStore: appStore)
        }
        await relay.register(method: "fs.list") { params in
            try await Self.fsList(params: params)
        }
    }
```

Then add the handler implementation. Place it after `projectScan` (and before `// MARK: - project.create`):

```swift
    // MARK: - fs.list

    /// List immediate subdirectories of a path on the Mac so iOS can drill
    /// into arbitrary folders when adding a project. Hidden entries and
    /// regular files are filtered out. Defaults to `$HOME` when no path
    /// is provided.
    @MainActor
    private static func fsList(params: [String: Any]) async throws -> Any? {
        let raw = (params["path"] as? String)?.trimmingCharacters(in: .whitespaces)
        let path: String = (raw?.isEmpty == false ? raw! :
                            FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            let listing = try RemoteFs.list(path: path)
            return [
                "path": listing.path,
                "parent": (listing.parent as Any?) ?? NSNull(),
                "entries": listing.entries.map { e in
                    [
                        "name": e.name,
                        "path": e.path,
                        "isGitRepo": e.isGitRepo,
                    ] as [String: Any]
                },
            ] as [String: Any]
        } catch {
            throw RemoteError.bad((error as? RemoteFs.ListError)?.errorDescription
                                  ?? error.localizedDescription)
        }
    }
```

- [ ] **Step 2.3: Verify the Swift build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 2.4: Verify the sidecar typecheck**

Run: `cd sidecar && bun run typecheck`
Expected: no errors.

- [ ] **Step 2.5: Run existing tests to confirm no regressions**

Run: `swift test`
Expected: all tests pass.

Run: `cd sidecar && bun test`
Expected: all sidecar tests pass.

- [ ] **Step 2.6: Commit**

```bash
git add sidecar/src/methods.ts Sources/Multiharness/RemoteHandlers.swift
git commit -m "Wire fs.list relay handler"
```

---

### Task 3: `ConnectionStore.listFolders` for iOS

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`

- [ ] **Step 3.1: Add the DTOs and `listFolders` method**

Edit `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`. Insert immediately after `scanRepos` (current line 126):

```swift
    public func listFolders(path: String?) async throws -> FolderListing {
        var params: [String: Any] = [:]
        if let p = path, !p.isEmpty { params["path"] = p }
        let result = try await client.call(method: "fs.list", params: params) as? [String: Any]
        let resolvedPath = (result?["path"] as? String) ?? (path ?? "")
        let parent = result?["parent"] as? String  // missing or NSNull → nil
        let arr = (result?["entries"] as? [[String: Any]]) ?? []
        let entries = arr.compactMap { dict -> FolderEntry? in
            guard let name = dict["name"] as? String,
                  let path = dict["path"] as? String else { return nil }
            let isGit = (dict["isGitRepo"] as? Bool) ?? false
            return FolderEntry(name: name, path: path, isGitRepo: isGit)
        }
        return FolderListing(path: resolvedPath, parent: parent, entries: entries)
    }
```

Then, at the bottom of the file (after the `DiscoveredModel` struct, around line 180), add:

```swift
public struct FolderEntry: Identifiable, Sendable, Hashable {
    public let name: String
    public let path: String
    public let isGitRepo: Bool
    public var id: String { path }
}

public struct FolderListing: Sendable {
    public let path: String
    public let parent: String?
    public let entries: [FolderEntry]
}
```

- [ ] **Step 3.2: Verify iOS package builds**

Run: `bash scripts/build-ios.sh`
Expected: build succeeds (full xcodegen + xcodebuild).

- [ ] **Step 3.3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "Add listFolders to iOS ConnectionStore"
```

---

### Task 4: `BrowseFolderView`

**Files:**
- Create: `ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift`

- [ ] **Step 4.1: Create the view**

Create `ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift`:

```swift
import SwiftUI
import MultiharnessClient

/// Recursive directory navigator. Pushed onto `NewProjectSheet`'s
/// `NavigationStack` so each subdirectory tap appends to the same
/// `NavigationPath`. The "Use this folder" button calls `onPick` with
/// the *current* directory and the parent resets the navigation path
/// to pop back to the form root.
struct BrowseFolderView: View {
    @Bindable var connection: ConnectionStore
    /// nil → start at $HOME (resolved by the Mac).
    let initialPath: String?
    /// Called with the path of the directory currently being viewed when
    /// the user taps "Use this folder". The caller is responsible for
    /// popping the navigation stack.
    let onPick: (String) -> Void

    @State private var listing: FolderListing?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading && listing == nil {
                ProgressView().controlSize(.large)
            } else if let err = error, listing == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
                .padding()
            } else if let listing {
                List {
                    Section {
                        Text(listing.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Section {
                        if listing.entries.isEmpty {
                            Text("No subfolders.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(listing.entries) { entry in
                                NavigationLink(value: entry) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(entry.name)
                                        Spacer()
                                        if entry.isGitRepo {
                                            Text("git")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule().fill(Color.secondary.opacity(0.15))
                                                )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyView()
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Use this folder") {
                    if let p = listing?.path { onPick(p) }
                }
                .disabled(listing == nil)
            }
        }
        .navigationDestination(for: FolderEntry.self) { entry in
            BrowseFolderView(
                connection: connection,
                initialPath: entry.path,
                onPick: onPick
            )
        }
        .task { await load() }
    }

    private var displayTitle: String {
        guard let path = listing?.path else { return "Browse" }
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            listing = try await connection.listFolders(path: initialPath)
        } catch {
            self.error = String(describing: error)
        }
    }
}
```

- [ ] **Step 4.2: Build to confirm it compiles in isolation**

Run: `bash scripts/build-ios.sh`
Expected: build succeeds. (`BrowseFolderView` is unused so far but should still compile.)

- [ ] **Step 4.3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift
git commit -m "Add BrowseFolderView to iOS"
```

---

### Task 5: Restructure `NewProjectSheet`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`

- [ ] **Step 5.1: Replace the body of `NewProjectSheet`**

In `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`, replace the entire `NewProjectSheet` struct (lines 147–254 of the current file) with:

```swift
struct NewProjectSheet: View {
    @Bindable var connection: ConnectionStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var repoPath: String = ""
    @State private var baseBranch: String = "main"
    @State private var candidates: [(name: String, path: String)] = []
    @State private var loadingScan = false
    @State private var error: String?
    @State private var working = false
    @State private var browsePath = NavigationPath()

    var body: some View {
        NavigationStack(path: $browsePath) {
            Form {
                Section("Browse") {
                    NavigationLink(value: BrowseDestination.root) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Browse for a folder")
                            if !repoPath.isEmpty {
                                Text(repoPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }

                Section("Pick a discovered repository") {
                    if loadingScan {
                        HStack { ProgressView(); Text("Scanning…").font(.caption) }
                    } else if candidates.isEmpty {
                        Text("No git repositories found in common locations.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates, id: \.path) { repo in
                            Button {
                                if name.isEmpty { name = repo.name }
                                repoPath = repo.path
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.name).font(.body)
                                        Text(repo.path).font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer()
                                    if repoPath == repo.path {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Details") {
                    TextField("Display name", text: $name)
                    TextField("Default base branch", text: $baseBranch)
                }

                if let err = error {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        Task { await create() }
                    }
                    .disabled(working || !canCreate)
                }
            }
            .navigationDestination(for: BrowseDestination.self) { _ in
                BrowseFolderView(
                    connection: connection,
                    initialPath: nil,
                    onPick: { picked in
                        let basename = (picked as NSString).lastPathComponent
                        if name.isEmpty { name = basename }
                        repoPath = picked
                        browsePath = NavigationPath()
                    }
                )
            }
            .task { await scan() }
        }
    }

    private enum BrowseDestination: Hashable { case root }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !repoPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor
    private func scan() async {
        loadingScan = true
        defer { loadingScan = false }
        do {
            candidates = try await connection.scanRepos()
        } catch {
            self.error = String(describing: error)
        }
    }

    @MainActor
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await connection.createProject(
                name: name,
                repoPath: repoPath,
                defaultBaseBranch: baseBranch
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
```

- [ ] **Step 5.2: Build and run iOS**

Run: `bash scripts/build-ios.sh`
Expected: build succeeds.

- [ ] **Step 5.3: Manual smoke test on simulator**

Run: `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`
Expected:
- Sim launches the iOS app.
- Tap the "+" / Add project sheet entry point.
- The sheet shows three sections in order: **Browse**, **Pick a discovered repository**, **Details**.
- The free-text path field is gone.
- Tap **"Browse for a folder"** → `BrowseFolderView` opens at `$HOME`. Header shows the home path.
- Drill into one or two subdirectories. The back button returns to the previous level.
- Inside a folder containing `.git`, tap **"Use this folder"** in the toolbar.
- The sheet pops all the way back to the form root.
- The display name is autofilled with the folder's basename (only if the field was empty).
- The Browse row caption shows the chosen absolute path.
- The Add button is enabled. Tapping Add creates the project (or shows a sensible error if the chosen folder lacks `.git`).

- [ ] **Step 5.4: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/CreateSheets.swift
git commit -m "Restructure NewProjectSheet around fs browser"
```

---

### Task 6: Final verification + PR prep

- [ ] **Step 6.1: Re-run all automated checks**

Run in parallel:
- `swift test`
- `cd sidecar && bun run typecheck && bun test`
- `bash scripts/build-ios.sh`

Expected: every check passes.

- [ ] **Step 6.2: Visual diff review**

Run: `git diff origin/main...HEAD --stat`
Expected: only the files listed in **File Structure** above appear.

- [ ] **Step 6.3: Push and open PR (only if user requests)**

Do not push or open a PR unless explicitly asked.

---

## Notes for the implementer

- `NavigationPath()` reset is the canonical SwiftUI way to pop to the root of a `NavigationStack(path:)`; don't replace it with `dismiss` or environment hackery.
- Don't add security-scoped bookmark logic here. TCC denials surface as listing errors; that's the agreed-on behavior.
- Don't reintroduce the manual `repoPath` text field. If a power user needs to type a path, they can use the discovered list (which is just a convenience over typing) or browse to it.
- `RemoteFs.list` is `@MainActor`-free on purpose so the test target (and any future caller) can use it without an actor hop. The handler in `RemoteHandlers.swift` stays `@MainActor` to match the rest of the file.
- The recursive `BrowseFolderView` shares the `NavigationPath` with `NewProjectSheet` — appending a `FolderEntry` value drills, resetting the path pops everything.

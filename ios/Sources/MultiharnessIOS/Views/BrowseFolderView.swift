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

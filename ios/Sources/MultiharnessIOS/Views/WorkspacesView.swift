import SwiftUI
import MultiharnessClient

struct WorkspacesView: View {
    @Bindable var connection: ConnectionStore
    let onUnpair: () -> Void
    let onSwitchMac: () -> Void
    let onAddMac: () -> Void
    let paired: [PairingStore.Pairing]
    @State private var showingNewWorkspace = false
    @State private var showingNewProject = false
    @State private var expandedProjectIds: Set<String> = []
    @State private var preselectedProjectId: String? = nil
    /// Set when the user just added a project; on the project sheet's
    /// dismissal we open the New Workspace sheet as a follow-up.
    @State private var pendingAutoNewWorkspace = false
    @State private var renameTarget: RemoteWorkspace? = nil

    var body: some View {
        Group {
            switch connection.state {
            case .connecting:
                connectingView
            case .disconnected:
                connectingView
            case .error(let msg):
                errorView(msg)
            case .connected:
                listView
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        preselectedProjectId = nil
                        showingNewWorkspace = true
                    } label: {
                        Label("New workspace", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(connection.projects.isEmpty || connection.providers.isEmpty)
                    Button {
                        showingNewProject = true
                    } label: {
                        Label("Add project", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    if paired.count > 1 {
                        Button {
                            onSwitchMac()
                        } label: {
                            Label("Switch Mac (\(paired.count))", systemImage: "macbook")
                        }
                    }
                    Button {
                        onAddMac()
                    } label: {
                        Label("Add another Mac", systemImage: "plus.app")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onUnpair()
                    } label: {
                        Label("Forget this Mac", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await connection.refreshWorkspaces() }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceSheet(
                connection: connection,
                isPresented: $showingNewWorkspace,
                preselectedProjectId: preselectedProjectId
            )
        }
        .sheet(
            isPresented: $showingNewProject,
            onDismiss: {
                // If the project sheet just successfully added a project AND
                // the system has at least one provider configured, fall
                // straight into "New workspace" so the user doesn't have to
                // re-open the menu. Cancel-without-add leaves the flag false.
                if pendingAutoNewWorkspace,
                   preselectedProjectId != nil,
                   !connection.providers.isEmpty {
                    showingNewWorkspace = true
                }
                pendingAutoNewWorkspace = false
            }
        ) {
            NewProjectSheet(
                connection: connection,
                isPresented: $showingNewProject
            ) { newProjectId in
                preselectedProjectId = newProjectId
                pendingAutoNewWorkspace = true
            }
        }
        .sheet(item: $renameTarget) { ws in
            RenameWorkspaceSheet(
                connection: connection,
                workspace: ws,
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            )
        }
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to \(connection.host):\(connection.port)…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Couldn't connect").font(.title3).bold()
            Text(msg).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                connection.connect()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var listView: some View {
        if connection.projects.isEmpty {
            ContentUnavailableView(
                "No projects yet",
                systemImage: "folder.badge.plus",
                description: Text("Tap ⋯ → Add project to get started.")
            )
        } else {
            List {
                ForEach(groupedByProject(), id: \.project.id) { group in
                    Section {
                        DisclosureGroup(
                            isExpanded: binding(for: group.project.id, autoExpand: group.workspaces.isEmpty)
                        ) {
                            if group.workspaces.isEmpty {
                                Button {
                                    preselectedProjectId = group.project.id
                                    showingNewWorkspace = true
                                } label: {
                                    Label("New workspace", systemImage: "plus.rectangle.on.rectangle")
                                }
                                .disabled(connection.providers.isEmpty)
                            } else {
                                ForEach(group.workspaces) { ws in
                                    NavigationLink(value: ws) {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(ws.name).font(.body)
                                                Text(ws.branchName).font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            LifecyclePill(state: ws.lifecycleState)
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            renameTarget = ws
                                        } label: {
                                            Label("Rename…", systemImage: "pencil")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.blue)
                                Text(group.project.name).font(.headline)
                                Spacer()
                                Text("\(group.workspaces.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: RemoteWorkspace.self) { ws in
                WorkspaceDetailView(connection: connection, workspace: ws)
            }
        }
    }

    /// Empty projects auto-expand so the inline "New workspace" button is
    /// immediately visible after the user adds a project. The `expandedProjectIds`
    /// set stores the user's explicit override — its meaning flips depending on
    /// the default: for non-empty projects, presence = expanded; for empty
    /// projects, presence = "user collapsed me, leave me alone".
    private func binding(for projectId: String, autoExpand: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let inSet = expandedProjectIds.contains(projectId)
                return autoExpand ? !inSet : inSet
            },
            set: { newValue in
                let store = autoExpand ? !newValue : newValue
                if store { expandedProjectIds.insert(projectId) }
                else { expandedProjectIds.remove(projectId) }
            }
        )
    }

    /// Groups workspaces under each project. Projects with no workspaces are
    /// kept so the user can still see them and add a workspace inline.
    private func groupedByProject() -> [(project: RemoteProject, workspaces: [RemoteWorkspace])] {
        let order = ["in_progress", "in_review", "done", "backlog", "cancelled"]
        let priority = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var buckets: [String: [RemoteWorkspace]] = [:]
        for w in connection.workspaces { buckets[w.projectId, default: []].append(w) }
        return connection.projects.map { p in
            let arr = buckets[p.id, default: []].sorted { a, b in
                let pa = priority[a.lifecycleState, default: 99]
                let pb = priority[b.lifecycleState, default: 99]
                if pa != pb { return pa < pb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return (p, arr)
        }
    }
}

struct RenameWorkspaceSheet: View {
    @Bindable var connection: ConnectionStore
    let workspace: RemoteWorkspace
    @Binding var isPresented: Bool

    @State private var draft: String
    @State private var error: String?
    @State private var inFlight = false
    @FocusState private var fieldFocused: Bool

    init(
        connection: ConnectionStore,
        workspace: RemoteWorkspace,
        isPresented: Binding<Bool>
    ) {
        self.connection = connection
        self.workspace = workspace
        self._isPresented = isPresented
        self._draft = State(initialValue: workspace.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workspace name", text: $draft)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                } footer: {
                    Text("Branch and worktree path stay the same — only the display name changes.")
                }
                if let err = error {
                    Section {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .disabled(!isValid || inFlight)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        let t = trimmed
        return !t.isEmpty && t.count <= 80 && t != workspace.name
    }

    private func commit() {
        guard isValid, !inFlight else { return }
        inFlight = true
        let id = workspace.id
        let newName = trimmed
        Task { @MainActor in
            defer { inFlight = false }
            do {
                try await connection.requestRename(workspaceId: id, newName: newName)
                isPresented = false
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

private struct LifecyclePill: View {
    let state: String
    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
    private var label: String {
        switch state {
        case "in_progress": return "in progress"
        case "in_review": return "in review"
        case "done": return "done"
        case "backlog": return "backlog"
        case "cancelled": return "cancelled"
        default: return state
        }
    }
    private var color: Color {
        switch state {
        case "in_progress": return .blue
        case "in_review": return .orange
        case "done": return .green
        case "backlog": return .gray
        case "cancelled": return .secondary
        default: return .gray
        }
    }
}

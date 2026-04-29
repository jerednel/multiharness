import SwiftUI
import MultiharnessClient

struct WorkspacesView: View {
    @Bindable var connection: ConnectionStore
    let onUnpair: () -> Void
    @State private var showingNewWorkspace = false
    @State private var showingNewProject = false
    @State private var expandedProjectIds: Set<String> = []

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
            NewWorkspaceSheet(connection: connection, isPresented: $showingNewWorkspace)
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(connection: connection, isPresented: $showingNewProject)
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
        if connection.workspaces.isEmpty {
            ContentUnavailableView(
                "No workspaces",
                systemImage: "rectangle.split.3x1",
                description: Text("Create a workspace on your Mac to see it here.")
            )
        } else {
            List {
                ForEach(groupedByProject(), id: \.project.id) { group in
                    Section {
                        DisclosureGroup(isExpanded: binding(for: group.project.id)) {
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

    private func binding(for projectId: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIds.contains(projectId) },
            set: { newValue in
                if newValue { expandedProjectIds.insert(projectId) }
                else { expandedProjectIds.remove(projectId) }
            }
        )
    }

    /// Returns groups of workspaces under each project. Projects with no
    /// workspaces are skipped. Within each project, workspaces are sorted
    /// by lifecycle priority then by name.
    private func groupedByProject() -> [(project: RemoteProject, workspaces: [RemoteWorkspace])] {
        let order = ["in_progress", "in_review", "done", "backlog", "cancelled"]
        let priority = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var buckets: [String: [RemoteWorkspace]] = [:]
        for w in connection.workspaces { buckets[w.projectId, default: []].append(w) }
        return connection.projects.compactMap { p in
            let arr = buckets[p.id, default: []].sorted { a, b in
                let pa = priority[a.lifecycleState, default: 99]
                let pb = priority[b.lifecycleState, default: 99]
                if pa != pb { return pa < pb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            guard !arr.isEmpty else { return nil }
            return (p, arr)
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

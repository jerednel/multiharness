import SwiftUI
import MultiharnessCore

struct WorkspaceSidebar: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(workspaceStore.grouped(), id: \.0) { (state, items) in
                Section(state.label) {
                    ForEach(items) { ws in
                        WorkspaceRow(ws: ws)
                            .tag(ws.id as UUID?)
                            .contextMenu { workspaceContextMenu(ws) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func workspaceContextMenu(_ ws: Workspace) -> some View {
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

struct WorkspaceRow: View {
    let ws: Workspace
    var showLifecycleDot: Bool = false

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

/// Sidebar mode that lists every project as a collapsible disclosure
/// group. Each project header has a quick-create "+" and a filter toggle
/// for grouping by lifecycle status. Defaults to a flat list per project,
/// sorted by recency, with a small lifecycle dot prepended to each row.
struct AllProjectsSidebar: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var selection: UUID?
    /// Called when the user taps "+" on a project header.
    var onQuickCreate: (Project) -> Void

    @State private var pendingReconcileProject: Project? = nil

    var body: some View {
        List(selection: $selection) {
            ForEach(appStore.projects) { project in
                ProjectDisclosure(
                    project: project,
                    workspaceStore: workspaceStore,
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
    }

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
                        WorkspaceRow(ws: ws)
                            .tag(ws.id as UUID?)
                            .contextMenu { workspaceContextMenu(ws) }
                    }
                }
            }
        } else {
            ForEach(items) { ws in
                WorkspaceRow(ws: ws, showLifecycleDot: true)
                    .tag(ws.id as UUID?)
                    .contextMenu { workspaceContextMenu(ws) }
            }
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ ws: Workspace) -> some View {
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

    static func expandedKey(_ id: UUID) -> String {
        "MultiharnessProjectExpanded.\(id.uuidString)"
    }

    static func groupKey(_ id: UUID) -> String {
        "MultiharnessProjectGroupByStatus.\(id.uuidString)"
    }
}

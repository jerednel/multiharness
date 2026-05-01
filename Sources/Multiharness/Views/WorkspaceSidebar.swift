import SwiftUI
import MultiharnessCore

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

struct RenameWorkspaceSheet: View {
    @Bindable var workspaceStore: WorkspaceStore
    let workspace: Workspace
    @Binding var isPresented: Bool

    @State private var draft: String
    @State private var error: String?
    @State private var inFlight: Bool = false

    init(
        workspaceStore: WorkspaceStore,
        workspace: Workspace,
        isPresented: Binding<Bool>
    ) {
        self.workspaceStore = workspaceStore
        self.workspace = workspace
        self._isPresented = isPresented
        self._draft = State(initialValue: workspace.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename workspace").font(.title2).bold()
            Text("Branch and worktree path stay the same — only the display name changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Workspace name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || inFlight)
            }
        }
        .padding(24)
        .frame(width: 420)
        .sheetEntry()
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
        let snapshot = workspace
        let newName = trimmed
        Task { @MainActor in
            defer { inFlight = false }
            do {
                try await workspaceStore.requestRename(snapshot, to: newName)
                isPresented = false
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

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
            } else if isUnseen {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unseen response")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverableRow(strong: true)
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
    @Bindable var agentRegistry: AgentRegistryStore
    @Binding var selection: UUID?
    let branchListService: BranchListService
    /// Called when the user taps "+" on a project header.
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
                    branchListService: branchListService,
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
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore
    let branchListService: BranchListService
    let onQuickCreate: () -> Void
    let onReconcile: () -> Void

    @State private var isExpanded: Bool
    @State private var groupByStatus: Bool
    @State private var showSettings = false
    @State private var renameTarget: Workspace?

    init(
        project: Project,
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        agentRegistry: AgentRegistryStore,
        branchListService: BranchListService,
        onQuickCreate: @escaping () -> Void,
        onReconcile: @escaping () -> Void
    ) {
        self.project = project
        self.appStore = appStore
        self.workspaceStore = workspaceStore
        self.agentRegistry = agentRegistry
        self.branchListService = branchListService
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
        .sheet(isPresented: $showSettings) {
            ProjectSettingsSheet(
                project: currentProject,
                appStore: appStore,
                branchListService: branchListService,
                onClose: { showSettings = false }
            )
        }
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

    private var currentProject: Project {
        appStore.projects.first(where: { $0.id == project.id }) ?? project
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(project.name).font(.body)
            Spacer()
            Menu {
                Toggle("Group by status", isOn: $groupByStatus)
                Divider()
                Button("Project settings…") { showSettings = true }
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
            .buttonStyle(.multiharnessIcon)
            .disabled(!hasEligibleWorkspaces)
            .help("Reconcile workspaces")
            Button(action: onQuickCreate) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.multiharnessIcon)
            .help("Quick-create workspace from \(project.defaultBaseBranch)")
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

    static func expandedKey(_ id: UUID) -> String {
        "MultiharnessProjectExpanded.\(id.uuidString)"
    }

    static func groupKey(_ id: UUID) -> String {
        "MultiharnessProjectGroupByStatus.\(id.uuidString)"
    }
}

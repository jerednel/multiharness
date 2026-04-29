import SwiftUI
import MultiharnessCore

struct RootView: View {
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore

    @State private var sidebarSelection: SidebarSelection = .workspaces
    @State private var showingNewWorkspace = false
    @State private var showingSettings = false
    @State private var showingNewProject = false

    enum SidebarSelection: Hashable { case workspaces, settings }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(appStore.selectedProject?.name ?? "Multiharness")
        .toolbar { toolbar }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceSheet(
                appStore: appStore,
                workspaceStore: workspaceStore,
                isPresented: $showingNewWorkspace
            )
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(appStore: appStore, isPresented: $showingNewProject)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(env: env, appStore: appStore, isPresented: $showingSettings)
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectPickerHeader(appStore: appStore, workspaceStore: workspaceStore, showingNewProject: $showingNewProject)
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if appStore.selectedProject != nil {
                WorkspaceSidebar(
                    workspaceStore: workspaceStore,
                    selection: Binding(
                        get: { workspaceStore.selectedWorkspaceId },
                        set: { workspaceStore.selectedWorkspaceId = $0 }
                    )
                )
            } else {
                ContentUnavailableView(
                    "No project selected",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a project to get started.")
                )
            }
            Spacer()
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                SidecarStatusBadge(status: appStore.sidecarStatus)
                if appStore.remoteActivityCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .foregroundStyle(.blue)
                        Text("iPhone request waiting")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
    }

    @ViewBuilder
    private var detail: some View {
        if let ws = workspaceStore.selected() {
            WorkspaceDetailView(
                workspace: ws,
                env: env,
                appStore: appStore,
                workspaceStore: workspaceStore,
                agentRegistry: agentRegistry
            )
        } else {
            ContentUnavailableView(
                "Select or create a workspace",
                systemImage: "rectangle.split.3x1",
                description: Text("Workspaces are git worktrees with their own agent threads.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingNewWorkspace = true
            } label: {
                Label("New workspace", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(appStore.selectedProject == nil || appStore.providers.isEmpty)

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

private struct ProjectPickerHeader: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var showingNewProject: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(appStore.projects) { p in
                    Button(action: {
                        appStore.selectedProjectId = p.id
                        workspaceStore.load(projectId: p.id)
                    }) {
                        Label(p.name, systemImage: appStore.selectedProjectId == p.id ? "checkmark" : "")
                    }
                }
                if !appStore.projects.isEmpty { Divider() }
                Button("Add project…") { showingNewProject = true }
                if let proj = appStore.selectedProject {
                    Divider()
                    Button("Delete \(proj.name)…", role: .destructive) {
                        appStore.removeProject(proj)
                        workspaceStore.load(projectId: appStore.selectedProjectId)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(appStore.selectedProject?.name ?? "Choose project")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SidecarStatusBadge: View {
    let status: SidecarManager.Status
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .crashed: return .red
        }
    }
    private var label: String {
        switch status {
        case .running(let port): return "sidecar :\(port)"
        case .starting: return "sidecar starting…"
        case .stopped: return "sidecar stopped"
        case .crashed(let r): return "sidecar crashed (\(r))"
        }
    }
}

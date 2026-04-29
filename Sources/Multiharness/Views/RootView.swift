import SwiftUI
import MultiharnessCore
import AppKit

struct RootView: View {
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore

    @State private var sidebarSelection: SidebarSelection = .workspaces
    @State private var showingNewWorkspace = false
    @State private var showingSettings = false
    @State private var showingNewProject = false
    @State private var quickCreateError: String?

    enum SidebarSelection: Hashable { case workspaces, settings }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(navigationTitle)
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
        .alert("Couldn't create workspace", isPresented: Binding(
            get: { quickCreateError != nil },
            set: { if !$0 { quickCreateError = nil } }
        ), actions: {
            Button("OK") { quickCreateError = nil }
        }, message: {
            Text(quickCreateError ?? "")
        })
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: appStore.sidebarMode) { _, new in
            reloadForMode(new)
        }
    }

    private var navigationTitle: String {
        switch appStore.sidebarMode {
        case .singleProject:
            return appStore.selectedProject?.name ?? "Multiharness"
        case .allProjects:
            return "Multiharness"
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch appStore.sidebarMode {
            case .singleProject:
                ProjectPickerHeader(
                    appStore: appStore,
                    workspaceStore: workspaceStore,
                    showingNewProject: $showingNewProject,
                    onQuickCreate: { runQuickCreate(project: $0) }
                )
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
            case .allProjects:
                AllProjectsHeader(showingNewProject: $showingNewProject)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                if appStore.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a project to get started.")
                    )
                } else {
                    AllProjectsSidebar(
                        appStore: appStore,
                        workspaceStore: workspaceStore,
                        selection: Binding(
                            get: { workspaceStore.selectedWorkspaceId },
                            set: { newID in
                                workspaceStore.selectedWorkspaceId = newID
                                if let id = newID,
                                   let ws = workspaceStore.workspaces.first(where: { $0.id == id }),
                                   appStore.selectedProjectId != ws.projectId {
                                    appStore.selectedProjectId = ws.projectId
                                }
                            }
                        ),
                        onQuickCreate: { runQuickCreate(project: $0) }
                    )
                }
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

    private func runQuickCreate(project: Project) {
        do {
            _ = try workspaceStore.quickCreate(
                project: project,
                providers: appStore.providers,
                gitUserName: NSUserName()
            )
            if appStore.sidebarMode == .allProjects {
                appStore.selectedProjectId = project.id
            }
        } catch {
            quickCreateError = String(describing: error)
        }
    }

    private func reloadForMode(_ mode: SidebarMode) {
        switch mode {
        case .singleProject:
            workspaceStore.load(projectId: appStore.selectedProjectId)
        case .allProjects:
            workspaceStore.loadAll()
        }
    }
}

private struct ProjectPickerHeader: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var showingNewProject: Bool
    var onQuickCreate: (Project) -> Void

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
            if let proj = appStore.selectedProject {
                Button {
                    onQuickCreate(proj)
                } label: {
                    Image(systemName: "plus").font(.body)
                }
                .buttonStyle(.borderless)
                .disabled(appStore.providers.isEmpty)
                .help("Quick-create workspace")
            }
        }
    }
}

private struct AllProjectsHeader: View {
    @Binding var showingNewProject: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
            Text("Projects").font(.headline)
            Spacer()
            Button {
                showingNewProject = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Add project")
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

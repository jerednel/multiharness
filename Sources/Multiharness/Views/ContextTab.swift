import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ContextTab: View {
    let workspace: Workspace
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let branchListService: BranchListService

    @State private var workspaceText: String = ""
    @State private var loadedForId: UUID?
    @State private var savingWorkspace: SaveState = .idle
    @State private var workspaceDebounceTask: Task<Void, Never>?
    @State private var showProjectSettings = false

    enum SaveState { case idle, saving, saved, error(String) }

    private var project: Project? {
        appStore.projects.first(where: { $0.id == workspace.projectId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Context").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSection
                    workspaceSection
                }
                .padding(12)
            }
        }
        .task(id: workspace.id) {
            // .task fires on every view appearance, not just when id changes.
            // macOS TabView re-mounts inactive tabs on switch back, so this
            // closure runs every time the user returns to the Context tab.
            // Only re-seed workspaceText when we're actually looking at a
            // different workspace — otherwise we'd clobber unsaved edits.
            if loadedForId != workspace.id {
                workspaceText = workspace.contextInstructions
                loadedForId = workspace.id
                savingWorkspace = .idle
            }
        }
        .sheet(isPresented: $showProjectSettings) {
            if let p = project {
                ProjectSettingsSheet(
                    project: p,
                    appStore: appStore,
                    branchListService: branchListService,
                    onClose: { showProjectSettings = false }
                )
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Project").font(.subheadline).bold()
                Spacer()
                Button("Edit in project settings →") {
                    showProjectSettings = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            let projectText = project?.contextInstructions ?? ""
            if projectText.isEmpty {
                Text("No project-wide instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(projectText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Workspace").font(.subheadline).bold()
                Spacer()
                statusLabel
            }
            TextEditor(text: $workspaceText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .padding(4)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: workspaceText) { _, new in
                    scheduleSave(new)
                }
            HStack {
                Button("Copy from CLAUDE.md") { copyFromClaudeMd() }
                    .disabled(!claudeMdExists)
                    .help(claudeMdExists ? "Replace the workspace context with this worktree's CLAUDE.md" : "No CLAUDE.md found in this worktree")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch savingWorkspace {
        case .idle: EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved:
            Text("Saved").font(.caption).foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    private var claudeMdPath: String {
        (workspace.worktreePath as NSString).appendingPathComponent("CLAUDE.md")
    }

    private var claudeMdExists: Bool {
        FileManager.default.fileExists(atPath: claudeMdPath)
    }

    private func copyFromClaudeMd() {
        guard let data = try? String(contentsOfFile: claudeMdPath, encoding: .utf8) else {
            savingWorkspace = .error("Could not read CLAUDE.md")
            return
        }
        workspaceText = data
        scheduleSave(data)
    }

    private func scheduleSave(_ text: String) {
        workspaceDebounceTask?.cancel()
        savingWorkspace = .saving
        workspaceDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                try await appStore.setWorkspaceContext(
                    workspaceStore: workspaceStore,
                    workspaceId: workspace.id,
                    text: text
                )
                savingWorkspace = .saved
            } catch {
                savingWorkspace = .error(String(describing: error))
            }
        }
    }
}

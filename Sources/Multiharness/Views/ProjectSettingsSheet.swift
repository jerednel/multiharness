import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ProjectSettingsSheet: View {
    let project: Project
    @Bindable var appStore: AppStore
    let branchListService: BranchListService
    var onClose: () -> Void

    @State private var text: String = ""
    @State private var saveState: SaveState = .idle
    @State private var debounceTask: Task<Void, Never>?
    @State private var baseBranchSelection: String = ""
    @State private var baseBranchSaveState: SaveState = .idle
    @State private var savedBaseBranch: String = ""

    enum SaveState { case idle, saving, saved, error(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project settings").font(.title3).bold()
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            Text(project.name).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context").font(.subheadline).bold()
                    Spacer()
                    statusLabel(for: saveState)
                }
                Text("Applies to every workspace in this project. Injected on every turn.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding(4)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: text) { _, new in
                        scheduleSave(new)
                    }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Default base branch").font(.subheadline).bold()
                    Spacer()
                    statusLabel(for: baseBranchSaveState)
                }
                Text("New workspaces in this project start from this branch — used by Quick Create and pre-selected in the New Workspace sheet. Selection auto-saves.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Currently saved:").font(.caption).foregroundStyle(.secondary)
                    Text(savedBaseBranch.isEmpty ? "—" : savedBaseBranch)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                BranchPicker(
                    selection: $baseBranchSelection,
                    initialDefault: project.defaultBaseBranch
                ) { refresh in
                    try await branchListService.list(
                        projectId: project.id,
                        repoPath: project.repoPath,
                        refresh: refresh
                    )
                }
                .onChange(of: baseBranchSelection) { _, new in
                    saveBaseBranch(new)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 600)
        .task(id: project.id) {
            text = project.contextInstructions
            saveState = .idle
            baseBranchSaveState = .idle
            savedBaseBranch = project.defaultBaseBranch
        }
    }

    @ViewBuilder
    private func statusLabel(for state: SaveState) -> some View {
        switch state {
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

    private func scheduleSave(_ value: String) {
        debounceTask?.cancel()
        saveState = .saving
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                try await appStore.setProjectContext(projectId: project.id, text: value)
                saveState = .saved
            } catch {
                saveState = .error(String(describing: error))
            }
        }
    }

    private func saveBaseBranch(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != savedBaseBranch else { return }
        baseBranchSaveState = .saving
        Task { @MainActor in
            do {
                try appStore.setProjectDefaultBaseBranch(
                    projectId: project.id, value: trimmed
                )
                savedBaseBranch = trimmed
                baseBranchSaveState = .saved
            } catch {
                baseBranchSaveState = .error(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }
}

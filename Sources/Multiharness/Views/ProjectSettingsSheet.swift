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

    // QA defaults — these mirror the persisted project columns and the
    // section's setters write through to AppStore.
    @State private var qaEnabled: Bool = false
    @State private var qaProviderId: UUID?
    @State private var qaModelId: String = ""
    @State private var qaSaveState: SaveState = .idle

    enum SaveState { case idle, saving, saved, error(String) }

    var body: some View {
        ScrollView {
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
                Divider()
                qaDefaultsSection
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 720)
        .task(id: project.id) {
            text = project.contextInstructions
            saveState = .idle
            baseBranchSaveState = .idle
            savedBaseBranch = project.defaultBaseBranch
            qaEnabled = project.defaultQaEnabled
            qaProviderId = project.defaultQaProviderId
            qaModelId = project.defaultQaModelId ?? ""
            qaSaveState = .idle
        }
        .sheetEntry()
    }

    @ViewBuilder
    private var qaDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("QA review (defaults for new workspaces)")
                    .font(.subheadline).bold()
                Spacer()
                statusLabel(for: qaSaveState)
            }
            Text(qaToggleCaption)
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable QA review by default for new workspaces", isOn: $qaEnabled)
                .toggleStyle(.switch)
                .onChange(of: qaEnabled) { _, new in
                    saveQaEnabled(new)
                }
            Text("Default QA model").font(.caption).foregroundStyle(.secondary)
            Picker("Provider", selection: Binding(
                get: { qaProviderId ?? UUID() },
                set: { newId in
                    qaProviderId = newId
                    qaModelId = ""
                    saveQaModel()
                }
            )) {
                Text("Select a provider…").tag(UUID())
                ForEach(appStore.providers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            ModelPicker(
                appStore: appStore,
                provider: qaSelectedProvider,
                modelId: $qaModelId
            )
            .onChange(of: qaModelId) { _, _ in
                saveQaModel()
            }
            Text("Setting a model here doesn't turn QA on by itself — toggle it above. Workspaces can still opt out individually.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qaToggleCaption: String {
        // Spec-specified caption flips by current state.
        qaEnabled
            ? "Workspaces in this project start with QA review on. Each workspace can still opt out individually."
            : "Workspaces in this project start with QA review off. Each workspace can still opt in individually."
    }

    private var qaSelectedProvider: ProviderRecord? {
        qaProviderId.flatMap { id in
            appStore.providers.first(where: { $0.id == id })
        }
    }

    private func saveQaEnabled(_ value: Bool) {
        qaSaveState = .saving
        Task { @MainActor in
            do {
                try appStore.setProjectDefaultQaEnabled(projectId: project.id, enabled: value)
                qaSaveState = .saved
            } catch {
                qaSaveState = .error(String(describing: error))
            }
        }
    }

    private func saveQaModel() {
        qaSaveState = .saving
        Task { @MainActor in
            do {
                try appStore.setProjectDefaultQaModel(
                    projectId: project.id,
                    providerId: qaProviderId,
                    modelId: qaModelId
                )
                qaSaveState = .saved
            } catch {
                qaSaveState = .error(String(describing: error))
            }
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

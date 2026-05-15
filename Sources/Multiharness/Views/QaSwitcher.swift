import SwiftUI
import MultiharnessClient
import MultiharnessCore

/// Composer-header button that opens the QA popover. The label reflects
/// the workspace's effective QA state — see spec §8a.
///
/// State table:
///
/// | Effective state                          | Label                          |
/// |------------------------------------------|--------------------------------|
/// | Effectively off                          | `🔍 QA off ▾` (muted)          |
/// | On, no model resolvable                  | `🔍 QA: pick a model ▾`        |
/// | On, model resolved                       | `🔍 QA · <provider> · <model> ▾` |
/// | QA currently running                     | `🔍 QA running…` (disabled)    |
struct QaButton: View {
    let workspace: Workspace
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var store: AgentStore
    @Binding var qaLaunching: Bool

    @State private var popoverShown = false

    private var project: Project? {
        appStore.projects.first(where: { $0.id == workspace.projectId })
    }

    private var effectiveEnabled: Bool {
        guard let project else { return false }
        return workspace.effectiveQaEnabled(in: project)
    }

    private var initialSelection: (providerId: UUID?, modelId: String?) {
        guard let project else { return (nil, nil) }
        return workspace.qaPopoverInitialSelection(in: project)
    }

    private var isQaRunning: Bool {
        // The combination "isStreaming on a QA-tagged group" identifies a
        // live QA run. Also covers the small window between user clicking
        // Run QA and the sidecar's agent_start arrival (via qaLaunching).
        if qaLaunching { return true }
        return store.isStreaming && store.lastGroupKind == .qa
    }

    private var label: String {
        if isQaRunning { return "🔍 QA running…" }
        if !effectiveEnabled { return "🔍 QA off" }
        let (pid, mid) = initialSelection
        if let pid, let mid, !mid.isEmpty,
           let provider = appStore.providers.first(where: { $0.id == pid })
        {
            return "🔍 QA · \(provider.name) · \(mid)"
        }
        return "🔍 QA: pick a model"
    }

    private var labelColor: Color {
        effectiveEnabled ? .secondary : .secondary.opacity(0.6)
    }

    var body: some View {
        Button {
            popoverShown = true
        } label: {
            HStack(spacing: 6) {
                Text(label)
                if isQaRunning {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(labelColor)
        }
        .buttonStyle(.multiharness)
        .disabled(isQaRunning)
        .help(isQaRunning ? "QA review in progress…" : "Run QA review")
        .popover(isPresented: $popoverShown, arrowEdge: .top) {
            QaSwitcher(
                workspace: workspace,
                appStore: appStore,
                workspaceStore: workspaceStore,
                store: store,
                qaLaunching: $qaLaunching,
                isPresented: $popoverShown
            )
        }
    }
}

/// The popover. Three sections: a toggle row (workspace QA opt-in with
/// project-default inheritance shown), a provider+model picker, and
/// the Cancel/Save/Run QA action row. Spec §8a "The popover".
struct QaSwitcher: View {
    let workspace: Workspace
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var store: AgentStore
    @Binding var qaLaunching: Bool
    @Binding var isPresented: Bool

    @State private var enabled: Bool
    @State private var hasExplicitOverride: Bool
    @State private var selectedProviderId: UUID?
    @State private var selectedModelId: String
    @State private var autoApplyEnabled: Bool
    @State private var hasAutoApplyOverride: Bool
    @State private var applying = false
    @State private var applyError: String?

    init(
        workspace: Workspace,
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        store: AgentStore,
        qaLaunching: Binding<Bool>,
        isPresented: Binding<Bool>
    ) {
        self.workspace = workspace
        self.appStore = appStore
        self.workspaceStore = workspaceStore
        self.store = store
        self._qaLaunching = qaLaunching
        self._isPresented = isPresented

        let project = appStore.projects.first(where: { $0.id == workspace.projectId })
        let initialEnabled = project.map { workspace.effectiveQaEnabled(in: $0) } ?? false
        let overridden = project.map { workspace.qaEnabledIsOverridden(in: $0) } ?? (workspace.qaEnabled != nil)
        let initialSel: (providerId: UUID?, modelId: String?)
        if let project {
            initialSel = workspace.qaPopoverInitialSelection(in: project)
        } else {
            initialSel = (workspace.qaProviderId, workspace.qaModelId)
        }
        let initialAutoApply = project.map { workspace.effectiveQaAutoApply(in: $0) } ?? false
        self._enabled = State(initialValue: initialEnabled)
        self._hasExplicitOverride = State(initialValue: overridden)
        self._selectedProviderId = State(initialValue: initialSel.providerId)
        self._selectedModelId = State(initialValue: initialSel.modelId ?? "")
        self._autoApplyEnabled = State(initialValue: initialAutoApply)
        self._hasAutoApplyOverride = State(initialValue: workspace.qaAutoApply != nil)
    }

    private var project: Project? {
        appStore.projects.first(where: { $0.id == workspace.projectId })
    }

    private var selectedProvider: ProviderRecord? {
        selectedProviderId.flatMap { id in
            appStore.providers.first(where: { $0.id == id })
        }
    }

    private var projectDefaultLabel: String {
        guard let project else { return "Project default: off" }
        return "Project default: \(project.defaultQaEnabled ? "on" : "off")"
    }

    private var canResetToProjectDefault: Bool {
        hasExplicitOverride
    }

    /// True when the popover's current state differs from what's
    /// persisted on the workspace. Drives the Save button's enabled
    /// state. Resetting to project default counts as a change iff the
    /// workspace currently carries an explicit override.
    private var pendingChanges: Bool {
        // Enabled: compare the popover's intent (explicit if we have
        // an override, otherwise nil) to what's persisted.
        let intendedQaEnabled: Bool? = hasExplicitOverride ? enabled : nil
        if intendedQaEnabled != workspace.qaEnabled { return true }
        // Model: empty intent → nil
        let trimmedModel = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let intendedModel = trimmedModel.isEmpty ? nil : trimmedModel
        if selectedProviderId != workspace.qaProviderId { return true }
        if intendedModel != workspace.qaModelId { return true }
        let intendedAutoApply: Bool? = hasAutoApplyOverride ? autoApplyEnabled : nil
        if intendedAutoApply != workspace.qaAutoApply { return true }
        return false
    }

    private var runDisabled: Bool {
        if applying { return true }
        if !enabled { return true }
        if selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if selectedProvider == nil { return true }
        // Don't fire a QA run while another agent (primary or QA) is
        // already streaming on this workspace.
        if store.isStreaming { return true }
        if qaLaunching { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("QA review").font(.headline)

            // 1. Toggle row
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        // Any flip is by definition an explicit override.
                        hasExplicitOverride = true
                    }
                )) {
                    Text("QA review for this workspace")
                }
                .toggleStyle(.switch)
                HStack(spacing: 8) {
                    Text(projectDefaultLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if canResetToProjectDefault {
                        Button("Use project default") {
                            hasExplicitOverride = false
                            // Re-derive `enabled` from the project default
                            // so the toggle visibly snaps back.
                            if let project {
                                enabled = project.defaultQaEnabled
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            Divider()

            // 2. Provider + model pickers
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: Binding(
                    get: { selectedProviderId ?? UUID() },
                    set: { newId in
                        selectedProviderId = newId
                        // Clear model when the provider changes — model ids
                        // are provider-scoped.
                        selectedModelId = ""
                    }
                )) {
                    Text("Select a provider…").tag(UUID())
                    ForEach(appStore.providers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .disabled(applying)

                ModelPicker(
                    appStore: appStore,
                    provider: selectedProvider,
                    modelId: $selectedModelId
                )
            }

            Divider()

            // 3. Auto-apply blocking findings
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { autoApplyEnabled },
                    set: { newValue in
                        autoApplyEnabled = newValue
                        hasAutoApplyOverride = true
                    }
                )) {
                    Text("Auto-apply blocking QA findings")
                }
                .toggleStyle(.switch)
                .disabled(!enabled)
                HStack(spacing: 8) {
                    let projectAutoDefault = project?.defaultQaAutoApply ?? false
                    Text("Project default: \(projectAutoDefault ? "on" : "off")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasAutoApplyOverride {
                        Button("Use project default") {
                            hasAutoApplyOverride = false
                            autoApplyEnabled = projectAutoDefault
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                Text("When QA returns `blocking_issues`, the findings get fed back to the primary as a new prompt. Caps at 3 cycles per task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = applyError {
                Text(err)
                    .font(.caption).foregroundStyle(.red).lineLimit(4)
            }

            // 3. Action row
            HStack {
                Button("Cancel") { isPresented = false }
                    .disabled(applying)
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .disabled(applying || !pendingChanges)
                Button {
                    Task { await runQA() }
                } label: {
                    if applying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Text("Run QA")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(runDisabled)
                .help(runHelpText)
            }
        }
        .padding(16)
        .frame(width: 500, height: 640)
        .sheetEntry()
    }

    private var runHelpText: String {
        if !enabled { return "Turn QA on for this workspace first." }
        if selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a QA model."
        }
        if store.isStreaming {
            return "Wait for the current run to finish."
        }
        return "Save these settings and run a QA review now."
    }

    @MainActor
    private func save() async {
        applying = true
        applyError = nil
        defer { applying = false }
        persistCurrentState()
        isPresented = false
    }

    @MainActor
    private func runQA() async {
        applying = true
        applyError = nil
        defer { applying = false }
        persistCurrentState()
        guard let pid = selectedProviderId else { return }
        // Snapshot the latest workspace AFTER persistence so we hand the
        // refreshed Workspace into runQA.
        let refreshed = workspaceStore.workspaces.first(where: { $0.id == workspace.id })
            ?? workspace
        // Flip launching flag IMMEDIATELY so the parent composer's QA
        // button disables before the popover even closes — guarantees a
        // user who double-clicks Run QA can't fire two passes.
        qaLaunching = true
        do {
            try await appStore.runQA(
                workspace: refreshed,
                providerId: pid,
                modelId: selectedModelId,
                turns: store.turns
            )
            // Auto-flip lifecycle to in_review on a successful kick-off
            // (spec §8a step 5).
            if refreshed.lifecycleState == .inProgress {
                workspaceStore.setLifecycle(refreshed, .inReview)
            }
            isPresented = false
            // qaLaunching stays true until the QA agent_start (or an
            // agent_end / error) drains it — see Composer.onChange below.
        } catch {
            qaLaunching = false
            applyError = String(describing: error)
        }
    }

    private func persistCurrentState() {
        let trimmedModel = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String? = trimmedModel.isEmpty ? nil : trimmedModel
        let qaEnabled: Bool? = hasExplicitOverride ? enabled : nil
        let qaAutoApply: Bool? = hasAutoApplyOverride ? autoApplyEnabled : nil
        workspaceStore.setQa(
            workspace,
            enabled: qaEnabled,
            providerId: selectedProviderId,
            modelId: model,
            autoApply: qaAutoApply
        )
    }
}

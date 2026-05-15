import SwiftUI
import AppKit
import MultiharnessCore

@main
struct MultiharnessApp: App {
    @State private var env: AppEnvironment?
    @State private var appStore: AppStore?
    @State private var workspaceStore: WorkspaceStore?
    @State private var agentRegistry = AgentRegistryStore()
    @State private var relayHandler = RelayHandler()
    @State private var bootError: String?
    @State private var branchListService: BranchListService?

    var body: some Scene {
        WindowGroup("Multiharness") {
            Group {
                if let appStore, let workspaceStore, let env, let branchListService {
                    RootView(
                        env: env,
                        appStore: appStore,
                        workspaceStore: workspaceStore,
                        agentRegistry: agentRegistry,
                        branchListService: branchListService
                    )
                } else if let bootError {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Multiharness failed to start").font(.title2)
                        Text(bootError).font(.callout).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }.padding(32).frame(minWidth: 480, minHeight: 200)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting…").foregroundStyle(.secondary)
                    }.frame(minWidth: 480, minHeight: 320)
                }
            }
            .task { await boot() }
        }
        // `.contentSize` would pin the window to the content's preferred
        // size, which made the window snap to a too-small frame the first
        // time a workspace was selected (the HSplitView's columns then
        // got squeezed and the user had to resize manually). `.contentMinSize`
        // honors our `minWidth: 1100, minHeight: 700` but otherwise lets
        // AppKit remember the user's chosen frame and lets the user grow
        // the window beyond the content's ideal size.
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }

    @MainActor
    private func boot() async {
        do {
            let dataDir = PersistenceService.defaultDataDir()
            let env = try AppEnvironment(dataDir: dataDir)
            let app = AppStore(env: env)
            // Wire control-rebind BEFORE start() so the very first onPortBound
            // event (fired by start) drives the same path as later restarts.
            let relayHandler = self.relayHandler
            env.onControlChanged = { [weak app, weak agentRegistry] client in
                client.delegate = agentRegistry
                if let app {
                    app.sidecarBindingVersion += 1
                }
                if let agentRegistry {
                    for store in agentRegistry.stores.values {
                        store.bind(control: client)
                    }
                    agentRegistry.relayHandler = relayHandler
                }
                Task { await relayHandler.bind(client: client) }
                Task { await relayHandler.registerWithSidecar() }
                if let app {
                    Task {
                        await relayHandler.setActivityCallback { count in
                            Task { @MainActor in app.remoteActivityCount = count }
                        }
                    }
                }
                // Recreate sessions for every workspace so any client (Mac
                // UI, iOS companion) can prompt without first opening the
                // workspace in the Mac UI. Sidecar restarts blow away
                // in-memory sessions; this re-arms them.
                if let app {
                    Task { @MainActor in
                        let all = (try? app.persistenceWorkspaces()) ?? []
                        await app.bootstrapAllSessions(workspaces: all)
                    }
                }
            }

            _ = try await env.sidecar.start()
            // start() fires onPortBound which triggers onControlChanged above,
            // so env.control is set by the time we get here.

            app.load()
            BuiltinSeeds.ensureBuiltinProviders(app: app)

            let ws = WorkspaceStore(env: env)
            switch app.sidebarMode {
            case .singleProject:
                ws.load(projectId: app.selectedProjectId)
            case .allProjects:
                ws.loadAll()
            }

            self.env = env
            self.appStore = app
            self.workspaceStore = ws
            self.agentRegistry.bindEnvironment(env: env, appStore: app, workspaceStore: ws)
            // Wire up the Mac-side handlers iOS will reach via the relay.
            let branchListService = BranchListService()
            self.branchListService = branchListService
            await RemoteHandlers.register(
                on: relayHandler,
                env: env,
                appStore: app,
                workspaceStore: ws,
                branchListService: branchListService
            )
        } catch {
            self.bootError = String(describing: error)
        }
    }
}

@MainActor
@Observable
final class AgentRegistryStore: NSObject, ControlClientDelegate {
    var stores: [UUID: AgentStore] = [:]
    weak var env: AppEnvironment?
    weak var appStore: AppStore?
    weak var workspaceStore: WorkspaceStore?
    var relayHandler: RelayHandler?
    let completionSoundPlayer = CompletionSoundPlayer()

    func bindEnvironment(env: AppEnvironment, appStore: AppStore, workspaceStore: WorkspaceStore) {
        self.env = env
        self.appStore = appStore
        self.workspaceStore = workspaceStore
    }

    func ensureStore(workspaceId: UUID) -> AgentStore? {
        guard let env else { return nil }
        if let existing = stores[workspaceId] { return existing }
        let store = AgentStore(env: env, workspaceId: workspaceId)
        if let client = env.control { store.bind(control: client) }
        stores[workspaceId] = store
        return store
    }

    func maybePlayCompletionSound(for eventWorkspaceId: UUID) {
        let enabled = appStore?.playCompletionSound ?? true
        let appIsFrontmost = NSApp.isActive
        let selected = workspaceStore?.selectedWorkspaceId
        if CompletionSoundDecision.shouldPlay(
            enabled: enabled,
            appIsFrontmost: appIsFrontmost,
            selectedWorkspaceId: selected,
            eventWorkspaceId: eventWorkspaceId
        ) {
            completionSoundPlayer.play()
        }
    }

    nonisolated func controlClient(_ client: ControlClient, didReceiveEvent event: AgentEventEnvelope) {
        if event.type == "relay_request" {
            Task { @MainActor in
                if let h = self.relayHandler { await h.handle(event) }
            }
            return
        }
        if event.type == "anthropic_auth_url" {
            let urlString = event.payload["url"] as? String
            Task { @MainActor in
                if let urlString { self.appStore?.openAnthropicAuthURL(urlString) }
            }
            return
        }
        if event.type == "anthropic_console_auth_url" {
            let urlString = event.payload["url"] as? String
            Task { @MainActor in
                if let urlString { self.appStore?.openAnthropicAuthURL(urlString) }
            }
            return
        }
        if event.type == "openai_auth_url" {
            let urlString = event.payload["url"] as? String
            Task { @MainActor in
                if let urlString { self.appStore?.openOpenAIAuthURL(urlString) }
            }
            return
        }
        Task { @MainActor in
            guard let id = UUID(uuidString: event.workspaceId) else { return }
            self.stores[id]?.handleEvent(event)
            if event.type == "agent_end" {
                self.workspaceStore?.recordAssistantEnd(workspaceId: id)
                // Auto-mark the currently-selected workspace so the user never
                // sees a dot for the row they're actively looking at.
                if self.workspaceStore?.selectedWorkspaceId == id {
                    self.workspaceStore?.markViewed(id)
                }
                self.maybePlayCompletionSound(for: id)
                self.maybeAutoRunQa(workspaceId: id)
            }
            if event.type == "qa_findings" {
                self.maybeAutoApplyQaFindings(workspaceId: id, payload: event.payload)
            }
        }
    }

    /// Cap on auto-apply cycles per user task. Three was picked together
    /// with the user: enough to fix and re-validate, low enough that
    /// a misbehaving model can't burn unbounded tokens. Reset by
    /// `AgentStore.sendPrompt` whenever the user prompts manually.
    static let qaAutoApplyCycleCap = 3

    /// Auto-apply hook: when QA returns `blocking_issues` and the
    /// workspace has the auto-apply loop turned on, feed the findings
    /// back to the primary agent as a new prompt. Bounded by
    /// `qaAutoApplyCycleCap` cycles per user task. Surfaces a notice in
    /// the transcript when the cap is hit so the user knows the loop
    /// stopped rather than QA silently being ignored.
    @MainActor
    func maybeAutoApplyQaFindings(workspaceId: UUID, payload: [String: Any]) {
        guard let store = stores[workspaceId] else { return }
        guard let appStore else { return }
        guard let workspace = workspaceStore?.workspaces.first(where: { $0.id == workspaceId })
            ?? (try? appStore.persistenceWorkspaces().first(where: { $0.id == workspaceId }))
        else { return }
        guard let project = appStore.projects.first(where: { $0.id == workspace.projectId }) else { return }
        guard workspace.effectiveQaAutoApply(in: project) else { return }
        let verdictRaw = payload["verdict"] as? String ?? "info"
        guard let verdict = QaVerdict(rawValue: verdictRaw), verdict == .blockingIssues else { return }
        if store.qaAutoApplyCycles >= Self.qaAutoApplyCycleCap {
            // Surface a one-line note so the user understands the loop
            // halted by policy rather than silently giving up.
            store.turns.append(ConversationTurn(
                role: .assistant,
                text: "⚠️ Auto-QA loop reached its \(Self.qaAutoApplyCycleCap)-cycle cap; not feeding these findings back automatically. Review the QA card and prompt manually if you want another pass."
            ))
            return
        }
        let summary = payload["summary"] as? String ?? ""
        let findingsRaw = payload["findings"] as? [[String: Any]] ?? []
        let findings = findingsRaw.compactMap(QaFinding.init(json:))
        let cycleIndex = store.qaAutoApplyCycles + 1
        let prompt = QaAutoApplyPromptBuilder.build(
            verdict: verdict,
            summary: summary,
            findings: findings,
            cycleIndex: cycleIndex,
            cycleCap: Self.qaAutoApplyCycleCap
        )
        store.qaAutoApplyCycles = cycleIndex
        Task { @MainActor in
            await store.sendAutoApplyPrompt(prompt)
        }
    }

    /// Auto-QA hook: if the just-finished build turn ended with the
    /// QA-ready sentinel and the workspace has QA configured, fire a QA
    /// review automatically. The sentinel is stripped from the visible
    /// transcript before we kick off so the user never sees it.
    @MainActor
    func maybeAutoRunQa(workspaceId: UUID) {
        guard let store = stores[workspaceId] else { return }
        guard store.lastGroupKind != .qa else { return }
        guard let appStore else { return }
        guard let workspace = workspaceStore?.workspaces.first(where: { $0.id == workspaceId })
            ?? (try? appStore.persistenceWorkspaces().first(where: { $0.id == workspaceId }))
        else { return }
        guard let project = appStore.projects.first(where: { $0.id == workspace.projectId }) else { return }
        guard AppStore.qaSentinelEnabledForCreate(workspace: workspace, project: project) else { return }
        guard store.consumeQaReadySentinel() else { return }
        let (providerId, modelId) = workspace.qaPopoverInitialSelection(in: project)
        guard let providerId, let modelId, !modelId.isEmpty else { return }
        Task { @MainActor in
            do {
                try await appStore.runQA(
                    workspace: workspace,
                    providerId: providerId,
                    modelId: modelId,
                    turns: store.turns
                )
                if workspace.lifecycleState == .inProgress {
                    self.workspaceStore?.setLifecycle(workspace, .inReview)
                }
            } catch {
                appStore.lastError = "Auto-QA failed: \(error)"
            }
        }
    }

    nonisolated func controlClientDidConnect(_ client: ControlClient) {
        Task { @MainActor in
            for store in self.stores.values { store.connectionState = "connected" }
        }
    }

    nonisolated func controlClientDidDisconnect(_ client: ControlClient, error: Error?) {
        Task { @MainActor in
            for store in self.stores.values {
                store.connectionState = "disconnected"
                // Any in-flight turn is gone — clear the perpetual-spinner
                // state so the UI doesn't show "Streaming…" forever after
                // a sidecar crash mid-turn.
                store.cancelInFlight()
            }
        }
    }
}

enum BuiltinSeeds {
    @MainActor
    static func ensureBuiltinProviders(app: AppStore) {
        // Seed only if no providers exist yet.
        guard app.providers.isEmpty else { return }
        for preset in ProviderPreset.builtins where preset.noKeyRequired {
            app.addProvider(
                name: preset.displayName,
                kind: preset.kind,
                piProvider: preset.piProvider,
                baseUrl: preset.baseUrl,
                defaultModelId: nil,
                apiKey: nil
            )
        }
    }
}

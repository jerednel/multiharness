import SwiftUI
import MultiharnessCore

@main
struct MultiharnessApp: App {
    @State private var env: AppEnvironment?
    @State private var appStore: AppStore?
    @State private var workspaceStore: WorkspaceStore?
    @State private var agentRegistry = AgentRegistryStore()
    @State private var relayHandler = RelayHandler()
    @State private var bootError: String?

    var body: some Scene {
        WindowGroup("Multiharness") {
            Group {
                if let appStore, let workspaceStore, let env {
                    RootView(env: env, appStore: appStore, workspaceStore: workspaceStore, agentRegistry: agentRegistry)
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
        .windowResizability(.contentSize)
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
            self.agentRegistry.bindEnvironment(env: env, appStore: app)
            // Wire up the Mac-side handlers iOS will reach via the relay.
            await RemoteHandlers.register(
                on: relayHandler,
                env: env,
                appStore: app,
                workspaceStore: ws
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
    var relayHandler: RelayHandler?

    func bindEnvironment(env: AppEnvironment, appStore: AppStore) {
        self.env = env
        self.appStore = appStore
    }

    func ensureStore(workspaceId: UUID) -> AgentStore? {
        guard let env else { return nil }
        if let existing = stores[workspaceId] { return existing }
        let store = AgentStore(env: env, workspaceId: workspaceId)
        if let client = env.control { store.bind(control: client) }
        stores[workspaceId] = store
        return store
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

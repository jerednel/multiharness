import SwiftUI
import MultiharnessCore

@main
struct MultiharnessApp: App {
    @State private var env: AppEnvironment?
    @State private var appStore: AppStore?
    @State private var workspaceStore: WorkspaceStore?
    @State private var agentRegistry = AgentRegistryStore()
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
            env.onControlChanged = { [weak app, weak agentRegistry] client in
                client.delegate = agentRegistry
                if let app {
                    app.sidecarBindingVersion += 1
                }
                // Re-point each per-workspace store at the new client. Active
                // sidecar sessions don't survive a restart, so the next prompt
                // will trigger a fresh agent.create through ensureSession's
                // .task(id: bindingVersion) hook.
                if let agentRegistry {
                    for store in agentRegistry.stores.values {
                        store.bind(control: client)
                    }
                }
            }

            _ = try await env.sidecar.start()
            // start() fires onPortBound which triggers onControlChanged above,
            // so env.control is set by the time we get here.

            app.load()
            BuiltinSeeds.ensureBuiltinProviders(app: app)

            let ws = WorkspaceStore(env: env)
            ws.load(projectId: app.selectedProjectId)

            self.env = env
            self.appStore = app
            self.workspaceStore = ws
            self.agentRegistry.bindEnvironment(env: env, appStore: app)
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
            for store in self.stores.values { store.connectionState = "disconnected" }
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

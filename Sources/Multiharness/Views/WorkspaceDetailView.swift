import SwiftUI
import MultiharnessCore

struct WorkspaceDetailView: View {
    let workspace: Workspace
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore

    @State private var draftMessage: String = ""
    @State private var creatingSession = false
    @State private var sessionReady = false
    @State private var sessionError: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceBanner(workspace: workspace)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if let store = agentRegistry.ensureStore(workspaceId: workspace.id) {
                    ConversationView(store: store)
                    Divider()
                    Composer(
                        workspace: workspace,
                        store: store,
                        appStore: appStore,
                        sessionReady: sessionReady,
                        sessionError: sessionError
                    )
                    .padding(12)
                } else {
                    Spacer()
                    Text("Agent unavailable").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(minWidth: 480)

            Inspector(workspace: workspace, env: env)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 600)
        }
        .task(id: workspace.id) {
            await ensureSession()
        }
    }

    @MainActor
    private func ensureSession() async {
        sessionReady = false
        sessionError = nil
        guard let client = env.control else {
            sessionError = "control client not connected"
            return
        }
        guard let provider = appStore.providers.first(where: { $0.id == workspace.providerId }) else {
            sessionError = "provider not found"
            return
        }
        creatingSession = true
        defer { creatingSession = false }

        let providerCfg = appStore.providerConfig(provider: provider, modelId: workspace.modelId)
        let params: [String: Any] = [
            "workspaceId": workspace.id.uuidString,
            "worktreePath": workspace.worktreePath,
            "systemPrompt": "You are a helpful coding agent operating inside a git worktree. Use the available tools to read and modify files.",
            "providerConfig": providerCfg,
        ]
        do {
            _ = try await client.call(method: "agent.create", params: params)
            sessionReady = true
        } catch let e as ControlError {
            // "already exists" is a benign race when reopening a workspace.
            if case let .remote(_, msg) = e, msg.contains("already exists") {
                sessionReady = true
            } else {
                sessionError = e.description
            }
        } catch {
            sessionError = String(describing: error)
        }
    }
}

private struct WorkspaceBanner: View {
    let workspace: Workspace
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.title2).bold()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption)
                    Text(workspace.branchName).font(.callout).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text("from \(workspace.baseBranch)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            LifecycleBadge(state: workspace.lifecycleState)
        }
    }
}

private struct LifecycleBadge: View {
    let state: LifecycleState
    var body: some View {
        Text(state.label).font(.caption).bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color, in: Capsule())
    }
    private var color: Color {
        switch state {
        case .inProgress: return .blue
        case .inReview: return .orange
        case .done: return .green
        case .backlog: return .gray
        case .cancelled: return .secondary
        }
    }
}

private struct ConversationView: View {
    @Bindable var store: AgentStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.turns) { turn in
                        TurnCard(turn: turn).id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: store.turns.count) { _, _ in
                if let last = store.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct TurnCard: View {
    let turn: ConversationTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                roleIcon
                Text(roleLabel).font(.caption).bold().foregroundStyle(.secondary)
                if turn.streaming {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                }
                Spacer()
            }
            Text(turn.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }
    private var roleLabel: String {
        switch turn.role {
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool: \(turn.toolName ?? "?")"
        }
    }
    @ViewBuilder
    private var roleIcon: some View {
        switch turn.role {
        case .user: Image(systemName: "person.crop.circle").foregroundStyle(.blue)
        case .assistant: Image(systemName: "sparkles").foregroundStyle(.purple)
        case .tool: Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
        }
    }
    private var background: Color {
        switch turn.role {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color.purple.opacity(0.06)
        case .tool: return Color.orange.opacity(0.07)
        }
    }
}

private struct Composer: View {
    let workspace: Workspace
    @Bindable var store: AgentStore
    @Bindable var appStore: AppStore
    let sessionReady: Bool
    let sessionError: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = sessionError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
                Text(modelLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isStreaming {
                    Text("Streaming…").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
                    .onSubmit {
                        Task { await send() }
                    }
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !sessionReady
                          || store.isStreaming)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var modelLabel: String {
        let providerName = appStore.providers.first(where: { $0.id == workspace.providerId })?.name ?? "?"
        return "\(providerName) · \(workspace.modelId)"
    }

    @MainActor
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await store.sendPrompt(text)
    }
}

private struct Inspector: View {
    let workspace: Workspace
    let env: AppEnvironment
    @State private var status: WorktreeStatus?
    @State private var statusError: String?
    @State private var fileText: String = ""
    @State private var selectedFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if let err = statusError {
                Text(err).font(.caption).foregroundStyle(.red).padding(12)
            }
            if let s = status {
                List(selection: $selectedFile) {
                    if !s.modifiedFiles.isEmpty {
                        Section("Changed") {
                            ForEach(s.modifiedFiles, id: \.self) { f in
                                Text(f).tag(Optional(f))
                            }
                        }
                    }
                    if !s.untrackedFiles.isEmpty {
                        Section("Untracked") {
                            ForEach(s.untrackedFiles, id: \.self) { f in
                                Text(f).tag(Optional(f))
                            }
                        }
                    }
                    if s.modifiedFiles.isEmpty && s.untrackedFiles.isEmpty {
                        Section { Text("No changes vs \(workspace.baseBranch)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 200)
                Divider()
                ScrollView {
                    Text(fileText).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .textSelection(.enabled)
                }
            } else {
                Spacer()
                ProgressView().padding()
                Spacer()
            }
        }
        .task(id: workspace.id) { await refresh() }
        .onChange(of: selectedFile) { _, _ in
            Task { await loadFile() }
        }
    }

    @MainActor
    private func refresh() async {
        statusError = nil
        do {
            self.status = try env.worktree.status(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch
            )
        } catch {
            statusError = String(describing: error)
        }
    }

    @MainActor
    private func loadFile() async {
        guard let f = selectedFile else { fileText = ""; return }
        let path = (workspace.worktreePath as NSString).appendingPathComponent(f)
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            fileText = data.count > 100_000 ? "(file too large to preview)" : data
        } else {
            fileText = "(unable to read \(path))"
        }
    }
}

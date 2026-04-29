import SwiftUI
import AppKit
import MultiharnessClient
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
                if case let .crashed(reason) = appStore.sidecarStatus {
                    SidecarCrashBanner(reason: reason)
                }
                Divider()
                if let store = agentRegistry.ensureStore(workspaceId: workspace.id) {
                    ConversationView(store: store, workspaceId: workspace.id)
                    Divider()
                    Composer(
                        workspace: workspace,
                        store: store,
                        appStore: appStore,
                        sessionReady: sessionReady && isSidecarHealthy,
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
        // Re-create the sidecar session whenever the sidecar (re)binds —
        // a fresh sidecar process means our previous AgentSession is gone.
        .task(id: appStore.sidecarBindingVersion) {
            await ensureSession()
        }
    }

    private var isSidecarHealthy: Bool {
        if case .running = appStore.sidecarStatus { return true }
        return false
    }

    @MainActor
    private func ensureSession() async {
        sessionReady = false
        sessionError = nil
        creatingSession = true
        defer { creatingSession = false }
        do {
            try await appStore.createAgentSession(for: workspace)
            sessionReady = true
        } catch let e as ControlError {
            // "already exists" is handled inside the helper, but be defensive.
            if case let .remote(_, msg) = e, msg.contains("already exists") {
                sessionReady = true
            } else {
                sessionError = e.description
            }
        } catch let e as AgentSessionError {
            sessionError = e.description
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
    let workspaceId: UUID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.turns) { turn in
                        TurnCard(turn: turn).id(turn.id)
                    }
                    if store.isStreaming {
                        ThinkingCard().id(thinkingCardId)
                    }
                }
                .padding(16)
            }
            .onChange(of: store.turns.count) { _, _ in
                if let last = store.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.isStreaming) { _, streaming in
                if streaming {
                    withAnimation { proxy.scrollTo(thinkingCardId, anchor: .bottom) }
                }
            }
            .onChange(of: workspaceId, initial: true) { _, _ in
                if let last = store.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else if store.isStreaming {
                    proxy.scrollTo(thinkingCardId, anchor: .bottom)
                }
            }
        }
    }

    private let thinkingCardId = "thinking-card"
}

private struct SidecarCrashBanner: View {
    let reason: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sidecar crashed").font(.callout).bold().foregroundStyle(.white)
                Text("\(reason). Auto-restarting…").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            ProgressView().controlSize(.small).tint(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red)
    }
}

private struct ThinkingCard: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Agent").font(.caption).bold().foregroundStyle(.secondary)
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TurnCard: View {
    let turn: ConversationTurn
    @State private var expanded = false

    var body: some View {
        if turn.role == .tool {
            toolCard
        } else {
            messageCard
        }
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange).font(.caption)
                    Text(turn.toolName ?? "tool").font(.caption).bold()
                    Text("·").foregroundStyle(.secondary)
                    Text(collapsedSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if turn.streaming {
                        ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(turn.text.isEmpty ? "(no output)" : turn.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                roleIcon
                Text(roleLabel).font(.caption).bold().foregroundStyle(.secondary)
                if turn.streaming {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                }
                Spacer()
            }
            Group {
                if turn.role == .assistant {
                    MarkdownMessageText(turn.text)
                } else {
                    Text(turn.text)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(messageBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var collapsedSummary: String {
        // Show the first non-empty line as a one-liner.
        let firstLine = turn.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        if firstLine.isEmpty { return turn.streaming ? "running…" : "done" }
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
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

    private var messageBackground: Color {
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
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            // The system's default for Shift+Return on a vertical
                            // TextField is "extend selection" rather than insert a
                            // newline — so we insert one ourselves at the end of
                            // the draft.
                            draft.append("\n")
                            return .handled
                        }
                        Task { await send() }
                        return .handled                        // Enter → send
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

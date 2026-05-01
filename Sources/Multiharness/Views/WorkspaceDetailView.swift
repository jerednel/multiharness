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
    let branchListService: BranchListService

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
                        workspaceStore: workspaceStore,
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

            Inspector(
                workspace: workspace,
                env: env,
                appStore: appStore,
                workspaceStore: workspaceStore,
                branchListService: branchListService
            )
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
                    ForEach(groupConversationTurns(store.turns), id: \.id) { row in
                        switch row {
                        case .single(let turn):
                            TurnCard(turn: turn).id(turn.id)
                        case .group(let id, let children):
                            ResponseGroupView(groupId: id, children: children)
                                .id(id)
                        }
                    }
                    if store.isStreaming && !hasActiveGroup {
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

    /// True iff there's an in-progress group already at the bottom — in
    /// that case the group's own header carries the streaming indicator,
    /// so we suppress the standalone ThinkingCard.
    private var hasActiveGroup: Bool {
        guard let last = store.turns.last, last.groupId != nil else { return false }
        return store.isStreaming
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

/// Collapsible container for one agent_start..agent_end response. While
/// any child is streaming, expands automatically; once the run finishes,
/// auto-collapses to a one-line summary the user can re-open. The final
/// assistant message renders outside the collapse so post-collapse it
/// still reads like a normal reply.
private struct ResponseGroupView: View {
    let groupId: String
    let children: [ConversationTurn]

    @State private var manuallyToggled = false
    @State private var manualExpanded = false

    private var isStreaming: Bool {
        children.contains(where: { $0.streaming })
    }

    private var expanded: Bool {
        manuallyToggled ? manualExpanded : isStreaming
    }

    /// Index of the assistant turn we lift OUT of the collapse so the
    /// final reply remains readable when collapsed. Picks the last
    /// non-empty assistant turn in the group; nil if there isn't one yet.
    private var liftedFinalIndex: Int? {
        children.indices.reversed().first(where: {
            children[$0].role == .assistant && !children[$0].text.isEmpty
        })
    }

    private var collapsedChildren: [ConversationTurn] {
        guard let lifted = liftedFinalIndex else { return children }
        var copy = children
        copy.remove(at: lifted)
        return copy
    }

    private var liftedFinal: ConversationTurn? {
        liftedFinalIndex.map { children[$0] }
    }

    private var summary: String {
        let toolCount = children.filter { $0.role == .tool }.count
        let messageCount = children.filter {
            $0.role == .assistant && !$0.text.isEmpty
        }.count
        var parts: [String] = []
        if toolCount > 0 {
            parts.append("\(toolCount) tool call\(toolCount == 1 ? "" : "s")")
        }
        if messageCount > 0 {
            parts.append("\(messageCount) message\(messageCount == 1 ? "" : "s")")
        }
        if parts.isEmpty { return isStreaming ? "thinking…" : "no output" }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.disclosure) {
                    manuallyToggled = true
                    manualExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    if isStreaming {
                        ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.multiharness)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(collapsedChildren) { turn in
                        TurnCard(turn: turn).id(turn.id)
                    }
                }
                .transition(.disclosureContent)
            }

            if let final = liftedFinal {
                TurnCard(turn: final).id(final.id)
            }
        }
        // When a streaming run completes, snap back to "follow streaming"
        // mode so the next run auto-expands then auto-collapses again.
        .onChange(of: isStreaming) { _, nowStreaming in
            if nowStreaming { manuallyToggled = false }
        }
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
                withAnimation(Motion.disclosure) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange).font(.caption)
                    Text(turn.toolStepLabel).font(.caption).bold()
                    if let raw = turn.toolName,
                       turn.toolCallDescription?.isEmpty == false {
                        Text(raw)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    if turn.streaming {
                        ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.multiharness)
            if expanded {
                Text(turn.text.isEmpty ? "(no output)" : turn.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                    .transition(.disclosureContent)
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

    private var roleLabel: String {
        switch turn.role {
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool: \(turn.toolStepLabel)"
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
    @Bindable var workspaceStore: WorkspaceStore
    let sessionReady: Bool
    let sessionError: String?
    @State private var draft = ""
    @State private var switcherShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = sessionError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button {
                    switcherShown = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle")
                        Text(modelLabel)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.multiharness)
                .disabled(store.isStreaming)
                .popover(isPresented: $switcherShown, arrowEdge: .top) {
                    ModelSwitcher(
                        appStore: appStore,
                        workspaceStore: workspaceStore,
                        workspace: workspace,
                        isPresented: $switcherShown
                    )
                }
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
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let branchListService: BranchListService

    private enum InspectorTab: Hashable { case files, context }
    @State private var inspectorTab: InspectorTab = .files
    @Namespace private var inspectorTabNamespace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(label: "Files", icon: "doc.text", value: .files)
                tabButton(label: "Context", icon: "text.alignleft", value: .context)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            Divider()
            Group {
                switch inspectorTab {
                case .files:
                    FilesTab(workspace: workspace, env: env)
                case .context:
                    ContextTab(
                        workspace: workspace,
                        appStore: appStore,
                        workspaceStore: workspaceStore,
                        branchListService: branchListService
                    )
                }
            }
            .id(inspectorTab)
            .transition(.tabSwap)
        }
    }

    @ViewBuilder
    private func tabButton(label: String, icon: String, value: InspectorTab) -> some View {
        Button {
            withAnimation(Motion.standard) { inspectorTab = value }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background {
                if inspectorTab == value {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "inspector-pill", in: inspectorTabNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.multiharness)
    }
}

private struct FilesTab: View {
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
                .buttonStyle(.multiharnessIcon)
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

private struct ModelSwitcher: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let workspace: Workspace
    @Binding var isPresented: Bool

    @State private var selectedProviderId: UUID
    @State private var selectedModelId: String
    @State private var applying = false
    @State private var applyError: String?

    init(
        appStore: AppStore,
        workspaceStore: WorkspaceStore,
        workspace: Workspace,
        isPresented: Binding<Bool>
    ) {
        self.appStore = appStore
        self.workspaceStore = workspaceStore
        self.workspace = workspace
        self._isPresented = isPresented
        self._selectedProviderId = State(initialValue: workspace.providerId)
        self._selectedModelId = State(initialValue: workspace.modelId)
    }

    private var selectedProvider: ProviderRecord? {
        appStore.providers.first(where: { $0.id == selectedProviderId })
    }

    private var changed: Bool {
        selectedProviderId != workspace.providerId || selectedModelId != workspace.modelId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch model").font(.headline)
            Picker("Provider", selection: $selectedProviderId) {
                ForEach(appStore.providers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: selectedProviderId) { _, newId in
                if newId != workspace.providerId {
                    selectedModelId = ""
                } else {
                    selectedModelId = workspace.modelId
                }
            }
            ModelPicker(
                appStore: appStore,
                provider: selectedProvider,
                modelId: $selectedModelId
            )
            if let err = applyError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .disabled(applying)
                Button {
                    Task { await apply() }
                } label: {
                    if applying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Applying…")
                        }
                    } else {
                        Text("Apply")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applying || !changed || selectedModelId.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: 460)
        .sheetEntry()
    }

    @MainActor
    private func apply() async {
        applying = true
        applyError = nil
        defer { applying = false }
        do {
            try await appStore.changeWorkspaceProviderAndModel(
                workspaceStore: workspaceStore,
                workspace: workspace,
                providerId: selectedProviderId,
                modelId: selectedModelId
            )
            isPresented = false
        } catch {
            applyError = String(describing: error)
        }
    }
}

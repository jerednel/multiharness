import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultiharnessClient
import MultiharnessCore

struct WorkspaceDetailView: View {
    let workspace: Workspace
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let agentRegistry: AgentRegistryStore
    let terminalRegistry: TerminalRegistryStore
    let branchListService: BranchListService

    @State private var draftMessage: String = ""
    @State private var creatingSession = false
    @State private var sessionReady = false
    @State private var sessionError: String?
    @State private var showingOneClickPR = false
    @State private var terminalVisible: Bool = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceBanner(
                    workspace: workspace,
                    onOpenPR: { showingOneClickPR = true }
                )
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
                    // Force a fresh Composer identity per workspace so
                    // @State (draft text, pending images, attach errors)
                    // resets when the user switches workspaces instead
                    // of carrying over from the previous one.
                    .id(workspace.id)
                    .padding(12)
                } else {
                    Spacer()
                    Text("Agent unavailable").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Floating terminal overlay — pops on top of the conversation
            // column when Ctrl+` is pressed. Inspector (the second
            // HSplitView child) stays untouched. The keyboard monitor
            // sits as a background NSView so it can swallow Ctrl+`
            // before SwiftTerm sees it, even while the terminal has
            // key focus.
            .overlay { terminalOverlayLayer }
            .background(TerminalKeyboardMonitor(isVisible: $terminalVisible))
            .animation(.spring(duration: 0.25), value: terminalVisible)
            // HSplitView needs an `idealWidth` on each child to decide
            // how to apportion space — without it the conversation column
            // could end up at its `minWidth` while the inspector takes
            // its ideal, leaving the rest of the detail area visually
            // broken until the user dragged the divider. The conversation
            // is the primary surface, so it gets the larger ideal and
            // unbounded max; the inspector grows with the window up to
            // a generous cap.
            .frame(minWidth: 480, idealWidth: 720, maxWidth: .infinity)

            Inspector(
                workspace: workspace,
                env: env,
                appStore: appStore,
                workspaceStore: workspaceStore,
                branchListService: branchListService
            )
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 640)
        }
        .task(id: workspace.id) {
            await ensureSession()
        }
        // Re-create the sidecar session whenever the sidecar (re)binds —
        // a fresh sidecar process means our previous AgentSession is gone.
        .task(id: appStore.sidecarBindingVersion) {
            await ensureSession()
        }
        .sheet(isPresented: $showingOneClickPR) {
            OneClickPRSheet(
                workspace: workspace,
                isPresented: $showingOneClickPR
            )
        }
    }

    @ViewBuilder
    private var terminalOverlayLayer: some View {
        if terminalVisible {
            TerminalOverlay(
                workspace: workspace,
                registry: terminalRegistry,
                isVisible: $terminalVisible
            )
            .padding(EdgeInsets(top: 50, leading: 40, bottom: 50, trailing: 40))
            .transition(
                AnyTransition.move(edge: .bottom).combined(with: AnyTransition.opacity)
            )
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
    var onOpenPR: () -> Void = {}
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
            // 1-click PR: stages anything dirty, commits, pushes,
            // opens a PR via `gh` against `workspace.baseBranch`.
            Button {
                onOpenPR()
            } label: {
                Label("Open PR", systemImage: "arrow.up.right.square")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .help("Commit any pending changes, push, and open a GitHub PR against \(workspace.baseBranch)")
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

    /// Whether the user has manually scrolled away from the bottom.
    /// When true we stop auto-scrolling until a new agent run resets it.
    @State private var userScrolledAway = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack (not LazyVStack). A conversation has tens to low
                // hundreds of turns — well within VStack's budget. Lazy
                // rendering caused views outside the viewport to never
                // materialize, producing blank/black regions when the
                // window lost focus or the user wasn't looking at the
                // conversation pane. Eager rendering ensures every turn
                // is painted regardless of viewport state.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupConversationTurns(store.turns), id: \.id) { row in
                        switch row {
                        case .single(let turn):
                            TurnCard(turn: turn).id(turn.id)
                        case .group(let id, let children):
                            ResponseGroupView(
                                groupId: id,
                                children: children,
                                kind: store.groupKind(for: id)
                            )
                                .id(id)
                        }
                    }
                    if store.isStreaming && !hasActiveGroup {
                        ThinkingCard().id("thinking-sentinel")
                    }
                    // Invisible anchor always at the very bottom. Scrolling
                    // to this keeps the latest content visible even when
                    // the last real view changes height (streaming text).
                    Color.clear
                        .frame(height: 1)
                        .id("scroll-bottom-anchor")
                }
                .padding(16)
            }
            // Anchors the initial layout to the bottom so the user lands
            // at the most recent message when opening a workspace (or
            // after history rehydration).
            .defaultScrollAnchor(.bottom)
            // Auto-scroll: follow new turns and streaming content.
            .onChange(of: store.turns.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: store.isStreaming) { _, streaming in
                if streaming {
                    // New agent run — reset the scroll-away latch so we
                    // follow the response from the start.
                    userScrolledAway = false
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: streamingTextLength) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
        // Force a fresh ScrollView per workspace so the bottom anchor
        // re-applies to the new content instead of inheriting the prior
        // workspace's scroll position.
        .id(workspaceId)
    }

    /// Approximate length of the text in the last turn while it's
    /// streaming. Sampled coarsely (every 80 chars) to drive
    /// auto-scroll without firing on literally every delta.
    private var streamingTextLength: Int {
        guard store.isStreaming,
              let last = store.turns.last,
              last.streaming
        else { return 0 }
        // Quantize to ~80-char buckets so we don't scroll on every
        // single character, but still keep up with fast-arriving text.
        return last.text.count / 80
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard !userScrolledAway else { return }
        // withAnimation keeps the jump smooth; .easeOut is snappy enough
        // to not feel laggy during fast streaming.
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
        }
    }

    /// True iff there's an in-progress group already at the bottom — in
    /// that case the group's own header carries the streaming indicator,
    /// so we suppress the standalone ThinkingCard.
    private var hasActiveGroup: Bool {
        guard let last = store.turns.last, last.groupId != nil else { return false }
        return store.isStreaming
    }
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
    var kind: GroupKind = .build

    @State private var manuallyToggled = false
    @State private var manualExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStreaming: Bool {
        children.contains(where: { $0.streaming })
    }

    private var expanded: Bool {
        manuallyToggled ? manualExpanded : isStreaming
    }

    /// Index of the assistant turn we lift OUT of the collapse so the
    /// final reply remains readable when collapsed. Picks the last
    /// non-empty assistant turn in the group; for QA groups the
    /// findings card wins if present (it IS the conclusion). Nil if
    /// neither is found yet.
    private var liftedFinalIndex: Int? {
        if let qaIdx = children.indices.reversed().first(where: {
            children[$0].role == .qaFindings
        }) {
            return qaIdx
        }
        return children.indices.reversed().first(where: {
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
        let findingsCount = children.filter { $0.role == .qaFindings }.count
        var parts: [String] = []
        if toolCount > 0 {
            parts.append("\(toolCount) tool call\(toolCount == 1 ? "" : "s")")
        }
        if messageCount > 0 {
            parts.append("\(messageCount) message\(messageCount == 1 ? "" : "s")")
        }
        if findingsCount > 0 {
            parts.append("\(findingsCount) finding card\(findingsCount == 1 ? "" : "s")")
        }
        if parts.isEmpty { return isStreaming ? "thinking…" : "no output" }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.disclosure.adaptive(reduceMotion)) {
                    manuallyToggled = true
                    manualExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: headerIcon).font(.caption).foregroundStyle(headerColor)
                    if kind == .qa {
                        Text("QA review").font(.caption).bold().foregroundStyle(headerColor)
                        Text("·").font(.caption).foregroundStyle(.secondary)
                    }
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

    private var headerIcon: String {
        kind == .qa ? "magnifyingglass" : "sparkles"
    }

    private var headerColor: Color {
        kind == .qa ? .cyan : .purple
    }
}

private struct TurnCard: View {
    let turn: ConversationTurn
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch turn.role {
        case .tool:
            toolCard
        case .qaFindings:
            QaFindingsCard(turn: turn)
        case .compaction:
            CompactionMarker(info: turn.compaction)
        case .user, .assistant:
            messageCard
        }
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.disclosure.adaptive(reduceMotion)) { expanded.toggle() }
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
            VStack(alignment: .leading, spacing: 8) {
                if !turn.images.isEmpty {
                    // Wrapping row of fixed-height thumbnails. Click-to-open
                    // is QuickLook-style (Space key in the future); for now
                    // the user can right-click → Save to retrieve the
                    // original bytes.
                    AttachmentThumbStrip(images: turn.images)
                }
                if !turn.text.isEmpty {
                    if turn.role == .assistant {
                        // While the turn is actively streaming, render as
                        // plain Text to avoid re-parsing the entire
                        // markdown tree on every text_delta (MarkdownUI
                        // re-parses from scratch each time the string
                        // changes). Once streaming finishes, switch to
                        // full MarkdownMessageText for rich rendering.
                        // This eliminates the main-thread stalls that
                        // caused the UI to freeze / go black on long
                        // responses.
                        if turn.streaming {
                            Text(turn.text)
                                .textSelection(.enabled)
                        } else {
                            MarkdownMessageText(turn.text)
                        }
                    } else {
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
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
        // Unreachable — qaFindings turns route through QaFindingsCard
        // before this view is consulted. Default included for
        // exhaustiveness, not for actual rendering.
        case .qaFindings: return "QA review"
        // Unreachable — compaction turns route through CompactionMarker.
        case .compaction: return "Context"
        }
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch turn.role {
        case .user: Image(systemName: "person.crop.circle").foregroundStyle(.blue)
        case .assistant: Image(systemName: "sparkles").foregroundStyle(.purple)
        case .tool: Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
        case .qaFindings: Image(systemName: "magnifyingglass").foregroundStyle(.cyan)
        case .compaction: Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(.secondary)
        }
    }

    private var messageBackground: Color {
        switch turn.role {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color.purple.opacity(0.06)
        case .tool: return Color.orange.opacity(0.07)
        case .qaFindings: return Color.cyan.opacity(0.06)
        case .compaction: return Color.secondary.opacity(0.05)
        }
    }
}

/// In-band marker rendered for `.compaction` turns. Shows the headline
/// inline; hovering reveals the breakdown of what changed. Designed to
/// take minimal vertical space — this is a context-management diagnostic,
/// not a primary surface.
private struct CompactionMarker: View {
    let info: CompactionInfo?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info {
                    Text(info.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Defensive: a context_compacted event arrived but
                    // we couldn't decode its fields. Still render the
                    // marker so the user knows compaction happened.
                    Text("Context compacted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(hovered ? 0.12 : 0.06))
            )
            .help(info?.detail ?? "")
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovered = $0 }
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
    /// Image attachments staged for the next send. Cleared after a
    /// successful send; the user can also remove individual entries with
    /// the X button on each thumbnail. Drop targets + paste both append
    /// here.
    @State private var pendingImages: [TurnImage] = []
    @State private var attachError: String?
    /// True from the moment the user clicks "Run QA" in the popover
    /// until the sidecar's `agent_start` (or an error) reaches us.
    /// Closes the small race where a double-click would fire two
    /// `qa.run` calls before the AgentStore's isStreaming flag flips.
    /// See spec §12.
    @State private var qaLaunching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = sessionError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let err = attachError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
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

                QaButton(
                    workspace: workspace,
                    appStore: appStore,
                    workspaceStore: workspaceStore,
                    store: store,
                    qaLaunching: $qaLaunching
                )

                Spacer()
                if store.isStreaming {
                    // Combined "what's running" + "stop it" affordance.
                    // The label carries the QA/build distinction that
                    // used to live in a standalone `streamingLabel`
                    // Text view; folding it into the Stop button keeps
                    // the row compact and lets the user abort either
                    // kind of run.
                    Button {
                        Task { await store.stopCurrentTurn() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text(stopButtonLabel)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.multiharness)
                    .help("Abort the in-flight turn")
                }
            }
            if !store.pendingMessages.isEmpty {
                PendingMessagesStrip(store: store)
            }
            if !pendingImages.isEmpty {
                ComposerAttachmentStrip(images: $pendingImages)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Manual attach (file picker) — paste/drop are the primary
                // entrypoints but a button is handy when the user wants to
                // browse to a screenshot in Finder.
                Button {
                    pickImages()
                } label: {
                    Image(systemName: "paperclip")
                        .padding(.horizontal, 8).padding(.vertical, 8)
                }
                .buttonStyle(.multiharness)
                .help("Attach images or text files (CSV, JSON, etc.)")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
                    // Cmd-V image paste. SwiftUI's `.onPasteCommand`
                    // doesn't fire when a TextField has focus (the field
                    // editor consumes the paste action and rejects
                    // non-text bytes with the system bell), so we
                    // install an NSEvent local monitor that runs *before*
                    // the field editor sees the keystroke. If the
                    // pasteboard has an image, we consume it and
                    // attach; otherwise we pass the event through and
                    // the field editor handles normal text paste.
                    .background(
                        CmdVImagePasteMonitor { nsImages in
                            let imgs = ComposerPaste.encode(nsImages: nsImages)
                            guard !imgs.isEmpty else { return false }
                            pendingImages.append(contentsOf: imgs)
                            attachError = nil
                            return true
                        }
                    )
                    .onDrop(of: ComposerPaste.acceptedTypes, isTargeted: nil) { providers in
                        ComposerPaste.absorb(providers: providers) { result in
                            Task { @MainActor in
                                applyAttachResult(result)
                            }
                        }
                        // Also check for file URLs pointing at text files
                        // (CSV, JSON, etc.) and inline their contents.
                        ComposerPaste.absorbTextFiles(providers: providers) { blocks in
                            Task { @MainActor in
                                if !blocks.isEmpty {
                                    let joined = blocks.joined(separator: "\n\n")
                                    if draft.isEmpty {
                                        draft = joined
                                    } else {
                                        draft += "\n\n" + joined
                                    }
                                }
                            }
                        }
                        return true
                    }
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            // The system's default for Shift+Return on a vertical
                            // TextField is "extend selection" rather than insert a
                            // newline — so we insert one ourselves. Reach into the
                            // focused field editor (NSTextView) and insert at the
                            // current selection so the newline lands at the cursor
                            // instead of being appended to the end of the draft.
                            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                                tv.insertText("\n", replacementRange: tv.selectedRange())
                            } else {
                                draft.append("\n")
                            }
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
                .disabled(sendDisabled)
                .buttonStyle(.borderedProminent)
            }
        }
        // Drain qaLaunching once the sidecar's agent_start (with kind:qa)
        // has been observed — at that point store.isStreaming + the QA
        // group kind take over as the "QA running" signal, and the
        // launching flag has done its job (covering the race window).
        .onChange(of: store.isStreaming) { _, nowStreaming in
            if nowStreaming && store.lastGroupKind == .qa {
                qaLaunching = false
            }
            // Also drain if a run finished without us seeing the flag
            // turn on (e.g. immediate error — agent_end without
            // agent_start): when isStreaming flips back to false, any
            // stale launching flag should be cleared so the button
            // re-enables.
            if !nowStreaming {
                qaLaunching = false
            }
        }
    }

    private var sendDisabled: Bool {
        let textEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Allow image-only sends: when at least one image is staged, the
        // empty-text guard relaxes.
        if textEmpty && pendingImages.isEmpty { return true }
        if !sessionReady { return true }
        // Note: `store.isStreaming` no longer disables sending. Composing
        // while a turn is in flight enqueues onto `store.pendingMessages`;
        // the queue drains one-at-a-time on `agent_end`.
        return false
    }

    private var modelLabel: String {
        let providerName = appStore.providers.first(where: { $0.id == workspace.providerId })?.name ?? "?"
        return "\(providerName) · \(workspace.modelId)"
    }

    /// Distinguishes a primary streaming turn from a QA review in the
    /// Stop button's label. Both flip `store.isStreaming`; we read
    /// `lastGroupKind` to pick the right wording so the user always
    /// knows which run they're aborting.
    private var stopButtonLabel: String {
        store.lastGroupKind == .qa ? "Stop QA" : "Stop"
    }

    @MainActor
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty else { return }
        draft = ""
        pendingImages = []
        await store.sendPrompt(text, images: images)
    }

    @MainActor
    private func applyAttachResult(_ result: ComposerPaste.Result) {
        if !result.images.isEmpty {
            pendingImages.append(contentsOf: result.images)
            attachError = nil
        }
        if let err = result.error {
            attachError = err
        }
    }

    @MainActor
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Accept images (for inline image attachments) AND common
        // text-based data files (CSV, JSON, TXT, etc.) whose contents
        // are inlined into the draft as a fenced code block.
        panel.allowedContentTypes = [
            .image,
            .commaSeparatedText,   // .csv
            .json,
            .plainText,
            .xml,
            .yaml,
            .sourceCode,
            .tabSeparatedText,     // .tsv
        ]
        guard panel.runModal() == .OK else { return }
        var addedImages: [TurnImage] = []
        var inlinedText: [String] = []
        var lastErr: String?
        for url in panel.urls {
            if ComposerPaste.isTextFile(url) {
                switch ComposerPaste.loadTextFile(at: url) {
                case .success(let block): inlinedText.append(block)
                case .failure(let e): lastErr = e.message
                }
            } else {
                switch ComposerPaste.loadImage(at: url) {
                case .success(let img): addedImages.append(img)
                case .failure(let e): lastErr = e.message
                }
            }
        }
        if !addedImages.isEmpty {
            pendingImages.append(contentsOf: addedImages)
            attachError = nil
        }
        if !inlinedText.isEmpty {
            let joined = inlinedText.joined(separator: "\n\n")
            if draft.isEmpty {
                draft = joined
            } else {
                draft += "\n\n" + joined
            }
            attachError = nil
        }
        if let lastErr { attachError = lastErr }
    }
}

/// Compact list of user messages that were composed while a turn was in
/// flight. Each row shows a one-line snippet plus an X to cancel that
/// individual message. The queue drains one entry per `agent_end` event,
/// so this view typically shrinks from the top.
private struct PendingMessagesStrip: View {
    @Bindable var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.pendingMessages) { msg in
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snippet(for: msg))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button {
                        store.cancelPendingMessage(id: msg.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel queued message")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
    }

    /// Pick a stable one-line preview: prefer the text, fall back to an
    /// image-only marker so image-only queued sends still render
    /// something meaningful.
    private func snippet(for msg: PendingMessage) -> String {
        let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let n = msg.images.count
        return n == 1 ? "(1 image)" : "(\(n) images)"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(label: "Files", icon: "doc.text", value: .files)
                tabButton(label: "Context", icon: "text.alignleft", value: .context)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            Divider()
            // True overlap-crossfade rather than fade-out-then-in: both tabs
            // stay in the hierarchy while opacity animates between them.
            TabCrossfade(selection: inspectorTab, first: .files) {
                FilesTab(workspace: workspace, env: env)
            } secondView: {
                ContextTab(
                    workspace: workspace,
                    appStore: appStore,
                    workspaceStore: workspaceStore,
                    branchListService: branchListService
                )
            }
        }
    }

    @ViewBuilder
    private func tabButton(label: String, icon: String, value: InspectorTab) -> some View {
        Button {
            withAnimation(Motion.standard.adaptive(reduceMotion)) { inspectorTab = value }
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
    @State private var diffText: String = ""
    @State private var diffError: String?
    @State private var selectedFile: String?

    /// Bucket the currently-selected file belongs to. Drives whether we
    /// render the diff against base+worktree, against base only, or as
    /// an all-added synthetic diff for an untracked file.
    private enum FileBucket { case modified, committed, untracked }

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
                        Section("Uncommitted") {
                            ForEach(s.modifiedFiles, id: \.self) { f in
                                fileRow(f, systemImage: "pencil", tint: .orange)
                            }
                        }
                    }
                    if !s.committedFiles.isEmpty {
                        Section("Committed vs \(workspace.baseBranch)") {
                            ForEach(s.committedFiles, id: \.self) { f in
                                fileRow(f, systemImage: "checkmark.seal", tint: .green)
                            }
                        }
                    }
                    if !s.untrackedFiles.isEmpty {
                        Section("Untracked") {
                            ForEach(s.untrackedFiles, id: \.self) { f in
                                fileRow(f, systemImage: "plus.circle", tint: .blue)
                            }
                        }
                    }
                    if s.modifiedFiles.isEmpty
                        && s.committedFiles.isEmpty
                        && s.untrackedFiles.isEmpty {
                        Section {
                            Text("No changes vs \(workspace.baseBranch)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 240)
                Divider()
                ScrollView {
                    if let err = diffError {
                        Text(err)
                            .font(.caption).foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if selectedFile == nil {
                        Text("Select a file to see its diff.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        UnifiedDiffView(diff: diffText)
                    }
                }
            } else {
                Spacer()
                ProgressView().padding()
                Spacer()
            }
        }
        .task(id: workspace.id) { await refresh() }
        .onChange(of: selectedFile) { _, _ in
            Task { await loadDiff() }
        }
    }

    @ViewBuilder
    private func fileRow(_ path: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.caption)
            Text(path).lineLimit(1).truncationMode(.middle)
        }
        .tag(Optional(path))
    }

    private func bucket(for path: String, in status: WorktreeStatus) -> FileBucket? {
        if status.modifiedFiles.contains(path) { return .modified }
        if status.committedFiles.contains(path) { return .committed }
        if status.untrackedFiles.contains(path) { return .untracked }
        return nil
    }

    @MainActor
    private func refresh() async {
        statusError = nil
        do {
            self.status = try env.worktree.status(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch
            )
            // Drop a stale selection if the file no longer appears in any
            // bucket — otherwise the diff pane keeps showing a phantom
            // diff after the file is reverted/committed.
            if let sel = selectedFile,
               let s = self.status,
               bucket(for: sel, in: s) == nil {
                selectedFile = nil
                diffText = ""
                diffError = nil
            } else {
                // Re-pull the diff in case the file's bucket changed
                // (e.g. user committed it).
                await loadDiff()
            }
        } catch {
            statusError = String(describing: error)
        }
    }

    @MainActor
    private func loadDiff() async {
        diffError = nil
        guard let f = selectedFile, let s = status, let b = bucket(for: f, in: s) else {
            diffText = ""
            return
        }
        do {
            switch b {
            case .modified:
                // Spans committed-on-branch + working-tree edits so the
                // user sees the full delta from base, not just the
                // uncommitted slice.
                diffText = try env.worktree.diffVsBaseIncludingWorktree(
                    worktreePath: workspace.worktreePath,
                    baseBranch: workspace.baseBranch,
                    file: f
                )
            case .committed:
                diffText = try env.worktree.diff(
                    worktreePath: workspace.worktreePath,
                    baseBranch: workspace.baseBranch,
                    file: f
                )
            case .untracked:
                diffText = env.worktree.diffForUntrackedFile(
                    worktreePath: workspace.worktreePath,
                    file: f
                )
            }
            if diffText.count > 400_000 {
                diffText = ""
                diffError = "(diff too large to preview)"
            }
        } catch {
            diffText = ""
            diffError = String(describing: error)
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

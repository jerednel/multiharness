import SwiftUI
import MultiharnessClient

struct WorkspaceDetailView: View {
    @Bindable var connection: ConnectionStore
    let workspace: RemoteWorkspace
    @State private var draft = ""
    @State private var contextExpanded = false

    private var project: RemoteProject? {
        connection.projects.first(where: { $0.id == workspace.projectId })
    }

    private var hasContext: Bool {
        !workspace.contextInstructions.isEmpty
            || !(project?.contextInstructions.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasContext {
                contextDisclosure
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Divider()
            }
            if let agent = connection.agents[workspace.id] {
                ConversationList(agent: agent, workspaceId: workspace.id)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            Divider()
            Composer(
                draft: $draft,
                isStreaming: connection.agents[workspace.id]?.isStreaming ?? false,
                onSend: { text in
                    Task { await connection.sendPrompt(workspaceId: workspace.id, message: text) }
                }
            )
            .padding(8)
        }
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workspace.id) {
            await connection.openWorkspace(workspace)
            await connection.markViewed(workspaceId: workspace.id)
        }
    }

    @ViewBuilder
    private var contextDisclosure: some View {
        DisclosureGroup(isExpanded: $contextExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let p = project, !p.contextInstructions.isEmpty {
                    Text("Project").font(.caption).bold().foregroundStyle(.secondary)
                    Text(p.contextInstructions)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if !workspace.contextInstructions.isEmpty {
                    Text("Workspace").font(.caption).bold().foregroundStyle(.secondary)
                    Text(workspace.contextInstructions)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.caption)
                Text("Context").font(.caption).bold()
            }
        }
    }
}

private struct ConversationList: View {
    @Bindable var agent: RemoteAgentStore
    let workspaceId: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groupConversationTurns(agent.turns), id: \.id) { row in
                        switch row {
                        case .single(let turn):
                            TurnRow(turn: turn).id(turn.id)
                        case .group(let id, let children):
                            ResponseGroupRow(groupId: id, children: children)
                                .id(id)
                        }
                    }
                    if agent.isStreaming && !hasActiveGroup {
                        ThinkingRow().id("thinking")
                    }
                }
                .padding(12)
            }
            .onChange(of: agent.turns.count) { _, _ in
                if let last = agent.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: workspaceId, initial: true) { _, _ in
                // Land at the most recent message on initial appearance and
                // when switching workspaces. Instant jump avoids the
                // "scroll-down" tease.
                if let last = agent.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else if agent.isStreaming {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            }
        }
    }

    private var hasActiveGroup: Bool {
        guard let last = agent.turns.last, last.groupId != nil else { return false }
        return agent.isStreaming
    }
}

private struct ResponseGroupRow: View {
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
        VStack(alignment: .leading, spacing: 6) {
            Button {
                manuallyToggled = true
                manualExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    if isStreaming {
                        ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(collapsedChildren) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
            }

            if let final = liftedFinal {
                TurnRow(turn: final).id(final.id)
            }
        }
        .onChange(of: isStreaming) { _, nowStreaming in
            if nowStreaming { manuallyToggled = false }
        }
    }
}

private struct TurnRow: View {
    let turn: ConversationTurn
    @State private var expanded = false

    var body: some View {
        if turn.role == .tool {
            toolRow
        } else {
            messageRow
        }
    }

    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.orange).font(.caption)
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
            .buttonStyle(.plain)
            if expanded {
                Text(turn.text.isEmpty ? "(no output)" : turn.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turn.role == .user ? "person.crop.circle" : "sparkles")
                .foregroundStyle(turn.role == .user ? .blue : .purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.role == .user ? "You" : "Agent")
                    .font(.caption).bold().foregroundStyle(.secondary)
                Group {
                    if turn.role == .assistant {
                        MarkdownMessageText(turn.text)
                    } else {
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
                }
                .font(.body)
                .padding(8)
                .background(
                    turn.role == .user ? Color.blue.opacity(0.10) : Color.purple.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Agent").font(.caption).bold().foregroundStyle(.secondary)
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            Spacer()
        }
        .padding(8)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Composer: View {
    @Binding var draft: String
    let isStreaming: Bool
    let onSend: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .padding(.horizontal, 8)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStreaming)
            .buttonStyle(.borderedProminent)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

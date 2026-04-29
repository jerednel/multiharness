import SwiftUI
import MultiharnessClient

struct WorkspaceDetailView: View {
    @Bindable var connection: ConnectionStore
    let workspace: RemoteWorkspace
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
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
                    ForEach(agent.turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                    if agent.isStreaming {
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
                    Text(turn.toolName ?? "tool").font(.caption).bold()
                    Text("·").foregroundStyle(.secondary)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    private var summary: String {
        let firstLine = turn.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if firstLine.isEmpty { return turn.streaming ? "running…" : "done" }
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
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

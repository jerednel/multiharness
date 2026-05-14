import SwiftUI
import MultiharnessClient
import PhotosUI

struct WorkspaceDetailView: View {
    @Bindable var connection: ConnectionStore
    let workspace: RemoteWorkspace
    @State private var draft = ""
    @State private var draftImages: [TurnImage] = []
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
                images: $draftImages,
                isStreaming: connection.agents[workspace.id]?.isStreaming ?? false,
                onSend: { text, imgs in
                    Task {
                        await connection.sendPrompt(
                            workspaceId: workspace.id,
                            message: text,
                            images: imgs
                        )
                    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                withAnimation(Motion.disclosure.adaptive(reduceMotion)) {
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(collapsedChildren) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
                .transition(.disclosureContent)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if turn.role == .tool {
            toolRow
        } else {
            messageRow
        }
    }

    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.disclosure.adaptive(reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
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
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turn.role == .user ? "person.crop.circle" : "sparkles")
                .foregroundStyle(turn.role == .user ? .blue : .purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.role == .user ? "You" : "Agent")
                    .font(.caption).bold().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    if !turn.images.isEmpty {
                        // Wrapping row of thumbnails (the iOS UIImage path —
                        // ComposerImages on iOS materializes UIImage from
                        // Data the same way the Mac side uses NSImage).
                        IOSAttachmentThumbStrip(images: turn.images)
                    }
                    if !turn.text.isEmpty {
                        if turn.role == .assistant {
                            MarkdownMessageText(turn.text)
                        } else {
                            Text(turn.text)
                                .textSelection(.enabled)
                        }
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
    @Binding var images: [TurnImage]
    let isStreaming: Bool
    let onSend: (String, [TurnImage]) -> Void

    /// PhotosPicker selection. Decoded into `images` in the `.onChange`
    /// handler then cleared so the picker is ready for another pick.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachError: String?
    /// Mirrors `UIPasteboard.general.hasImages`. SwiftUI's iOS
    /// `onPasteCommand` is unavailable, so we surface a manual "paste
    /// image from clipboard" button that lights up only when the system
    /// clipboard actually contains an image (refreshed on scene
    /// activation and after attach actions).
    @State private var clipboardHasImage: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = attachError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !images.isEmpty {
                IOSComposerAttachmentStrip(images: $images)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: 8,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .padding(.horizontal, 4)
                }
                .disabled(isStreaming)

                // Paste-from-clipboard button. iOS doesn't expose a
                // SwiftUI paste hook on TextField (`onPasteCommand` is
                // explicitly unavailable), and `PasteButton` insists on
                // its own visual treatment, so we read UIPasteboard
                // directly. The button only renders when there's
                // actually an image to paste — avoids a permanently-on
                // dimmed control that conveys nothing.
                if clipboardHasImage {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title3)
                            .padding(.horizontal, 4)
                    }
                    .disabled(isStreaming)
                }

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
                .disabled(sendDisabled)
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { refreshClipboardState() }
        // UIPasteboard doesn't have a SwiftUI-native change publisher;
        // poll on the scene-active notification so the button appears
        // when the user copies a screenshot in another app and switches
        // back. Cheap (one bool flip).
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshClipboardState()
        }
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { @MainActor in
                var picked: [TurnImage] = []
                var err: String?
                for item in newItems {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let img = IOSComposerPaste.encodeRawImageData(data) {
                            picked.append(img)
                        }
                    } catch {
                        err = error.localizedDescription
                    }
                }
                images.append(contentsOf: picked)
                if let err { attachError = err } else { attachError = nil }
                photoItems = []
            }
        }
    }

    private var sendDisabled: Bool {
        let textEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if textEmpty && images.isEmpty { return true }
        if isStreaming { return true }
        return false
    }

    /// Read every image on the clipboard, encode each through the same
    /// pipeline the PhotosPicker path uses, and append to the staged
    /// list. After consuming we re-check `hasImages` so the button hides
    /// once the clipboard is exhausted (matches the user's intuition
    /// that "Paste" is a one-shot action on a given snapshot).
    @MainActor
    private func pasteFromClipboard() {
        let pb = UIPasteboard.general
        var picked: [TurnImage] = []
        var lastErr: String?
        // `pb.images` covers the common UIImage path. For something
        // weird like a clipboard with explicit HEIC data and no UIImage
        // rep we'd need `pb.data(forPasteboardType:)` — skipping that
        // until we see a real case; UIImage covers screenshots, Safari
        // image copies, Photos, Markup, etc.
        if let uiimgs = pb.images, !uiimgs.isEmpty {
            for ui in uiimgs {
                if let data = ui.pngData(),
                   let img = IOSComposerPaste.encodeRawImageData(data, hint: .png) {
                    picked.append(img)
                } else if let data = ui.jpegData(compressionQuality: 0.9),
                          let img = IOSComposerPaste.encodeRawImageData(data, hint: .jpeg) {
                    picked.append(img)
                } else {
                    lastErr = "Could not encode pasted image"
                }
            }
        }
        if !picked.isEmpty {
            images.append(contentsOf: picked)
            attachError = nil
        }
        if let lastErr { attachError = lastErr }
        refreshClipboardState()
    }

    @MainActor
    private func refreshClipboardState() {
        // `hasImages` is true for both single-image and multi-image
        // clipboard contents. Cheap synchronous call; no entitlement
        // prompt on iOS 16+ for `hasImages`/`hasStrings` (the prompt
        // only fires when you actually read the data).
        clipboardHasImage = UIPasteboard.general.hasImages
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = images
        guard !text.isEmpty || !imgs.isEmpty else { return }
        draft = ""
        images = []
        onSend(text, imgs)
    }
}

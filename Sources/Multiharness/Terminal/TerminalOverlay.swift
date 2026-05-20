import SwiftUI
import AppKit
import SwiftTerm
import MultiharnessClient

/// SwiftUI wrapper that hands SwiftUI back the *same* NSView each time
/// the overlay opens. Creating a new `LocalProcessTerminalView` per
/// reveal would respawn the shell and lose scrollback, which is the
/// opposite of what the user wants when they hide+show the panel.
struct TerminalNSView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return session.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No-op: the view's state lives entirely in the SwiftTerm
        // process + buffer, neither of which we want to reach into from
        // SwiftUI's reactive update path.
    }
}

/// Floating terminal panel anchored over the conversation column.
/// Visibility is driven by a parent `@State` binding; the panel itself
/// is unaware of the Ctrl+\` shortcut that drives it.
struct TerminalOverlay: View {
    let workspace: Workspace
    @Bindable var registry: TerminalRegistryStore
    @Binding var isVisible: Bool

    var body: some View {
        let session = registry.ensure(
            workspaceId: workspace.id,
            worktreePath: workspace.worktreePath
        )
        return VStack(spacing: 0) {
            header
            Divider()
            TerminalNSView(session: session)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 6)
        .onAppear {
            // Bounce to the next runloop so the NSView is already
            // attached to a window — makeFirstResponder is a no-op
            // before that. Without this the user has to click into
            // the terminal before they can type.
            DispatchQueue.main.async {
                session.view.window?.makeFirstResponder(session.view)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workspace.worktreePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("⌃`")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
            Button {
                isVisible = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide terminal (⌃`)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// Catches Ctrl+\` (toggle) and Esc (hide) at the window level so the
/// shortcut keeps working even when the terminal NSView has key focus
/// (SwiftUI's `.keyboardShortcut` doesn't reach inside an
/// NSViewRepresentable that consumes keyDown events).
struct TerminalKeyboardMonitor: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.install()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        @Binding var isVisible: Bool
        private var monitor: Any?

        init(isVisible: Binding<Bool>) {
            self._isVisible = isVisible
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Ctrl+` — the backtick key reports as keyCode 50 on
                // US/ANSI Mac keyboards. Checking character coverage
                // alongside lets non-US layouts where ` lives elsewhere
                // still fire the shortcut.
                let isCtrl = event.modifierFlags.contains(.control)
                let isBacktick = (event.charactersIgnoringModifiers == "`") || event.keyCode == 50
                if isCtrl && isBacktick {
                    self.isVisible.toggle()
                    return nil
                }
                // Esc when the overlay is visible → hide. We don't
                // swallow Esc otherwise so other escape-key handlers
                // (sheet dismissal, etc.) keep working.
                if self.isVisible && event.keyCode == 53 {
                    self.isVisible = false
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }
}

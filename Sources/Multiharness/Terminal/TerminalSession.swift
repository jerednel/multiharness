import Foundation
import AppKit
import Observation
import SwiftTerm

/// Owns the long-lived `LocalProcessTerminalView` for one workspace.
/// The NSView is preserved across overlay hide/show so the terminal
/// keeps its scrollback, command history, and live process tree —
/// SwiftUI's `NSViewRepresentable` re-attaches the same instance each
/// time the overlay reveals.
@MainActor
final class TerminalSession {
    let workspaceId: UUID
    let view: LocalProcessTerminalView

    init(workspaceId: UUID, worktreePath: String) {
        self.workspaceId = workspaceId
        // Initial frame is provisional — SwiftUI's NSViewRepresentable
        // sets the real frame on first layout. SwiftTerm reads the frame
        // through `sizeChanged` and resizes the PTY accordingly.
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        // Default colors come from the system; explicit set keeps the
        // terminal readable against the overlay's translucent backdrop.
        view.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1.0)
        view.nativeForegroundColor = NSColor(white: 0.95, alpha: 1.0)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-l"], // login shell so the user's PATH/aliases match Terminal.app
            currentDirectory: worktreePath
        )
    }

    func dispose() {
        view.terminate()
    }
}

/// Lazy per-workspace map of `TerminalSession`s. Mirrors
/// `AgentRegistryStore`'s ensure-on-demand pattern. A workspace's shell
/// is created the first time the user reveals the terminal overlay and
/// stays alive until the app shuts down (or the workspace is archived,
/// at which point the caller invokes `dispose`).
@MainActor
@Observable
final class TerminalRegistryStore {
    private var sessions: [UUID: TerminalSession] = [:]

    func ensure(workspaceId: UUID, worktreePath: String) -> TerminalSession {
        if let existing = sessions[workspaceId] { return existing }
        let session = TerminalSession(workspaceId: workspaceId, worktreePath: worktreePath)
        sessions[workspaceId] = session
        return session
    }

    func dispose(workspaceId: UUID) {
        sessions.removeValue(forKey: workspaceId)?.dispose()
    }

    func disposeAll() {
        for s in sessions.values { s.dispose() }
        sessions.removeAll()
    }
}

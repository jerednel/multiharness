import Foundation

/// Pure decision function: should the agent-completion chime play for this
/// `agent_end` event?
///
/// The only suppression case is "the user is already looking at this exact
/// workspace" — Multiharness frontmost AND the finished workspace matches the
/// sidebar selection. Every other state (app backgrounded, minimized, on
/// another Space, or focused on a different workspace) plays the chime.
public enum CompletionSoundDecision {
    public static func shouldPlay(
        enabled: Bool,
        appIsFrontmost: Bool,
        selectedWorkspaceId: UUID?,
        eventWorkspaceId: UUID
    ) -> Bool {
        guard enabled else { return false }
        if appIsFrontmost && selectedWorkspaceId == eventWorkspaceId {
            return false
        }
        return true
    }
}

import Foundation
import MultiharnessClient

/// Per-workspace draft storage that outlives Composer view teardowns.
///
/// iOS's `WorkspaceDetailView` uses `.id(workspace.id)` so transient UI
/// state resets on workspace switch. This store lives above the view tree
/// so the user's draft text and staged images survive navigation and are
/// restored when they return to a workspace.
@MainActor
@Observable
final class ComposerDraftStore {
    private var drafts: [String: String] = [:]
    private var images: [String: [TurnImage]] = [:]

    func draft(for workspaceId: String) -> String {
        drafts[workspaceId] ?? ""
    }

    func setDraft(_ text: String, for workspaceId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: workspaceId)
        } else {
            drafts[workspaceId] = text
        }
    }

    func pendingImages(for workspaceId: String) -> [TurnImage] {
        images[workspaceId] ?? []
    }

    func setPendingImages(_ imgs: [TurnImage], for workspaceId: String) {
        if imgs.isEmpty {
            images.removeValue(forKey: workspaceId)
        } else {
            images[workspaceId] = imgs
        }
    }
}

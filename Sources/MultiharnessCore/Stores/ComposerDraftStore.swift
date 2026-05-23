import Foundation
import MultiharnessClient

/// Per-workspace draft storage that outlives Composer view teardowns.
///
/// The Composer view is identified by `.id(workspace.id)` so that
/// transient UI state (popover visibility, QA launching flag, etc.)
/// resets on workspace switch. That teardown previously wiped the
/// user's in-progress draft text and staged images. `ComposerDraftStore`
/// lives above the view tree — created once at app launch and injected
/// into the Composer — so drafts survive switches and are restored when
/// the user returns to a workspace.
@MainActor
@Observable
public final class ComposerDraftStore {
    /// Draft text keyed by workspace ID.
    var drafts: [UUID: String] = [:]
    /// Staged image attachments keyed by workspace ID.
    var images: [UUID: [TurnImage]] = [:]

    public init() {}

    public func draft(for workspaceId: UUID) -> String {
        drafts[workspaceId] ?? ""
    }

    public func setDraft(_ text: String, for workspaceId: UUID) {
        if text.isEmpty {
            drafts.removeValue(forKey: workspaceId)
        } else {
            drafts[workspaceId] = text
        }
    }

    public func pendingImages(for workspaceId: UUID) -> [TurnImage] {
        images[workspaceId] ?? []
    }

    public func setPendingImages(_ imgs: [TurnImage], for workspaceId: UUID) {
        if imgs.isEmpty {
            images.removeValue(forKey: workspaceId)
        } else {
            images[workspaceId] = imgs
        }
    }

    /// Clear all state for a workspace (e.g. after archiving).
    public func clear(workspaceId: UUID) {
        drafts.removeValue(forKey: workspaceId)
        images.removeValue(forKey: workspaceId)
    }
}

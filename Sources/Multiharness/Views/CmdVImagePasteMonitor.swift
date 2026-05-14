import SwiftUI
import AppKit

/// Invisible SwiftUI view that installs an NSEvent local monitor for
/// Cmd-V while it's in the hierarchy. The monitor fires for *every*
/// keyDown that hits the app's main event loop, BEFORE the keystroke
/// is dispatched to firstResponder (so the focused TextField's field
/// editor hasn't yet rejected the non-text paste with the system bell).
///
/// Why a global monitor instead of a more targeted hook:
///
///  - SwiftUI's `.onPasteCommand` is swallowed when a TextField has
///    focus — the field editor consumes `paste:` and rejects non-text
///    data with `NSBeep`, so the modifier never runs.
///  - Wrapping the TextField in an NSViewRepresentable that overrides
///    `paste:` works in theory but breaks SwiftUI's autosize + Return-
///    to-submit + focus glue (we tried; the box ballooned to its max
///    height and Cmd-V still beeped because focus never landed on the
///    custom view).
///  - A `localMonitorForEvents` is the documented Cocoa way to peek at
///    events before responder dispatch. We narrow it to Cmd-V only,
///    check the pasteboard for image data, and consume the event iff
///    we successfully attach. Plain Cmd-V text paste falls through to
///    the field editor unchanged.
///
/// Scope: the monitor is installed on `makeNSView` and removed on
/// `dismantleNSView`, so it's only active while this Composer is
/// present in the view hierarchy. Multiple composers (multi-window)
/// each install their own monitor — that's fine because each handler
/// guards on "did we actually attach anything?" and bails out
/// otherwise, so only the focused workspace's composer gets the image.
struct CmdVImagePasteMonitor: NSViewRepresentable {
    /// Called on Cmd-V whenever the pasteboard contains at least one
    /// image. Return `true` to consume the event (composer attached
    /// the image, suppress text-paste); return `false` to let the
    /// event continue and the field editor handle it as a text paste.
    let onPasteImages: ([NSImage]) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onPasteImages: onPasteImages)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refresh the closure on every SwiftUI update so the monitor
        // captures the current `pendingImages` binding (SwiftUI may
        // recreate the closure with stale captured @State otherwise).
        context.coordinator.handler = onPasteImages
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var handler: (([NSImage]) -> Bool)?

        func install(onPasteImages: @escaping ([NSImage]) -> Bool) {
            // Already installed (SwiftUI sometimes calls makeNSView
            // again on view-identity churn) — replace the handler in
            // place to avoid dangling monitors.
            self.handler = onPasteImages
            if monitor != nil { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Cmd-V (no other modifiers among the gating set). We
                // ignore Shift/Option-modified V so Cmd-Shift-V (paste
                // and match style) and similar don't get intercepted.
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v"
                else { return event }

                // Peek at the pasteboard. NSImage objects cover the
                // common cases (screenshots, Preview / Safari image
                // copies, Photos drag, Markup output).
                let pb = NSPasteboard.general
                let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
                guard !imgs.isEmpty else { return event }

                // Try to attach. If the handler refuses (no image bytes
                // survived re-encoding), pass through so the field
                // editor still attempts a text paste — which will beep,
                // but that's no worse than the pre-fix behavior.
                if self.handler?(imgs) == true {
                    return nil  // consume
                }
                return event
            }
        }

        func uninstall() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
            handler = nil
        }

        deinit { uninstall() }
    }
}

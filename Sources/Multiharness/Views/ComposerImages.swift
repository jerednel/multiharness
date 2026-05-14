import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultiharnessClient

/// Hard cap on a single attached image's encoded size. Anything bigger is
/// recompressed to JPEG @ 0.85 before we give up; this prevents a 40 MB
/// PNG screenshot from blowing past the ControlClient's 60 MB preflight
/// frame ceiling. Picked to leave headroom for several images + a long
/// caption in one prompt.
private let kMaxImageBytes = 8 * 1024 * 1024

/// Pasteboard + drag-and-drop helpers for the composer. Lives in its own
/// file so the WorkspaceDetailView stays readable. All entrypoints return
/// the same `Result` shape so the Composer can apply a uniform
/// "appended N, last error: M" UX.
enum ComposerPaste {
    struct Result {
        var images: [TurnImage]
        var error: String?
    }

    /// Plain string-wrapped error so `loadImage` can return
    /// `Swift.Result<TurnImage, ImageLoadError>` (Result requires the
    /// Failure type conform to `Error`).
    struct ImageLoadError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// UTTypes we ask the system for. PNG/JPEG are direct hits for
    /// screenshots; `.image` catches HEIC, TIFF, GIF, and image files
    /// dragged in from Finder. `.fileURL` is needed because some apps
    /// (Preview, Finder) put a file reference on the pasteboard rather
    /// than the bytes.
    static var acceptedTypes: [UTType] {
        [.png, .jpeg, .image, .fileURL]
    }

    /// Walk a set of `NSItemProvider`s from `onPasteCommand` /
    /// `onDrop`, decode every one we can, and hand the accumulated
    /// result back on the main actor.
    static func absorb(
        providers: [NSItemProvider],
        completion: @escaping (Result) -> Void
    ) {
        let group = DispatchGroup()
        var images: [TurnImage] = []
        var lastError: String?
        let lock = NSLock()
        func push(_ img: TurnImage) {
            lock.lock(); defer { lock.unlock() }
            images.append(img)
        }
        func setErr(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            lastError = s
        }

        for provider in providers {
            // Prefer the raw image bytes path when available (cleaner,
            // no temp-file round-trip). Fall back to .fileURL.
            if provider.canLoadObject(ofClass: NSImage.self) {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    defer { group.leave() }
                    if let data, let img = encode(rawData: data, sourceMime: "image/png") {
                        push(img)
                    } else {
                        // PNG load failed; try JPEG.
                        group.enter()
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { jdata, _ in
                            defer { group.leave() }
                            if let jdata, let img = encode(rawData: jdata, sourceMime: "image/jpeg") {
                                push(img)
                            } else {
                                // Last resort: ask for an NSImage and re-encode.
                                group.enter()
                                provider.loadObject(ofClass: NSImage.self) { obj, err in
                                    defer { group.leave() }
                                    if let nsimg = obj as? NSImage, let img = encode(nsImage: nsimg) {
                                        push(img)
                                    } else if let err {
                                        setErr(err.localizedDescription)
                                    }
                                }
                            }
                        }
                    }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    switch loadImage(at: url) {
                    case .success(let img): push(img)
                    case .failure(let e): setErr(e.message)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            completion(Result(images: images, error: lastError))
        }
    }

    /// Turn a list of NSImages (typically straight off the pasteboard
    /// via `NSPasteboard.readObjects(forClasses: [NSImage.self], …)`)
    /// into encoded TurnImages. Used by the composer's Cmd-V intercept
    /// inside `PasteAwareTextEditor`, which bypasses the
    /// `NSItemProvider`-based path because NSTextView's `paste:`
    /// override doesn't get providers — only the live pasteboard.
    static func encode(nsImages: [NSImage]) -> [TurnImage] {
        return nsImages.compactMap { encode(nsImage: $0) }
    }

    /// Read an image file from disk and turn it into a `TurnImage`. Used
    /// by the Composer's attach button and as a fallback inside drag
    /// handling.
    static func loadImage(at url: URL) -> Swift.Result<TurnImage, ImageLoadError> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ImageLoadError(message: "Could not read \(url.lastPathComponent)"))
        }
        let mime = mimeForExtension(url.pathExtension)
        if let img = encode(rawData: data, sourceMime: mime) {
            return .success(img)
        }
        return .failure(ImageLoadError(message: "Unsupported image: \(url.lastPathComponent)"))
    }

    /// Decide the wire mime + (re)compress if needed. Returns nil only
    /// when both the raw bytes and the fallback JPEG re-encode are
    /// unrenderable as an image.
    private static func encode(rawData: Data, sourceMime: String) -> TurnImage? {
        // Trust the bytes as-is when they're under the cap and a sane
        // image-shaped mime.
        if rawData.count <= kMaxImageBytes {
            // Sanity-check that the bytes actually decode — guards against
            // garbage on the pasteboard that happens to claim image/* mime.
            if NSImage(data: rawData) != nil {
                return TurnImage(data: rawData, mimeType: sourceMime)
            }
        }
        // Oversized or unrecognized — recompress via NSImage → JPEG.
        guard let nsimg = NSImage(data: rawData) else { return nil }
        return encode(nsImage: nsimg)
    }

    private static func encode(nsImage: NSImage) -> TurnImage? {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        // 0.85 is the same default Preview uses for "Export as JPEG…" at
        // medium-high quality. Aggressive enough to keep typical
        // screenshots well under the cap; preserves enough fidelity that
        // diff/UI screenshots remain readable to the model.
        if let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        ), jpeg.count <= kMaxImageBytes {
            return TurnImage(data: jpeg, mimeType: "image/jpeg")
        }
        // If even 0.85 is too big (huge screenshot, retina × wide), drop
        // to 0.6. Acceptable degradation for a screenshot at that point.
        if let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.6]
        ), jpeg.count <= kMaxImageBytes {
            return TurnImage(data: jpeg, mimeType: "image/jpeg")
        }
        return nil
    }

    private static func mimeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }
}

/// Read-only thumbnail row used inside an already-sent user turn card.
struct AttachmentThumbStrip: View {
    let images: [TurnImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { img in
                    if let nsimg = NSImage(data: img.data) {
                        Image(nsImage: nsimg)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary, lineWidth: 1)
                            )
                            .contextMenu {
                                Button("Save As…") { saveAttachment(img) }
                                Button("Copy") { copyAttachment(img) }
                            }
                    } else {
                        // Bytes didn't decode — show a placeholder so the
                        // turn doesn't silently lose the attachment.
                        unrenderablePlaceholder
                    }
                }
            }
        }
    }

    private var unrenderablePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
        .frame(width: 96, height: 96)
    }

    private func saveAttachment(_ img: TurnImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.\(ext(for: img.mimeType))"
        if panel.runModal() == .OK, let url = panel.url {
            try? img.data.write(to: url)
        }
    }

    private func copyAttachment(_ img: TurnImage) {
        guard let nsimg = NSImage(data: img.data) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsimg])
    }

    private func ext(for mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return "png"
        }
    }
}

/// Editable attachment row used in the composer above the text field.
/// Each thumbnail has a tap-target X overlay that removes it from the
/// pending list. Sits on its own ScrollView so a wide row of paste-fest
/// thumbnails doesn't push the text field off-screen.
struct ComposerAttachmentStrip: View {
    @Binding var images: [TurnImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { img in
                    ZStack(alignment: .topTrailing) {
                        if let nsimg = NSImage(data: img.data) {
                            Image(nsImage: nsimg)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.quaternary, lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                                .frame(width: 72, height: 72)
                        }
                        Button {
                            images.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                    }
                }
            }
        }
        .frame(height: 78)
    }
}

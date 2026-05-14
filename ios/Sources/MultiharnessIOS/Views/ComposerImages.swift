import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MultiharnessClient

/// iOS-side counterpart to `Sources/Multiharness/Views/ComposerImages.swift`.
/// Keeps the cross-platform `TurnImage` wire shape but uses UIImage to
/// decode/re-encode bytes. The wire mime types stay aligned with the Mac so
/// a screenshot pasted on iPhone shows up identically when the same
/// workspace history is rehydrated on the Mac.

/// Same 8 MB cap as the Mac side. Big enough for a typical
/// high-DPI screenshot at JPEG q=0.85; small enough that several images
/// + a long caption stay under the ControlClient's 60 MB preflight ceiling.
private let kMaxImageBytes = 8 * 1024 * 1024

/// Pasteboard handlers for the iOS composer. Exposes the same `Result`
/// shape as the Mac so the calling site can stay symmetric.
enum IOSComposerPaste {
    struct Result {
        var images: [TurnImage]
        var error: String?
    }

    /// UTType identifiers the composer accepts via `onPasteCommand`. We ask
    /// for both PNG and JPEG explicitly so iOS doesn't decode-then-recompress
    /// when the clipboard already has a clean PNG (screenshots).
    static var acceptedTypeIdentifiers: [UTType] {
        [.png, .jpeg, .image]
    }

    /// Walk a set of `NSItemProvider`s, decode every one we can, and hand
    /// the accumulated result back on the main actor.
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
            // Try PNG first (most screenshot-friendly), then JPEG, then the
            // generic image identifier. We stop after the first hit per
            // provider to avoid attaching the same image twice.
            let candidates: [UTType] = [.png, .jpeg, .image]
            group.enter()
            attemptLoad(provider: provider, candidates: candidates, index: 0) { result in
                switch result {
                case .ok(let img): push(img)
                case .err(let e): setErr(e)
                case .skip: break
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(Result(images: images, error: lastError))
        }
    }

    private enum AttemptOutcome {
        case ok(TurnImage)
        case err(String)
        case skip
    }

    /// Recursive walk over the candidate UTTypes for a single provider.
    /// Bails out at the first successful decode; only surfaces an error if
    /// every candidate failed AND at least one of them produced a real
    /// error (rather than "type not supported").
    private static func attemptLoad(
        provider: NSItemProvider,
        candidates: [UTType],
        index: Int,
        completion: @escaping (AttemptOutcome) -> Void
    ) {
        if index >= candidates.count {
            completion(.skip)
            return
        }
        let type = candidates[index]
        if !provider.hasItemConformingToTypeIdentifier(type.identifier) {
            attemptLoad(
                provider: provider,
                candidates: candidates,
                index: index + 1,
                completion: completion
            )
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, err in
            if let data, let img = encodeRawImageData(data, hint: type) {
                completion(.ok(img))
                return
            }
            if let err {
                completion(.err(err.localizedDescription))
                return
            }
            attemptLoad(
                provider: provider,
                candidates: candidates,
                index: index + 1,
                completion: completion
            )
        }
    }

    /// Public so PhotosPicker can reuse the same encode path. Takes a
    /// `hint` to skip a re-encode when the bytes are already a sane size
    /// in PNG/JPEG.
    static func encodeRawImageData(_ data: Data, hint: UTType? = nil) -> TurnImage? {
        let sourceMime = mime(for: hint)
        if data.count <= kMaxImageBytes {
            // Sanity-check decode so garbage bytes claiming image/* mime
            // don't end up as broken thumbnails downstream.
            if UIImage(data: data) != nil {
                return TurnImage(data: data, mimeType: sourceMime)
            }
        }
        // Oversized or unrecognized — recompress via UIImage → JPEG.
        guard let uiimg = UIImage(data: data) else { return nil }
        return encode(uiImage: uiimg)
    }

    private static func encode(uiImage: UIImage) -> TurnImage? {
        if let jpeg = uiImage.jpegData(compressionQuality: 0.85),
           jpeg.count <= kMaxImageBytes {
            return TurnImage(data: jpeg, mimeType: "image/jpeg")
        }
        if let jpeg = uiImage.jpegData(compressionQuality: 0.6),
           jpeg.count <= kMaxImageBytes {
            return TurnImage(data: jpeg, mimeType: "image/jpeg")
        }
        return nil
    }

    private static func mime(for type: UTType?) -> String {
        switch type {
        case .some(.png): return "image/png"
        case .some(.jpeg): return "image/jpeg"
        case .some(.gif): return "image/gif"
        case .some(.heic): return "image/heic"
        default: return "image/jpeg"
        }
    }
}

/// Read-only thumbnail row used inside an already-sent user turn row.
struct IOSAttachmentThumbStrip: View {
    let images: [TurnImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { img in
                    if let uiimg = UIImage(data: img.data) {
                        Image(uiImage: uiimg)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary, lineWidth: 1)
                            )
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                        .frame(width: 96, height: 96)
                    }
                }
            }
        }
    }
}

/// Editable attachment row used in the composer above the text field.
struct IOSComposerAttachmentStrip: View {
    @Binding var images: [TurnImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { img in
                    ZStack(alignment: .topTrailing) {
                        if let uiimg = UIImage(data: img.data) {
                            Image(uiImage: uiimg)
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
                                .font(.system(size: 18))
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

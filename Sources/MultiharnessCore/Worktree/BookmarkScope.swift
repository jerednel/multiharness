import Foundation

/// Captures and resurrects security-scoped URL handles so the app can keep
/// reading/writing TCC-protected directories (Documents, Desktop, etc.) across
/// launches without re-prompting the user every time.
///
/// Usage:
/// 1. When `NSOpenPanel` returns a URL, call `BookmarkScope.makeBookmark(for:)`
///    while the panel's implicit grant is still active.
/// 2. Persist the returned `Data` blob alongside the project row.
/// 3. At app launch, call `BookmarkScope.shared.resolve(_:)` for each project's
///    bookmark to reactivate access. The shared instance keeps each scoped URL
///    alive for the app's lifetime via `startAccessingSecurityScopedResource()`.
public final class BookmarkScope: @unchecked Sendable {
    public static let shared = BookmarkScope()

    private let lock = NSLock()
    private var resolved: [UUID: URL] = [:]

    public init() {}

    /// Build a security-scoped bookmark for the given URL. Call this immediately
    /// after the user picks the URL via `NSOpenPanel` (which provides the
    /// implicit grant).
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a previously stored bookmark and start accessing the
    /// security-scoped resource. The returned URL is retained in the shared
    /// scope for the app's lifetime so the scope stays open.
    @discardableResult
    public func resolve(id: UUID, bookmark: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolved[id] { return cached }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        if !url.startAccessingSecurityScopedResource() {
            // Even when start fails, return the URL — TCC may have silently
            // upgraded the grant or the path may not be in a protected
            // directory. Callers can still attempt operations on the path.
        }
        resolved[id] = url
        return url
    }

    /// Stop accessing a previously resolved scope (e.g. when a project is
    /// deleted). Safe to call on an unknown id.
    public func release(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let url = resolved.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Whether the bookmark went stale (path moved or the binding broke).
    /// Caller should re-prompt the user if true.
    public static func isStale(_ bookmark: Data) -> Bool {
        var stale = false
        _ = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return stale
    }
}

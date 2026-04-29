import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Thin wrapper over the macOS-bundled libsqlite3 C API.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var h: OpaquePointer?
        guard sqlite3_open(path, &h) == SQLITE_OK else {
            let msg = h.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(h)
            throw DatabaseError.openFailed(msg)
        }
        self.handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.exec(rc: rc, message: msg)
        }
    }

    public func query<T>(
        _ sql: String,
        bind: (Statement) throws -> Void = { _ in },
        rowMap: (Statement) throws -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              let s = stmt
        else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.prepare(message: msg)
        }
        defer { sqlite3_finalize(s) }
        let st = Statement(handle: s)
        try bind(st)
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                rows.append(try rowMap(st))
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw DatabaseError.exec(rc: rc, message: msg)
            }
        }
        return rows
    }

    public func executeUpdate(_ sql: String, bind: (Statement) throws -> Void) throws {
        _ = try query(sql, bind: bind, rowMap: { _ in 0 as Int })
    }
}

public enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case exec(rc: Int32, message: String)
    case prepare(message: String)

    public var description: String {
        switch self {
        case .openFailed(let m): return "open failed: \(m)"
        case .exec(let rc, let m): return "exec failed (rc=\(rc)): \(m)"
        case .prepare(let m): return "prepare failed: \(m)"
        }
    }
}

/// Thin wrapper around a single sqlite3 prepared statement for binding/extraction.
public final class Statement {
    private let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }

    public func bind(_ idx: Int32, _ v: String?) {
        if let v {
            sqlite3_bind_text(handle, idx, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    public func bind(_ idx: Int32, _ v: Int64?) {
        if let v {
            sqlite3_bind_int64(handle, idx, v)
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    public func bind(_ idx: Int32, _ v: Data?) {
        if let v {
            v.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                _ = sqlite3_bind_blob(handle, idx, ptr.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    public func data(_ idx: Int32) -> Data? {
        if sqlite3_column_type(handle, idx) == SQLITE_NULL { return nil }
        let bytes = sqlite3_column_blob(handle, idx)
        let len = Int(sqlite3_column_bytes(handle, idx))
        guard let bytes else { return Data() }
        return Data(bytes: bytes, count: len)
    }

    public func bind(_ idx: Int32, _ v: Date?) {
        if let v {
            sqlite3_bind_int64(handle, idx, Int64(v.timeIntervalSince1970 * 1000))
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    public func string(_ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(handle, idx) else { return nil }
        return String(cString: cstr)
    }

    public func requiredString(_ idx: Int32) -> String {
        return string(idx) ?? ""
    }

    public func int64(_ idx: Int32) -> Int64? {
        if sqlite3_column_type(handle, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(handle, idx)
    }

    public func date(_ idx: Int32) -> Date? {
        guard let ms = int64(idx) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    public func requiredDate(_ idx: Int32) -> Date {
        return date(idx) ?? Date(timeIntervalSince1970: 0)
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

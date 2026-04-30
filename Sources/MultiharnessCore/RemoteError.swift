import Foundation

/// Standard error type for Mac-side relay handlers. Lives in
/// `MultiharnessCore` so testable handler logic in this module and the
/// executable target's `RemoteHandlers` can throw the same type.
public enum RemoteError: Error, CustomStringConvertible {
    case bad(String)
    public var description: String {
        switch self {
        case .bad(let m): return m
        }
    }
}

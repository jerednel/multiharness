import Foundation
import Network
import Observation

/// Owns the "expose the sidecar on the LAN" state: persistent toggle, token in
/// Keychain, Bonjour advertisement. Settings UI flips `enabled`; the rest of
/// the wiring (re-launching the sidecar with a new bind/token) is driven by
/// AppEnvironment in response to changes.
@MainActor
@Observable
public final class RemoteAccess {
    /// User-visible toggle. Persisted in the `settings` table.
    public var enabled: Bool {
        didSet {
            persistEnabled()
        }
    }
    /// Bearer token. Generated on first enable, kept in Keychain.
    public private(set) var token: String?
    /// Best-guess primary LAN IP for displaying in the pairing UI.
    public private(set) var lanAddress: String?
    /// True while the Bonjour service is registered.
    public private(set) var advertising: Bool = false
    /// Currently-bound port, mirrored from SidecarManager.
    public var publicPort: Int?

    private let persistence: PersistenceService
    private let keychain: KeychainService
    private let keychainAccount = "remote-access-token"
    private let settingsKey = "remote_access.enabled"

    private var bonjour: NetService?
    private var bonjourDelegate: BonjourDelegate?

    public init(persistence: PersistenceService, keychain: KeychainService) {
        self.persistence = persistence
        self.keychain = keychain
        let stored = (try? persistence.getSetting(self.settingsKey)) ?? "0"
        self.enabled = (stored == "1")
        self.token = (try? keychain.getKey(account: keychainAccount))
        self.lanAddress = Self.primaryLanAddress()
    }

    /// Generate and persist a fresh token. Returns the new value.
    @discardableResult
    public func generateToken() -> String {
        let raw = (0..<24).map { _ in UInt8.random(in: 0...255) }
        let token = Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? keychain.setKey(token, account: keychainAccount)
        self.token = token
        return token
    }

    /// Pairing string the iOS app can scan or paste.
    /// Format: `mh://<host>:<port>?token=<token>&name=<encoded-host-name>`
    public func pairingString(host: String? = nil) -> String? {
        guard let token, let port = publicPort else { return nil }
        let h = host ?? lanAddress ?? "127.0.0.1"
        let name = ProcessInfo.processInfo.hostName
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "mh://\(h):\(port)?token=\(token)&name=\(name)"
    }

    /// Start advertising on Bonjour at the given port. Idempotent.
    /// Uses `NetService` (registration-only; doesn't bind a socket) so it
    /// doesn't conflict with the sidecar's existing TCP listener on the
    /// same port.
    public func startAdvertising(port: Int) {
        stopAdvertising()
        guard enabled else { return }
        let name = ProcessInfo.processInfo.hostName
        let svc = NetService(domain: "", type: "_multiharness._tcp.", name: name, port: Int32(port))
        let delegate = BonjourDelegate(
            onPublished: { [weak self] in Task { @MainActor in self?.advertising = true } },
            onError: { [weak self] err in
                FileHandle.standardError.write(
                    "[remote-access] bonjour error: \(err)\n".data(using: .utf8) ?? Data()
                )
                Task { @MainActor in self?.advertising = false }
            }
        )
        svc.delegate = delegate
        svc.publish()
        self.bonjour = svc
        self.bonjourDelegate = delegate
    }

    public func stopAdvertising() {
        bonjour?.stop()
        bonjour = nil
        bonjourDelegate = nil
        advertising = false
    }

    private func persistEnabled() {
        try? persistence.setSetting(settingsKey, value: enabled ? "1" : "0")
    }

    /// Internal NetService delegate adapter — translates ObjC delegate
    /// callbacks into closure invocations.
    private final class BonjourDelegate: NSObject, NetServiceDelegate {
        let onPublished: () -> Void
        let onError: (String) -> Void
        init(onPublished: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.onPublished = onPublished
            self.onError = onError
        }
        func netServiceDidPublish(_ sender: NetService) { onPublished() }
        func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
            onError(String(describing: errorDict))
        }
    }

    /// Best-effort primary IPv4 on a non-loopback interface (en0/en1).
    public static func primaryLanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            let addr = p.pointee.ifa_addr.pointee
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}

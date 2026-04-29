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

    /// All routable IPv4 interfaces present on the box, ordered with the
    /// best default first (Tailscale > Wi-Fi/Ethernet > anything else).
    public private(set) var interfaces: [NetworkInterface] = []
    /// User-selected interface to advertise in the pairing QR. Persisted.
    public var selectedHost: String? {
        didSet {
            try? persistence.setSetting(selectedHostKey, value: selectedHost ?? "")
        }
    }
    private let selectedHostKey = "remote_access.selected_host"

    public init(persistence: PersistenceService, keychain: KeychainService) {
        self.persistence = persistence
        self.keychain = keychain
        let stored = (try? persistence.getSetting(self.settingsKey)) ?? "0"
        self.enabled = (stored == "1")
        self.token = (try? keychain.getKey(account: keychainAccount))
        self.interfaces = Self.routableInterfaces()
        self.lanAddress = self.interfaces.first?.ipv4
        let savedHost = (try? persistence.getSetting(selectedHostKey)) ?? nil
        if let s = savedHost, !s.isEmpty, interfaces.contains(where: { $0.ipv4 == s }) {
            self.selectedHost = s
        } else {
            // Default: prefer Tailscale, otherwise the first routable interface.
            self.selectedHost = interfaces.first(where: { $0.kind == .tailscale })?.ipv4
                ?? interfaces.first?.ipv4
        }
    }

    /// Re-scan interfaces; call when the user opens the pairing panel.
    public func refreshInterfaces() {
        interfaces = Self.routableInterfaces()
        if let host = selectedHost, !interfaces.contains(where: { $0.ipv4 == host }) {
            selectedHost = interfaces.first(where: { $0.kind == .tailscale })?.ipv4
                ?? interfaces.first?.ipv4
        } else if selectedHost == nil {
            selectedHost = interfaces.first(where: { $0.kind == .tailscale })?.ipv4
                ?? interfaces.first?.ipv4
        }
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
        let h = host ?? selectedHost ?? lanAddress ?? "127.0.0.1"
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

    /// Best-effort primary IPv4 on a non-loopback interface — returns the
    /// first interface from `routableInterfaces()`. Kept as a convenience.
    public static func primaryLanAddress() -> String? {
        routableInterfaces().first?.ipv4
    }

    /// Enumerate all UP, non-loopback IPv4 interfaces on the box, classified
    /// by kind so the pairing UI can label them sensibly. Interfaces are
    /// returned in priority order: Tailscale first (best for cross-network
    /// access), then Wi-Fi/Ethernet (LAN), then everything else.
    public static func routableInterfaces() -> [NetworkInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var found: [NetworkInterface] = []
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            let addr = p.pointee.ifa_addr.pointee
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                        &hostBuf, socklen_t(hostBuf.count),
                        nil, 0, NI_NUMERICHOST)
            let ipv4 = String(cString: hostBuf)
            // Skip link-local (169.254.x) and APIPA-style addresses.
            if ipv4.hasPrefix("169.254.") { continue }
            let kind = NetworkInterface.classify(ifname: name, ipv4: ipv4)
            found.append(NetworkInterface(name: name, ipv4: ipv4, kind: kind))
        }
        return found.sorted { a, b in
            a.kind.priority < b.kind.priority
        }
    }
}

/// A routable network interface present on the host.
public struct NetworkInterface: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case tailscale
        case wifiOrEthernet
        case other

        public var label: String {
            switch self {
            case .tailscale: return "Tailscale"
            case .wifiOrEthernet: return "Wi-Fi / Ethernet"
            case .other: return "Other"
            }
        }

        var priority: Int {
            switch self {
            case .tailscale: return 0
            case .wifiOrEthernet: return 1
            case .other: return 2
            }
        }
    }

    public var id: String { ipv4 }
    public let name: String      // e.g. "en0", "utun4"
    public let ipv4: String      // e.g. "10.0.0.70", "100.110.118.112"
    public let kind: Kind

    public var displayLabel: String {
        "\(kind.label) — \(ipv4)"
    }

    static func classify(ifname: String, ipv4: String) -> Kind {
        // Tailscale uses the 100.64.0.0/10 CGNAT range and its tunnel iface
        // is `utun*` on macOS. Both signals together avoid false-positives.
        if ifname.hasPrefix("utun") {
            let parts = ipv4.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) {
                return .tailscale
            }
            return .other
        }
        if ifname == "en0" || ifname == "en1" || ifname == "en2" {
            return .wifiOrEthernet
        }
        return .other
    }
}

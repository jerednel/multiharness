import Foundation
import Observation
import MultiharnessClient

/// Holds the connection details for a paired Mac. Persisted in the iOS
/// Keychain so the user only pairs once. Toggling forgets the pairing.
@MainActor
@Observable
public final class PairingStore {
    public struct Pairing: Codable, Equatable {
        public var host: String
        public var port: Int
        public var token: String
        public var name: String?
    }

    public private(set) var pairing: Pairing?
    public var connection: ConnectionStore?
    private let keychain = KeychainService(service: "com.multiharness.ios.pairing")
    private let account = "primary"

    public init() {
        self.pairing = loadPairing()
        if let pairing { connect(to: pairing) }
    }

    public func pair(with raw: String) -> Bool {
        guard let p = parsePairingString(raw) else { return false }
        save(pairing: p)
        self.pairing = p
        connect(to: p)
        return true
    }

    public func unpair() {
        connection?.disconnect()
        connection = nil
        pairing = nil
        try? keychain.deleteKey(account: account)
    }

    private func connect(to p: Pairing) {
        connection?.disconnect()
        let conn = ConnectionStore(host: p.host, port: p.port, token: p.token)
        conn.connect()
        self.connection = conn
    }

    private func save(pairing p: Pairing) {
        guard let data = try? JSONEncoder().encode(p),
              let s = String(data: data, encoding: .utf8) else { return }
        try? keychain.setKey(s, account: account)
    }

    private func loadPairing() -> Pairing? {
        guard let s = try? keychain.getKey(account: account),
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    /// Parse a pairing string of the form
    /// `mh://<host>:<port>?token=<token>&name=<host-name>`.
    public func parsePairingString(_ raw: String) -> Pairing? {
        guard let url = URL(string: raw),
              url.scheme == "mh",
              let host = url.host,
              let port = url.port,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let q = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let token = q["token"], !token.isEmpty else { return nil }
        return Pairing(host: host, port: port, token: token, name: q["name"])
    }
}

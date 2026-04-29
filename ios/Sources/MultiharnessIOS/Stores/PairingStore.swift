import Foundation
import Observation
import MultiharnessClient

/// Stores connection details for one or more paired Macs. The list is kept
/// in the iOS Keychain so credentials survive app launches; a separate
/// `activePairingId` tracks which one the app is currently connected to.
@MainActor
@Observable
public final class PairingStore {
    public struct Pairing: Codable, Equatable, Identifiable, Hashable {
        public var id: String       // stable per-Mac id; we generate it
        public var host: String
        public var port: Int
        public var token: String
        public var name: String?
        public var addedAt: Date
    }

    /// Every paired Mac, ordered by addedAt (oldest first). Empty until the
    /// user pairs at least once.
    public private(set) var pairings: [Pairing] = []
    /// The currently selected Mac, if any. Connection always tracks this id.
    public private(set) var activePairingId: String?
    /// Live connection to the active pairing.
    public var connection: ConnectionStore?

    private let keychain = KeychainService(service: "com.multiharness.ios.pairing")
    private let listAccount = "pairings.v2"
    private let activeAccount = "active.v2"
    /// v1 used a single Pairing under the "primary" account. We migrate it
    /// into the list on first launch.
    private let legacyAccount = "primary"

    public init() {
        loadAndMigrate()
        if let id = activePairingId, let p = pairings.first(where: { $0.id == id }) {
            connect(to: p)
        } else if let first = pairings.first {
            // Persisted active id missing/stale — pick the most recent.
            activePairingId = first.id
            connect(to: first)
        }
    }

    public var activePairing: Pairing? {
        guard let id = activePairingId else { return nil }
        return pairings.first(where: { $0.id == id })
    }

    /// Pair a new Mac (or re-pair an existing one — by host:port — with a
    /// fresh token). Returns false on parse failure.
    @discardableResult
    public func pair(with raw: String) -> Bool {
        guard var p = parsePairingString(raw) else { return false }
        // If we already have this host:port, replace it (new token, etc.)
        if let existingIdx = pairings.firstIndex(where: {
            $0.host == p.host && $0.port == p.port
        }) {
            p.id = pairings[existingIdx].id
            p.addedAt = pairings[existingIdx].addedAt
            pairings[existingIdx] = p
        } else {
            pairings.append(p)
        }
        activePairingId = p.id
        savePairings()
        saveActiveId()
        connect(to: p)
        return true
    }

    /// Switch to a previously paired Mac.
    public func activate(_ id: String) {
        guard activePairingId != id, let p = pairings.first(where: { $0.id == id }) else { return }
        activePairingId = id
        saveActiveId()
        connect(to: p)
    }

    /// Forget one paired Mac. If it was active, falls back to another
    /// pairing or no connection at all.
    public func forget(_ id: String) {
        let wasActive = (activePairingId == id)
        pairings.removeAll { $0.id == id }
        savePairings()
        if wasActive {
            connection?.disconnect()
            connection = nil
            if let next = pairings.first {
                activePairingId = next.id
                connect(to: next)
            } else {
                activePairingId = nil
            }
            saveActiveId()
        }
    }

    /// Forget every paired Mac and disconnect.
    public func forgetAll() {
        connection?.disconnect()
        connection = nil
        pairings.removeAll()
        activePairingId = nil
        savePairings()
        saveActiveId()
    }

    private func connect(to p: Pairing) {
        connection?.disconnect()
        let conn = ConnectionStore(host: p.host, port: p.port, token: p.token)
        conn.connect()
        connection = conn
    }

    // MARK: Keychain persistence

    private func loadAndMigrate() {
        if let s = try? keychain.getKey(account: listAccount),
           let data = s.data(using: .utf8),
           let list = try? JSONDecoder().decode([Pairing].self, from: data) {
            pairings = list
        }
        if let s = try? keychain.getKey(account: activeAccount), !s.isEmpty {
            activePairingId = s
        }
        // Migrate v1 single pairing — it lived under "primary" with the
        // old (no-id) Pairing struct shape.
        if pairings.isEmpty,
           let s = try? keychain.getKey(account: legacyAccount),
           let data = s.data(using: .utf8) {
            // Old shape didn't have id/addedAt — decode into a custom shape.
            struct LegacyPairing: Decodable {
                var host: String
                var port: Int
                var token: String
                var name: String?
            }
            if let lp = try? JSONDecoder().decode(LegacyPairing.self, from: data) {
                let migrated = Pairing(
                    id: UUID().uuidString,
                    host: lp.host,
                    port: lp.port,
                    token: lp.token,
                    name: lp.name,
                    addedAt: Date()
                )
                pairings = [migrated]
                activePairingId = migrated.id
                savePairings()
                saveActiveId()
                try? keychain.deleteKey(account: legacyAccount)
            }
        }
    }

    private func savePairings() {
        guard let data = try? JSONEncoder().encode(pairings),
              let s = String(data: data, encoding: .utf8) else { return }
        try? keychain.setKey(s, account: listAccount)
    }

    private func saveActiveId() {
        try? keychain.setKey(activePairingId ?? "", account: activeAccount)
    }

    // MARK: Pairing string parser

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
        return Pairing(
            id: UUID().uuidString,
            host: host,
            port: port,
            token: token,
            name: q["name"],
            addedAt: Date()
        )
    }
}

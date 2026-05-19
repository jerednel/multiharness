import Foundation
import Security

public struct KeychainService: Sendable {
    public let service: String
    private let getKeyImpl: @Sendable (String) throws -> String?
    private let setKeyImpl: @Sendable (String, String) throws -> Void
    private let deleteKeyImpl: @Sendable (String) throws -> Void

    public init(service: String = "com.multiharness.providers") {
        self.service = service
        self.getKeyImpl = { [service] account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
                return nil
            }
            return s
        }
        self.setKeyImpl = { [service] key, account in
            let data = key.data(using: .utf8) ?? Data()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let attrs: [String: Any] = [
                kSecValueData as String: data,
            ]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw KeychainError.osStatus(addStatus)
                }
            } else if status != errSecSuccess {
                throw KeychainError.osStatus(status)
            }
        }
        self.deleteKeyImpl = { [service] account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.osStatus(status)
            }
        }
    }

    public init(
        service: String = "com.multiharness.providers",
        getKey: @escaping @Sendable (String) throws -> String?,
        setKey: @escaping @Sendable (String, String) throws -> Void,
        deleteKey: @escaping @Sendable (String) throws -> Void
    ) {
        self.service = service
        self.getKeyImpl = getKey
        self.setKeyImpl = setKey
        self.deleteKeyImpl = deleteKey
    }

    public func setKey(_ key: String, account: String) throws {
        try setKeyImpl(key, account)
    }

    public func getKey(account: String) throws -> String? {
        try getKeyImpl(account)
    }

    public func deleteKey(account: String) throws {
        try deleteKeyImpl(account)
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case osStatus(OSStatus)
    public var description: String {
        switch self {
        case .osStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        }
    }
}

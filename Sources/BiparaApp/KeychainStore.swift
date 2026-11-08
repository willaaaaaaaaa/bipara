import Foundation
import Security

/// Model-configuration credentials as configuration-scoped generic
/// passwords. Only presence and explicit replace/delete are ever exposed;
/// the stored key is never returned to the UI layer. Reusing the same key
/// value in two configurations creates independent items, so editing or
/// deleting one cannot affect the other.
@MainActor
public protocol CredentialStore: AnyObject {
    func hasKey(configurationID: UUID) -> Bool
    func credential(configurationID: UUID) throws -> String?
    func setKey(_ key: String, configurationID: UUID) throws
    func deleteKey(configurationID: UUID) throws
    /// Legacy provider-scoped item read, used only by the approved
    /// v1→v2 preferences migration.
    func legacyCredential(provider: String) throws -> String?
    /// Legacy provider-scoped item cleanup after verified v2 persistence.
    func deleteLegacyKey(provider: String) throws
}

@MainActor
public final class KeychainStore: CredentialStore {
    public enum KeychainChange: Equatable, Sendable {
        case set(String)
        case delete
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case deleteFailed(OSStatus)
    }

    private let service: String

    /// Production service name. Tests inject their own isolated service.
    /// The service is unchanged from v1 so legacy provider-scoped items
    /// remain readable during migration.
    public init(service: String = "dev.bipara.provider") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Key presence only — never the stored material.
    public func hasKey(configurationID: UUID) -> Bool {
        var query = baseQuery(account: Self.account(for: configurationID))
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads the stored key for model dispatch (never for display).
    public func credential(configurationID: UUID) throws -> String? {
        var query = baseQuery(account: Self.account(for: configurationID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Replaces (or creates) the configuration's key.
    public func setKey(_ key: String, configurationID: UUID) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account: Self.account(for: configurationID)) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account: Self.account(for: configurationID))
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteKey(configurationID: UUID) throws {
        let status = SecItemDelete(baseQuery(account: Self.account(for: configurationID)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: Legacy provider-scoped items (migration only)

    public func legacyCredential(provider: String) throws -> String? {
        var query = baseQuery(account: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func deleteLegacyKey(provider: String) throws {
        let status = SecItemDelete(baseQuery(account: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Applies a draft change; scoped so a failure aborts without
    /// partial-field effects beyond the single configuration entry.
    public func apply(_ change: KeychainChange, configurationID: UUID) throws {
        switch change {
        case .set(let key):
            try setKey(key, configurationID: configurationID)
        case .delete:
            try deleteKey(configurationID: configurationID)
        }
    }

    /// Configuration-scoped account names never collide with the legacy
    /// provider accounts ("openai"/"glm"): a UUID string is never either.
    private static func account(for configurationID: UUID) -> String {
        configurationID.uuidString.lowercased()
    }

    /// Test-only: removes every entry under this store's service.
    public func removeAllForTesting() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

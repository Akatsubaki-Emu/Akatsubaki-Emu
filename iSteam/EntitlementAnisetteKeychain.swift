import Foundation
import Security

final class EntitlementAnisetteKeychain {
    static let shared = EntitlementAnisetteKeychain()
    private let service = Bundle.main.bundleIdentifier ?? "com.xthrx.isteam"

    private init() {}

    func loadIdentifier() throws -> String? { try read("identifier") }
    func loadADIPB() throws -> String? { try read("adiPb") }
    func storeIdentifier(_ value: String?) throws { try write(value, for: "identifier") }
    func storeADIPB(_ value: String?) throws { try write(value, for: "adiPb") }

    private func read(_ key: String) throws -> String? {
        var legacyQuery = baseQuery(for: key)
        legacyQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw keychainError("legacy item cleanup", status: legacyStatus)
        }

        var query = baseQuery(for: key)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError("read", status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AkatsubakiAnisetteKeychain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The stored Anisette Keychain value is invalid."])
        }
        return value
    }

    private func write(_ value: String?, for key: String) throws {
        var legacyQuery = baseQuery(for: key)
        legacyQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw keychainError("legacy item cleanup", status: legacyStatus)
        }

        var query = baseQuery(for: key)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw keychainError("delete", status: deleteStatus)
        }
        guard let value else { return }
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: "AkatsubakiAnisetteKeychain", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The Anisette Keychain value could not be encoded."])
        }

        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw keychainError("update", status: updateStatus) }
        } else if addStatus != errSecSuccess {
            throw keychainError("write", status: addStatus)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func keychainError(_ operation: String, status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Anisette Keychain \(operation) failed (status \(status))."])
    }
}

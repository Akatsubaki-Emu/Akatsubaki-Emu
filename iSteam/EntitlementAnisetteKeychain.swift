import Foundation
import Security

enum EntitlementAnisetteKeychainError: Error, LocalizedError {
    case operationFailed(operation: String, status: OSStatus)
    case invalidStoredValue
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            return "Anisette Keychain " + operation + " failed (OSStatus " + String(status) + ")."
        case .invalidStoredValue:
            return "Anisette Keychain returned an invalid stored value."
        case .invalidValue:
            return "Anisette Keychain could not encode the supplied value."
        }
    }
}

final class EntitlementAnisetteKeychain {
    static let shared = EntitlementAnisetteKeychain()
    private let service = Bundle.main.bundleIdentifier ?? "com.xthrx.isteam"

    private init() {}

    func identifier() throws -> String? { try read("identifier") }
    func setIdentifier(_ value: String?) throws { try write(value, for: "identifier") }
    func adiPb() throws -> String? { try read("adiPb") }
    func setAdiPb(_ value: String?) throws { try write(value, for: "adiPb") }

    private func read(_ key: String) throws -> String? {
        try removeLegacySynchronizableValue(for: key)
        let query = baseQuery(for: key).merging([
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw EntitlementAnisetteKeychainError.invalidStoredValue
            }
            guard let value = String(data: data, encoding: .utf8) else {
                try deleteLocalValue(for: key)
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw EntitlementAnisetteKeychainError.operationFailed(operation: "read", status: status)
        }
    }

    private func write(_ value: String?, for key: String) throws {
        try removeLegacySynchronizableValue(for: key)
        let query = baseQuery(for: key).merging([
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]) { _, new in new }

        guard let value else {
            try deleteLocalValue(for: key)
            return
        }
        guard let data = value.data(using: .utf8) else {
            throw EntitlementAnisetteKeychainError.invalidValue
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw EntitlementAnisetteKeychainError.operationFailed(operation: "update after duplicate add", status: retryStatus)
                }
            } else if addStatus != errSecSuccess {
                throw EntitlementAnisetteKeychainError.operationFailed(operation: "add", status: addStatus)
            }
        default:
            throw EntitlementAnisetteKeychainError.operationFailed(operation: "update", status: updateStatus)
        }
    }

    private func deleteLocalValue(for key: String) throws {
        let query = baseQuery(for: key).merging([
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]) { _, new in new }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EntitlementAnisetteKeychainError.operationFailed(operation: "delete local value", status: status)
        }
    }

    private func removeLegacySynchronizableValue(for key: String) throws {
        let query = baseQuery(for: key).merging([
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]) { _, new in new }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw EntitlementAnisetteKeychainError.operationFailed(operation: "remove legacy synchronizable value", status: status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

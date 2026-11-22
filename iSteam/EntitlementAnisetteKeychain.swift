import Foundation
import Security

final class EntitlementAnisetteKeychain {
    static let shared = EntitlementAnisetteKeychain()

    enum KeychainError: LocalizedError {
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case storeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .readFailed(let status):
                return "Could not read Anisette state from Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Could not clear Anisette state from Keychain (status \(status))."
            case .storeFailed(let status):
                return "Could not store Anisette state in Keychain (status \(status))."
            }
        }
    }

    private let service = Bundle.main.bundleIdentifier ?? "com.xthrx.isteam"

    private init() {}

    func loadIdentifier() throws -> String? { try read("identifier") }
    func loadAdiPb() throws -> String? { try read("adiPb") }
    func storeIdentifier(_ value: String) throws { try write(value, for: "identifier") }
    func storeAdiPb(_ value: String) throws { try write(value, for: "adiPb") }
    func clearIdentifier() throws { try write(nil, for: "identifier") }
    func clearAdiPb() throws { try write(nil, for: "adiPb") }

    private func read(_ key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.readFailed(errSecDecode)
        }
        return value
    }

    private func write(_ value: String?, for key: String) throws {
        var deleteQuery = baseQuery(for: key)
        deleteQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.deleteFailed(deleteStatus)
        }

        guard let value else { return }
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.storeFailed(errSecParam)
        }

        var addQuery = baseQuery(for: key)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.storeFailed(addStatus)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

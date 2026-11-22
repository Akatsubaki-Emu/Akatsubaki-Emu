import Foundation
import Security

final class EntitlementAnisetteKeychain {
    static let shared = EntitlementAnisetteKeychain()

    private let service = Bundle.main.bundleIdentifier ?? "com.xthrx.isteam"

    var identifier: String? {
        get { read("identifier") }
        set { write(newValue, for: "identifier") }
    }

    var adiPb: String? {
        get { read("adiPb") }
        set { write(newValue, for: "adiPb") }
    }

    private init() {}

    private func read(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, for key: String) {
        var query = baseQuery(for: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }
        query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

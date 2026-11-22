import Foundation
import Security

final class EntitlementKeychain {
    static let shared = EntitlementKeychain()
    private let service = Bundle.main.bundleIdentifier ?? "com.xthrx.isteam"

    var identifier: String? {
        get { string(for: "identifier") }
        set { set(newValue, for: "identifier") }
    }
    var adiPb: String? {
        get { string(for: "adiPb") }
        set { set(newValue, for: "adiPb") }
    }

    private init() {}

    private func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func set(_ value: String?, for key: String) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

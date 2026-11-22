import Foundation
import Security

@propertyWrapper
struct KeychainItem {
    let key: String

    var wrappedValue: String? {
        get { Keychain.shared.keychain.string(for: key) }
        set { Keychain.shared.keychain.set(newValue, for: key) }
    }

    init(key: String) {
        self.key = key
    }
}

final class Keychain {
    static let shared = Keychain()
    fileprivate let keychain = SystemKeychain(service: Bundle.main.bundleIdentifier ?? "com.xthrx.isteam")

    @KeychainItem(key: "identifier")
    var identifier: String?

    @KeychainItem(key: "adiPb")
    var adiPb: String?

    private init() {}
}

private struct SystemKeychain {
    let service: String

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) {
        var query = baseQuery(for: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }
        query = baseQuery(for: key)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }
}

import Foundation
import Security

/// Where a password kept out of the account file lives: the macOS Keychain for the app, or
/// something else for tests. Items are generic passwords under the service `com.loopbreak.inverterly`.
public struct PasswordStore: Sendable {
    public var read: @Sendable (_ account: String) -> String?
    public var save: @Sendable (_ password: String, _ account: String) throws -> Void
    public var deleteAll: @Sendable () -> Void

    public init(read: @escaping @Sendable (String) -> String?,
                save: @escaping @Sendable (String, String) throws -> Void,
                deleteAll: @escaping @Sendable () -> Void) {
        self.read = read; self.save = save; self.deleteAll = deleteAll
    }

    static let service = "com.loopbreak.inverterly"

    public static let keychain = PasswordStore(
        read: { account in
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                          kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        },
        save: { password, account in
            let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
            SecItemDelete(item as CFDictionary)
            var add = item
            add[kSecValueData] = Data(password.utf8)
            add[kSecAttrLabel] = "Inverterly"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        },
        deleteAll: {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        })

    /// Keeps nothing and finds nothing.
    public static let none = PasswordStore(read: { _ in nil }, save: { _, _ in }, deleteAll: {})
}

public enum PasswordStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The password could not be saved in the Keychain (\(reason))."
        }
    }
}

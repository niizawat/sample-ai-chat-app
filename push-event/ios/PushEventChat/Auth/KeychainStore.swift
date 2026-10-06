import Foundation
import Security

enum KeychainStore {
    private static let service = "com.example.PushEventChat"

    enum Key: String {
        case accessToken
        case idToken
        case refreshToken
        case username
        case accessTokenExpiresAt
    }

    static func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAll() {
        for key in [Key.accessToken, .idToken, .refreshToken, .username, .accessTokenExpiresAt] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key.rawValue,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    static func save(tokens: CognitoTokens, username: String) {
        set(tokens.accessToken, for: .accessToken)
        set(tokens.idToken, for: .idToken)
        if let refresh = tokens.refreshToken {
            set(refresh, for: .refreshToken)
        }
        set(username, for: .username)
        set(String(tokens.expiresAt.timeIntervalSince1970), for: .accessTokenExpiresAt)
    }
}

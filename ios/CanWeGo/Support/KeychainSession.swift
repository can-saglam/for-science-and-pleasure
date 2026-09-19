import Foundation
import Security

/// Session tokens live in the App Group keychain so the app and the
/// Share Extension share one login, and so a bearer is never sitting in
/// UserDefaults. Access is after first unlock, this device only.
enum KeychainSession {
    private static let service = "com.cansaglam.CanWeGo.session"
    private static let account = "supabase"
    static let signedOutKey = "supabaseSignedOut"

    /// TEAMID.group.com.cansaglam.CanWeGo — both targets list this as
    /// their keychain-access-group so the item is visible to each.
    private static var accessGroup: String? {
        guard let team = teamID else { return nil }
        return "\(team)group.com.cansaglam.CanWeGo"
    }

    private static var teamID: String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "cwg.teamid",
            kSecAttrService as String: "cwg.teamid",
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let team = group.split(separator: ".").first
        else { return nil }
        return String(team) + "."
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    static func load() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data) {
        delete()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

import Foundation
import Security

/// Thin wrapper over the login keychain's generic-password items.
///
/// Uses the same service names and account keys as the Python app (which went
/// through the `security` tool), so credentials already saved there are found.
/// The first read of an item created by `security` makes macOS ask once whether
/// to allow this app; choosing "Always Allow" ends the prompts.
public enum Keychain {
    #if DEBUG
    /// Debug builds can be pointed at a throwaway service so test runs never
    /// touch the real credentials. Compiled out of Release builds.
    public static let service = ProcessInfo.processInfo.environment["JAMFTOOLBOX_KEYCHAIN_SERVICE"]
        ?? "com.jamftoolbox.credentials"
    #else
    public static let service = "com.jamftoolbox.credentials"
    #endif
    /// Pre-rename service; values found here are copied forward on first read.
    #if DEBUG
    public static let legacyService = ProcessInfo.processInfo.environment["JAMFTOOLBOX_KEYCHAIN_SERVICE"].map { $0 + ".legacy" }
        ?? "com.jamfquicktasks.credentials"
    #else
    public static let legacyService = "com.jamfquicktasks.credentials"
    #endif

    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    @discardableResult
    public static func write(service: String, account: String, value: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemAdd(identity.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            return SecItemUpdate(identity as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return false
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

import Foundation

/// Owns `settings.json` and the Keychain-backed secrets.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var prefs: Preferences

    /// False once a Keychain write has failed; secrets then fall back to the
    /// settings file (base64, owner-only permissions) so the app keeps working.
    public private(set) var keychainAvailable = true
    public private(set) var lastSaveError: String?

    /// Folder holding settings.json (and the Audits folder).
    public let directory: URL
    /// When set, secrets live only in this dictionary and the Keychain is never
    /// touched. Used by previews so they can't read real credentials.
    private var memorySecrets: [String: String]?
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    public static let secretAccounts = ["client_id", "client_secret", "username", "password", "meraki_api_key"]

    public init(directory: URL? = nil, inMemorySecrets: [String: String]? = nil) {
        memorySecrets = inMemorySecrets
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = directory
        #if DEBUG
        // Debug builds can use a scratch folder so test runs never touch real settings.
        if directory == nil, let override = ProcessInfo.processInfo.environment["JAMFTOOLBOX_SUPPORT_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        self.directory = directory ?? support.appendingPathComponent("JamfToolbox", isDirectory: true)

        if directory == nil {
            Self.migrateLegacyDirectory(into: self.directory, parent: support)
        }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("settings.json")) {
            prefs = Preferences.decode(from: data)
        } else {
            prefs = Preferences()
        }
    }

    /// One-time move of settings from the app's pre-rename folder.
    private static func migrateLegacyDirectory(into directory: URL, parent: URL) {
        let legacy = parent.appendingPathComponent("JamfQuickTasks", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: directory.path) {
            try? fm.moveItem(at: legacy, to: directory)
        }
    }

    // MARK: Persistence

    @discardableResult
    public func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try prefs.encoded().write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error.localizedDescription
            return false
        }
    }

    // MARK: Secrets

    public func secret(_ account: String) -> String {
        if let memorySecrets { return memorySecrets[account] ?? "" }
        for service in [Keychain.service, Keychain.legacyService] {
            if let value = Keychain.read(service: service, account: account) {
                if service == Keychain.legacyService { setSecret(account, value) }  // migrate forward
                return value
            }
        }
        if let blob = prefs.credentialsInFile[account],
           let data = Data(base64Encoded: blob) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    /// Returns true when the value went to the Keychain.
    @discardableResult
    public func setSecret(_ account: String, _ value: String) -> Bool {
        if memorySecrets != nil {
            memorySecrets?[account] = value.isEmpty ? nil : value
            return true
        }
        if value.isEmpty {
            // Nothing to store; clear any previous value everywhere.
            Keychain.delete(service: Keychain.service, account: account)
            prefs.credentialsInFile[account] = nil
            return true
        }
        if Keychain.write(service: Keychain.service, account: account, value: value) {
            prefs.credentialsInFile[account] = nil  // no stale fallback copy
            keychainAvailable = true
            return true
        }
        keychainAvailable = false
        prefs.credentialsInFile[account] = Data(value.utf8).base64EncodedString()
        return false
    }

    public func credentials(for method: AuthMethod) -> (String, String) {
        switch method {
        case .oauth: return (secret("client_id"), secret("client_secret"))
        case .basic: return (secret("username"), secret("password"))
        }
    }
}

import Foundation

/// Everything the Settings screen edits. Changes stay in this draft until Save,
/// so Cancel (or just closing Settings) discards them and credentials only
/// reach the Keychain when the user commits.
public struct SettingsDraft: Equatable {
    public var jamfURL = ""
    public var authMethod = AuthMethod.basic
    public var oauthID = ""
    public var oauthSecret = ""
    public var basicUser = ""
    public var basicPassword = ""
    public var verifyNotes = true
    public var doubleClickAction = DeviceAction.openInJamf
    public var sslVerify = true
    public var caBundle = ""
    public var lostModePresets: [LostModePreset] = Preferences().lostModePresets
    public var lostModeSound = true
    public var namePresets: [NamePreset] = Preferences().namePresets
    public var lockPresets: [LockPreset] = Preferences().lockPresets
    public var merakiKey = ""

    @MainActor
    public init(settings: SettingsStore) {
        let p = settings.prefs
        jamfURL = p.jamfURL
        authMethod = p.authMethod
        oauthID = settings.secret("client_id")
        oauthSecret = settings.secret("client_secret")
        basicUser = settings.secret("username")
        basicPassword = settings.secret("password")
        verifyNotes = p.verifyNotes
        doubleClickAction = p.doubleClickAction
        sslVerify = p.sslVerify
        caBundle = p.sslCABundle
        lostModePresets = p.lostModePresets
        lostModeSound = p.lostModeSound
        namePresets = p.namePresets
        lockPresets = p.lockPresets
        merakiKey = settings.secret("meraki_api_key")
    }

    public init() {}

    public var credentials: (String, String) {
        authMethod == .oauth ? (oauthID, oauthSecret) : (basicUser, basicPassword)
    }

    /// A client for Test Connection, built from the unsaved values.
    /// Fails (with the reason) when there is no URL yet.
    public func testClient() -> Result<JamfClient, ServiceError> {
        let url = jamfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .failure(ServiceError("Enter the Jamf Pro server URL first.")) }
        let (a, b) = credentials
        return .success(JamfClient(baseURL: url, authMethod: authMethod,
                                   credentialA: a.trimmingCharacters(in: .whitespacesAndNewlines), credentialB: b,
                                   tls: TLSPolicy(verify: sslVerify,
                                                  caBundlePath: caBundle.trimmingCharacters(in: .whitespaces))))
    }

    /// Saves the draft. `loaded` is the draft as first shown, so only secrets
    /// the user actually changed touch the Keychain. Returns a problem to show
    /// instead of saving, or nil once saved.
    @MainActor
    public func commit(to model: AppModel, loaded: SettingsDraft) -> String? {
        let url = jamfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.isEmpty || url.lowercased().hasPrefix("https://") else {
            return "The Jamf Pro URL should start with https://"
        }
        let settings = model.settings
        var p = settings.prefs
        var trimmedURL = url
        while trimmedURL.hasSuffix("/") { trimmedURL.removeLast() }
        p.jamfURL = trimmedURL
        p.authMethod = authMethod
        p.verifyNotes = verifyNotes
        p.doubleClickAction = doubleClickAction
        p.sslVerify = sslVerify
        p.sslCABundle = caBundle.trimmingCharacters(in: .whitespaces)
        func cleanName(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }
        p.lostModePresets = lostModePresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.message = preset.message.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.phone = preset.phone.trimmingCharacters(in: .whitespaces)
            clean.footnote = preset.footnote.trimmingCharacters(in: .whitespaces)
            return clean
        }
        p.lostModeSound = lostModeSound
        p.namePresets = namePresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.template = preset.template.trimmingCharacters(in: .whitespaces)
            return clean
        }
        p.lockPresets = lockPresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.message = preset.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean
        }
        settings.prefs = p

        // Only touch the Keychain for secrets the user actually changed.
        func store(_ account: String, _ new: String, _ old: String, trim: Bool = false) {
            let value = trim ? new.trimmingCharacters(in: .whitespacesAndNewlines) : new
            if value != old { settings.setSecret(account, value) }
        }
        store("client_id", oauthID, loaded.oauthID, trim: true)
        store("client_secret", oauthSecret, loaded.oauthSecret)
        store("username", basicUser, loaded.basicUser, trim: true)
        store("password", basicPassword, loaded.basicPassword)
        store("meraki_api_key", merakiKey, loaded.merakiKey, trim: true)

        model.persist()
        model.settingsSaved()
        return nil
    }
}

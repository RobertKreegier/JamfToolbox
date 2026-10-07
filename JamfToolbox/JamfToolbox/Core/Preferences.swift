import Foundation

enum AuthMethod: String {
    case oauth   // API client (client ID + secret)
    case basic   // user account
}

/// Everything persisted to `settings.json`.
///
/// The file location, key names and value shapes are identical to the Python
/// app's, so someone upgrading keeps their settings and saved device lists.
/// Secrets are *not* part of this file; they live in the Keychain.
struct Preferences: Codable {
    var jamfURL = ""
    var authMethod = AuthMethod.basic
    var verifyNotes = true
    var sslVerify = true
    var sslCABundle = ""
    var lostModeMessage = "{name} - (Lost Mode: Please return to tech desk to disable lost mode)"
    var lostModePhone = ""
    var lostModeFootnote = "Property of Rock Ridge Public Schools"
    var lostModeSound = true
    var renameFormatComputer = "{realname} - {serial}"
    var renameFormatMobile = "{realname} - {username} - {serial}"
    var doubleClickAction = DeviceAction.openInJamf
    /// nil means "use the default column set".
    var listColumns: [String]?
    var lockMessage = "This device has been locked by RRPS Tech Department. Please contact tech@rrps.org or bring to tech desk to remove lock."
    var deviceListComputer: [DeviceEntry] = []
    var deviceListMobile: [DeviceEntry] = []
    var merakiOrgID = ""
    var merakiOrgName = ""
    var merakiNetworkID = ""
    var merakiNetworkName = ""
    /// Fallback only: base64 secrets used when the Keychain can't be written.
    var credentialsInFile: [String: String] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jamfURL = "jamf_url"
        case authMethod = "auth_method"
        case verifyNotes = "verify_notes"
        case sslVerify = "ssl_verify"
        case sslCABundle = "ssl_ca_bundle"
        case lostModeMessage = "lost_mode_message"
        case lostModePhone = "lost_mode_phone"
        case lostModeFootnote = "lost_mode_footnote"
        case lostModeSound = "lost_mode_sound"
        case renameFormatComputer = "rename_format_computer"
        case renameFormatMobile = "rename_format_mobile"
        case doubleClickAction = "double_click_action"
        case listColumns = "list_columns"
        case lockMessage = "lock_message"
        case deviceListComputer = "device_list_computer"
        case deviceListMobile = "device_list_mobile"
        case merakiOrgID = "meraki_org_id"
        case merakiOrgName = "meraki_org_name"
        case merakiNetworkID = "meraki_network_id"
        case merakiNetworkName = "meraki_network_name"
        case credentialsInFile = "credentials_in_file"
        case legacyRenameFormat = "rename_format"
    }

    init() {}

    /// Missing or mistyped keys fall back to defaults one at a time, so a file
    /// from an older (or newer) version never prevents launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        jamfURL = value(.jamfURL, jamfURL)
        authMethod = AuthMethod(rawValue: value(.authMethod, authMethod.rawValue)) ?? authMethod
        verifyNotes = value(.verifyNotes, verifyNotes)
        sslVerify = value(.sslVerify, sslVerify)
        sslCABundle = value(.sslCABundle, sslCABundle)
        lostModeMessage = value(.lostModeMessage, lostModeMessage)
        lostModePhone = value(.lostModePhone, lostModePhone)
        lostModeFootnote = value(.lostModeFootnote, lostModeFootnote)
        lostModeSound = value(.lostModeSound, lostModeSound)
        renameFormatComputer = value(.renameFormatComputer, renameFormatComputer)
        renameFormatMobile = value(.renameFormatMobile, renameFormatMobile)
        doubleClickAction = DeviceAction(rawValue: value(.doubleClickAction, doubleClickAction.rawValue)) ?? doubleClickAction
        listColumns = (try? c.decodeIfPresent([String].self, forKey: .listColumns)) ?? nil
        lockMessage = value(.lockMessage, lockMessage)
        deviceListComputer = value(.deviceListComputer, deviceListComputer)
        deviceListMobile = value(.deviceListMobile, deviceListMobile)
        merakiOrgID = value(.merakiOrgID, merakiOrgID)
        merakiOrgName = value(.merakiOrgName, merakiOrgName)
        merakiNetworkID = value(.merakiNetworkID, merakiNetworkID)
        merakiNetworkName = value(.merakiNetworkName, merakiNetworkName)
        credentialsInFile = value(.credentialsInFile, credentialsInFile)

        // The single rename format became per-type templates. The legacy value
        // was written for mobile devices, so carry it there.
        let hasMobileFormat = c.contains(.renameFormatMobile)
        if !hasMobileFormat, let legacy = (try? c.decodeIfPresent(String.self, forKey: .legacyRenameFormat)) ?? nil {
            renameFormatMobile = legacy
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jamfURL, forKey: .jamfURL)
        try c.encode(authMethod.rawValue, forKey: .authMethod)
        try c.encode(verifyNotes, forKey: .verifyNotes)
        try c.encode(sslVerify, forKey: .sslVerify)
        try c.encode(sslCABundle, forKey: .sslCABundle)
        try c.encode(lostModeMessage, forKey: .lostModeMessage)
        try c.encode(lostModePhone, forKey: .lostModePhone)
        try c.encode(lostModeFootnote, forKey: .lostModeFootnote)
        try c.encode(lostModeSound, forKey: .lostModeSound)
        try c.encode(renameFormatComputer, forKey: .renameFormatComputer)
        try c.encode(renameFormatMobile, forKey: .renameFormatMobile)
        try c.encode(doubleClickAction.rawValue, forKey: .doubleClickAction)
        try c.encode(listColumns, forKey: .listColumns)
        try c.encode(lockMessage, forKey: .lockMessage)
        try c.encode(deviceListComputer, forKey: .deviceListComputer)
        try c.encode(deviceListMobile, forKey: .deviceListMobile)
        try c.encode(merakiOrgID, forKey: .merakiOrgID)
        try c.encode(merakiOrgName, forKey: .merakiOrgName)
        try c.encode(merakiNetworkID, forKey: .merakiNetworkID)
        try c.encode(merakiNetworkName, forKey: .merakiNetworkName)
        try c.encode(credentialsInFile, forKey: .credentialsInFile)
    }

    // MARK: Convenience

    func deviceList(for type: DeviceType) -> [DeviceEntry] {
        type == .computer ? deviceListComputer : deviceListMobile
    }

    mutating func setDeviceList(_ list: [DeviceEntry], for type: DeviceType) {
        if type == .computer { deviceListComputer = list } else { deviceListMobile = list }
    }

    func renameFormat(for type: DeviceType) -> String {
        type == .computer ? renameFormatComputer : renameFormatMobile
    }

    /// The user's chosen columns, validated against the catalog.
    var visibleColumns: [ColumnField] {
        let chosen = (listColumns ?? []).compactMap(ColumnField.init(rawValue:))
        return chosen.isEmpty ? ColumnField.defaults : chosen
    }

    static func decode(from data: Data) -> Preferences {
        (try? JSONDecoder().decode(Preferences.self, from: data)) ?? Preferences()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

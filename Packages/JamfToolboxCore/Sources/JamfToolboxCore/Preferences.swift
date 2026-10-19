import Foundation

public enum AuthMethod: String {
    case oauth   // API client (client ID + secret)
    case basic   // user account
}

/// A saved set of Lost Mode text. Fields may contain `{tags}`.
public struct LostModePreset: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var message: String
    public var phone = ""
    public var footnote = ""

    public init(name: String, message: String, phone: String = "", footnote: String = "") {
        self.name = name
        self.message = message
        self.phone = phone
        self.footnote = footnote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        phone = (try? c.decode(String.self, forKey: .phone)) ?? ""
        footnote = (try? c.decode(String.self, forKey: .footnote)) ?? ""
    }
}

/// A saved lock-screen message. May contain `{tags}`.
public struct LockPreset: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
    }
}

/// A saved device-name template, usable for computers and mobile devices alike.
public struct NamePreset: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var template: String

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        template = (try? c.decode(String.self, forKey: .template)) ?? ""
    }
}

/// Everything persisted to `settings.json`.
///
/// The file location, key names and value shapes are identical to the Python
/// app's, so someone upgrading keeps their settings and saved device lists.
/// Secrets are *not* part of this file; they live in the Keychain.
public struct Preferences: Codable {
    public var jamfURL = ""
    public var authMethod = AuthMethod.basic
    public var verifyNotes = true
    public var sslVerify = true
    public var sslCABundle = ""
    /// The first preset is the default. Never empty.
    public var lostModePresets = [LostModePreset(name: "Default",
                                          message: "{name} - (Lost Mode: Please return this device to your IT department)",
                                          footnote: "")]
    public var lostModeSound = true
    /// Device-name templates for Rename; the first is the default. Never empty.
    public var namePresets = [NamePreset(name: "Default", template: Preferences.defaultNameTemplate)]
    public static let defaultNameTemplate = "{realname} - {username} - {serial}"
    public var doubleClickAction = DeviceAction.openInJamf
    /// nil means "use the default column set".
    public var listColumns: [String]?
    /// The first preset is the default. Never empty.
    public var lockPresets = [LockPreset(name: "Default",
                                  message: "This device has been locked by your IT department. Please contact them to unlock it.")]
    public var deviceListComputer: [DeviceEntry] = []
    public var deviceListMobile: [DeviceEntry] = []
    public var merakiOrgID = ""
    public var merakiOrgName = ""
    public var merakiNetworkID = ""
    public var merakiNetworkName = ""
    /// Fallback only: base64 secrets used when the Keychain can't be written.
    public var credentialsInFile: [String: String] = [:]

    public enum CodingKeys: String, CodingKey, CaseIterable {
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
        case lostModePresets = "lost_mode_presets"
        case lockPresets = "lock_message_presets"
        case namePresets = "rename_presets"
    }

    public init() {}

    /// Missing or mistyped keys fall back to defaults one at a time, so a file
    /// from an older (or newer) version never prevents launch.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        jamfURL = value(.jamfURL, jamfURL)
        authMethod = AuthMethod(rawValue: value(.authMethod, authMethod.rawValue)) ?? authMethod
        verifyNotes = value(.verifyNotes, verifyNotes)
        sslVerify = value(.sslVerify, sslVerify)
        sslCABundle = value(.sslCABundle, sslCABundle)
        // Presets are newer than the single-message keys. Without saved presets,
        // the single message (Python app, or earlier versions) becomes the default.
        let defaults = Preferences()
        let presets = ((try? c.decodeIfPresent([LostModePreset].self, forKey: .lostModePresets)) ?? nil) ?? []
        lostModePresets = presets.isEmpty
            ? [LostModePreset(name: "Default",
                              message: value(.lostModeMessage, defaults.lostModePresets[0].message),
                              phone: value(.lostModePhone, defaults.lostModePresets[0].phone),
                              footnote: value(.lostModeFootnote, defaults.lostModePresets[0].footnote))]
            : presets
        lostModeSound = value(.lostModeSound, lostModeSound)
        // Name presets replaced the per-type formats. Without saved presets,
        // start from the default and keep any earlier format that differs.
        let names = ((try? c.decodeIfPresent([NamePreset].self, forKey: .namePresets)) ?? nil) ?? []
        if names.isEmpty {
            var migrated = [NamePreset(name: "Default", template: Preferences.defaultNameTemplate)]
            func keep(_ key: CodingKeys, as label: String) {
                guard let format = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil else { return }
                let trimmed = format.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !migrated.contains(where: { $0.template == trimmed }) {
                    migrated.append(NamePreset(name: label, template: trimmed))
                }
            }
            keep(.renameFormatComputer, as: "Previous computer format")
            keep(.renameFormatMobile, as: "Previous mobile format")
            keep(.legacyRenameFormat, as: "Previous mobile format")
            namePresets = migrated
        } else {
            namePresets = names
        }
        doubleClickAction = DeviceAction(rawValue: value(.doubleClickAction, doubleClickAction.rawValue)) ?? doubleClickAction
        listColumns = (try? c.decodeIfPresent([String].self, forKey: .listColumns)) ?? nil
        let locks = ((try? c.decodeIfPresent([LockPreset].self, forKey: .lockPresets)) ?? nil) ?? []
        lockPresets = locks.isEmpty
            ? [LockPreset(name: "Default", message: value(.lockMessage, defaults.lockPresets[0].message))]
            : locks
        deviceListComputer = value(.deviceListComputer, deviceListComputer)
        deviceListMobile = value(.deviceListMobile, deviceListMobile)
        merakiOrgID = value(.merakiOrgID, merakiOrgID)
        merakiOrgName = value(.merakiOrgName, merakiOrgName)
        merakiNetworkID = value(.merakiNetworkID, merakiNetworkID)
        merakiNetworkName = value(.merakiNetworkName, merakiNetworkName)
        credentialsInFile = value(.credentialsInFile, credentialsInFile)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jamfURL, forKey: .jamfURL)
        try c.encode(authMethod.rawValue, forKey: .authMethod)
        try c.encode(verifyNotes, forKey: .verifyNotes)
        try c.encode(sslVerify, forKey: .sslVerify)
        try c.encode(sslCABundle, forKey: .sslCABundle)
        try c.encode(lostModePresets, forKey: .lostModePresets)
        // The default preset also goes under the original single-message keys,
        // which older versions (and the Python app) read.
        try c.encode(defaultLostMode.message, forKey: .lostModeMessage)
        try c.encode(defaultLostMode.phone, forKey: .lostModePhone)
        try c.encode(defaultLostMode.footnote, forKey: .lostModeFootnote)
        try c.encode(lostModeSound, forKey: .lostModeSound)
        try c.encode(namePresets, forKey: .namePresets)
        // Older versions (and the Python app) read one format per device type.
        try c.encode(defaultName.template, forKey: .renameFormatComputer)
        try c.encode(defaultName.template, forKey: .renameFormatMobile)
        try c.encode(doubleClickAction.rawValue, forKey: .doubleClickAction)
        try c.encode(listColumns, forKey: .listColumns)
        try c.encode(lockPresets, forKey: .lockPresets)
        try c.encode(defaultLock.message, forKey: .lockMessage)
        try c.encode(deviceListComputer, forKey: .deviceListComputer)
        try c.encode(deviceListMobile, forKey: .deviceListMobile)
        try c.encode(merakiOrgID, forKey: .merakiOrgID)
        try c.encode(merakiOrgName, forKey: .merakiOrgName)
        try c.encode(merakiNetworkID, forKey: .merakiNetworkID)
        try c.encode(merakiNetworkName, forKey: .merakiNetworkName)
        try c.encode(credentialsInFile, forKey: .credentialsInFile)
    }

    // MARK: Convenience

    public var defaultLostMode: LostModePreset { lostModePresets.first ?? Preferences().lostModePresets[0] }
    public var defaultLock: LockPreset { lockPresets.first ?? Preferences().lockPresets[0] }

    public func deviceList(for type: DeviceType) -> [DeviceEntry] {
        type == .computer ? deviceListComputer : deviceListMobile
    }

    public mutating func setDeviceList(_ list: [DeviceEntry], for type: DeviceType) {
        if type == .computer { deviceListComputer = list } else { deviceListMobile = list }
    }

    public var defaultName: NamePreset { namePresets.first ?? Preferences().namePresets[0] }

    /// The user's chosen columns, validated against the catalog.
    public var visibleColumns: [ColumnField] {
        let chosen = (listColumns ?? []).compactMap(ColumnField.init(rawValue:))
        return chosen.isEmpty ? ColumnField.defaults : chosen
    }

    public static func decode(from data: Data) -> Preferences {
        (try? JSONDecoder().decode(Preferences.self, from: data)) ?? Preferences()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

import Foundation

enum DeviceType: String, CaseIterable, Identifiable {
    case computer
    case mobile

    var id: String { rawValue }
    var pluralName: String { self == .computer ? "computers" : "mobile devices" }
    var exportName: String { self == .computer ? "Computers" : "Mobile Devices" }
}

/// Every field a device row can display, in catalog order. Raw values match
/// the Python app's field names so saved settings carry over unchanged.
///
/// Saved list entries carry *all* of these fields, so changing which columns
/// are shown never requires a refetch.
enum ColumnField: String, CaseIterable, Identifiable {
    case name
    case serial
    case username
    case realname
    case email
    case position
    case department
    case building
    case room
    case phone
    case assetTag = "asset_tag"
    case wifiMAC = "wifi_mac"
    case ip
    case model
    case modelShort = "model_short"
    case serialLast4 = "serial_last4"
    case osVersion = "os_version"
    case udid
    case lastInventory = "last_inventory"
    case deviceID = "device_id"

    var id: String { rawValue }

    var heading: String {
        switch self {
        case .name: return "Name"
        case .serial: return "Serial"
        case .username: return "Username"
        case .realname: return "Full Name"
        case .email: return "Email"
        case .position: return "Position"
        case .department: return "Department"
        case .building: return "Building"
        case .room: return "Room"
        case .phone: return "Phone"
        case .assetTag: return "Asset Tag"
        case .wifiMAC: return "Wi-Fi MAC"
        case .ip: return "IP address"
        case .model: return "Model"
        case .modelShort: return "Model (short)"
        case .serialLast4: return "Serial (last 4)"
        case .osVersion: return "OS Version"
        case .udid: return "UDID"
        case .lastInventory: return "Last Inventory"
        case .deviceID: return "Jamf ID"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 170
        case .serial: return 115
        case .username: return 100
        case .realname: return 140
        case .email: return 170
        case .position: return 120
        case .department: return 120
        case .building: return 110
        case .room: return 70
        case .phone: return 110
        case .assetTag: return 100
        case .wifiMAC: return 130
        case .ip: return 110
        case .model: return 160
        case .modelShort: return 110
        case .serialLast4: return 90
        case .osVersion: return 90
        case .udid: return 230
        case .lastInventory: return 150
        case .deviceID: return 70
        }
    }

    /// The out-of-the-box column set (also what "Reset to Default Columns" restores).
    static let defaults: [ColumnField] = [.name, .serial, .username, .wifiMAC, .ip, .model]
}

/// One row of a saved working list.
///
/// Stored as a flat JSON object (`{"id": "12", "name": "…", "serial": "…"}`)
/// exactly like the Python app wrote it, so existing settings files load as-is.
struct DeviceEntry: Codable, Equatable, Identifiable {
    var id: String
    var fields: [String: String]

    init(id: String, fields: [String: String] = [:]) {
        self.id = id
        self.fields = fields
    }

    func value(_ field: ColumnField) -> String { fields[field.rawValue] ?? "" }

    mutating func setValue(_ value: String, for field: ColumnField) {
        fields[field.rawValue] = value
    }

    /// Display name for logs and prompts: name, else serial, else the Jamf ID.
    var displayName: String {
        let name = value(.name)
        if !name.isEmpty { return name }
        let serial = value(.serial)
        return serial.isEmpty ? id : serial
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var id = ""
        var fields: [String: String] = [:]
        for key in container.allKeys {
            // Be forgiving about scalar types; older files held ids as strings
            // but nothing guarantees it.
            let text: String
            if let s = try? container.decode(String.self, forKey: key) {
                text = s
            } else if let i = try? container.decode(Int.self, forKey: key) {
                text = String(i)
            } else if let d = try? container.decode(Double.self, forKey: key) {
                text = String(d)
            } else if let b = try? container.decode(Bool.self, forKey: key) {
                text = b ? "true" : "false"
            } else {
                continue
            }
            if key.stringValue == "id" { id = text } else { fields[key.stringValue] = text }
        }
        guard !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Device entry has no id"))
        }
        self.id = id
        self.fields = fields
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: Key(stringValue: "id"))
        for field in ColumnField.allCases {
            try container.encode(value(field), forKey: Key(stringValue: field.rawValue))
        }
    }
}

/// The actions a device can take. Raw values are the Python method names, which
/// is what the shared settings file stores for the double-click action.
enum DeviceAction: String, CaseIterable, Identifiable {
    case showInfo = "action_show_info"
    case networkInfo = "action_meraki_info"
    case toggleLostMode = "action_toggle_lost_mode"
    case lock = "action_lock"
    case rename = "action_rename"
    case updateInventory = "action_update_inventory"
    case openInJamf = "action_open_in_jamf"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .showInfo: return "Show Info"
        case .networkInfo: return "Network Info"
        case .toggleLostMode: return "Toggle Lost Mode"
        case .lock: return "Lock Device"
        case .rename: return "Rename Device"
        case .updateInventory: return "Update Inventory"
        case .openInJamf: return "Open in Jamf Pro"
        }
    }

    /// Jamf has no remote command for these on a Mac, so they are shown
    /// disabled (not removed) for computers to keep the menu layout stable.
    var mobileOnly: Bool { self == .toggleLostMode || self == .updateInventory }

    var supportsBulk: Bool {
        switch self {
        case .toggleLostMode, .lock, .rename, .openInJamf: return true
        default: return false
        }
    }

    /// Actions that open a prompt first get an ellipsis in menus.
    var needsEllipsis: Bool { self == .toggleLostMode || self == .lock || self == .rename }

    var symbolName: String {
        switch self {
        case .showInfo: return "info.circle"
        case .networkInfo: return "wifi"
        case .toggleLostMode: return "location.slash"
        case .lock: return "lock"
        case .rename: return "pencil"
        case .updateInventory: return "arrow.triangle.2.circlepath"
        case .openInJamf: return "safari"
        }
    }

    func isAvailable(for type: DeviceType) -> Bool { !mobileOnly || type == .mobile }
}

import Foundation

public typealias TagValues = [String: String]

public enum Templates {
    /// Tags offered in Settings and Help, in display order.
    public static let tagDescriptions: [(tag: String, description: String)] = [
        ("{name}", "Current device name in Jamf Pro"),
        ("{username}", "Assigned username (Location > Username)"),
        ("{realname}", "Assigned user's full name"),
        ("{email}", "Assigned user's email address"),
        ("{position}", "Assigned user's job title / position"),
        ("{department}", "Department from the device record"),
        ("{building}", "Building from the device record"),
        ("{room}", "Room from the device record"),
        ("{phone}", "Assigned user's phone number"),
        ("{serial}", "Device serial number"),
        ("{serial_last4}", "Last 4 characters of the serial number"),
        ("{asset_tag}", "Asset tag from the device record"),
        ("{model}", "Full model name (e.g. MacBook Pro 14-inch)"),
        ("{model_short}", "Condensed model name, no spaces (e.g. MacBookPro)"),
        ("{wifi_mac}", "Wi-Fi MAC address (primary MAC for computers)"),
        ("{ip}", "Last reported IP address"),
        ("{os_version}", "Operating system version"),
        ("{udid}", "Device UDID"),
        ("{last_inventory}", "When the device last submitted inventory"),
        ("{device_id}", "The device's Jamf Pro ID"),
        ("{date}", "Today's date (YYYY-MM-DD)"),
        ("{time}", "Current time (HH:MM)"),
    ]

    private static let tagPattern = try! NSRegularExpression(pattern: "\\{([a-z_0-9]+)\\}")

    /// Substitute `{tags}`; unknown tags are left as-is so typos stay visible.
    public static func render(_ template: String, _ values: TagValues) -> String {
        let ns = template as NSString
        var result = ""
        var cursor = 0
        for match in tagPattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = ns.substring(with: match.range(at: 1))
            result += values[key] ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Flatten a classic-API device record into tag values.
    public static func buildTagValues(record: JSONValue, type: DeviceType, deviceID: String,
                               now: Date = Date()) -> TagValues {
        let general = record["general"] ?? .emptyObject
        let location = record["location"] ?? .emptyObject
        let hardware = record["hardware"] ?? .emptyObject

        func text(_ section: JSONValue, _ key: String) -> String { section[key]?.text ?? "" }
        func first(_ values: String...) -> String { values.first { !$0.isEmpty } ?? "" }

        let name: String, model: String, wifiMAC: String, ip: String, osVersion: String, lastInventory: String
        switch type {
        case .computer:
            name = text(general, "name")
            model = text(hardware, "model")
            wifiMAC = text(general, "mac_address")
            ip = first(text(general, "last_reported_ip"), text(general, "ip_address"))
            osVersion = text(hardware, "os_version")
            lastInventory = text(general, "report_date")
        case .mobile:
            name = first(text(general, "display_name"), text(general, "name"))
            model = first(text(general, "model"), text(general, "model_display"))
            wifiMAC = text(general, "wifi_mac_address")
            ip = text(general, "ip_address")
            osVersion = text(general, "os_version")
            lastInventory = text(general, "last_inventory_update")
        }

        let serial = text(general, "serial_number")
        let modelHead = model.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let modelShort = String(modelHead.unicodeScalars.filter {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        })

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        return [
            "name": name,
            "username": text(location, "username"),
            "realname": first(text(location, "realname"), text(location, "real_name")),
            "email": text(location, "email_address"),
            "position": text(location, "position"),
            "department": text(location, "department"),
            "building": text(location, "building"),
            "room": text(location, "room"),
            "phone": first(text(location, "phone"), text(location, "phone_number")),
            "serial": serial,
            "serial_last4": String(serial.suffix(4)),
            "asset_tag": text(general, "asset_tag"),
            "model": model,
            "model_short": modelShort,
            "wifi_mac": wifiMAC,
            "ip": ip,
            "os_version": osVersion,
            "udid": text(general, "udid"),
            "last_inventory": lastInventory,
            "device_id": deviceID,
            "date": dateFormatter.string(from: now),
            "time": timeFormatter.string(from: now),
        ]
    }

    /// A working-list entry carrying every catalog field, from a full record.
    public static func entry(from record: JSONValue, type: DeviceType, deviceID: String) -> DeviceEntry {
        let tags = buildTagValues(record: record, type: type, deviceID: deviceID)
        var entry = DeviceEntry(id: deviceID)
        for field in ColumnField.allCases {
            entry.fields[field.rawValue] = tags[field.rawValue] ?? ""
        }
        return entry
    }

    /// A mobile device's current Lost Mode state, or nil when the record doesn't say.
    ///
    /// Jamf reports this in slightly different places and spellings depending on
    /// version, so several keys are checked.
    public static func lostModeEnabled(in record: JSONValue) -> Bool? {
        let sections = [record["general"], record["security"], record["mobile_device_lost_mode"]]
        let keys = ["lost_mode_enabled", "lost_mode_enable", "lost_mode_enforced",
                    "lost_mode_status", "lost_mode"]
        for case let section? in sections {
            guard case .object = section else { continue }
            for key in keys {
                guard let value = section[key] else { continue }
                switch value {
                case .bool(let b):
                    return b
                case .string(let s):
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return ["true", "yes", "on", "enabled"].contains(trimmed.lowercased())
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }
}

/// Meraki hands back MACs in whatever format Jamf stored; its API wants `aa:bb:cc:dd:ee:ff`.
public func normalizeMAC(_ mac: String) -> String {
    let hex = mac.filter { $0.isHexDigit }
    guard hex.count == 12 else { return mac.trimmingCharacters(in: .whitespaces).lowercased() }
    var parts: [String] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        parts.append(String(hex[index..<next]))
        index = next
    }
    return parts.joined(separator: ":").lowercased()
}

/// Meraki timestamps arrive as ISO 8601 or epoch seconds; show them in local time.
public func friendlyTimestamp(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    let date: Date?
    switch value {
    case .number(let n):
        date = Double(n).map { Date(timeIntervalSince1970: $0) }
    case .string(let s):
        if s.isEmpty { return "" }
        date = parseISO8601(s)
        if date == nil { return s }
    default:
        return ""
    }
    guard let date else { return value.text }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

public func parseISO8601(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

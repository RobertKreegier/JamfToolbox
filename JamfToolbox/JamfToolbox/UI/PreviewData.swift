#if DEBUG
import Foundation

/// Sample data for SwiftUI previews.
///
/// Everything here is fake and sealed off from real data: settings live in a
/// throwaway temp folder, secrets stay in memory (the Keychain is never read),
/// and no Jamf URL is set, so nothing can reach a server.
@MainActor
enum PreviewData {
    static func model(type: DeviceType = .computer, selected: Set<String> = []) -> AppModel {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfToolboxPreview-\(UUID().uuidString)", isDirectory: true)
        let store = SettingsStore(directory: folder, inMemorySecrets: ["username": "preview-user"])
        store.prefs.deviceListComputer = computers
        store.prefs.deviceListMobile = mobiles
        let model = AppModel(settings: store)
        model.opensSettingsWhenUnconfigured = false
        model.deviceType = type
        model.selection = selected
        model.log.add("Welcome to Jamf Toolbox (preview data).")
        model.log.add("Added to list: MBP-ARIVERA, MBA-JCHEN")
        model.log.add("OK — Rename MBP-0042 → Alex Rivera - C02XL0AAJGH5. Set Computer Name command queued.")
        return model
    }

    private static func entry(_ id: String, _ fields: [String: String]) -> DeviceEntry {
        var all = Dictionary(uniqueKeysWithValues: ColumnField.allCases.map { ($0.rawValue, "") })
        all.merge(fields) { $1 }
        all["device_id"] = id
        return DeviceEntry(id: id, fields: all)
    }

    static let computers: [DeviceEntry] = [
        entry("101", ["name": "MBP-ARIVERA", "serial": "C02XL0AAJGH5", "username": "arivera", "realname": "Alex Rivera",
                      "wifi_mac": "a4:83:e7:12:34:56", "ip": "10.20.4.18", "model": "MacBook Pro (14-inch, 2023)",
                      "os_version": "15.4", "building": "High School", "room": "214"]),
        entry("102", ["name": "MBA-JCHEN", "serial": "FVFH31AAQ6L4", "username": "jchen", "realname": "Jordan Chen",
                      "wifi_mac": "3c:22:fb:9a:0b:11", "ip": "10.20.6.102", "model": "MacBook Air (M2, 2022)",
                      "os_version": "15.3.2", "building": "Middle School", "room": "Library"]),
        entry("103", ["name": "LAB-iMAC-07", "serial": "C02DM7AAPN7C", "username": "", "realname": "",
                      "wifi_mac": "", "ip": "10.20.8.57", "model": "iMac (24-inch, M3, 2023)",
                      "os_version": "14.7", "building": "High School", "room": "Lab 2"]),
    ]

    static let mobiles: [DeviceEntry] = [
        entry("201", ["name": "iPad-G5-014", "serial": "DMPZK1AAQ1GC", "username": "spatel", "realname": "Sam Patel",
                      "wifi_mac": "f0:b3:ec:44:21:07", "ip": "10.30.1.44", "model": "iPad (10th generation)",
                      "os_version": "18.3"]),
        entry("202", ["name": "iPad-G5-015", "serial": "DMPZK1AAQ1GD", "username": "mlopez", "realname": "Maria Lopez",
                      "wifi_mac": "f0:b3:ec:44:21:08", "ip": "", "model": "iPad (10th generation)",
                      "os_version": "17.7"]),
    ]

    static let record: JSONValue = (try? JSONValue.parse(Data(#"""
    {"general": {"id": 101, "name": "MBP-ARIVERA", "serial_number": "C02XL0AAJGH5",
                 "mac_address": "A4:83:E7:12:34:56", "last_reported_ip": "10.20.4.18",
                 "report_date": "2026-10-12 08:14:03", "supervised": true},
     "location": {"username": "arivera", "realname": "Alex Rivera", "email_address": "arivera@example.org",
                  "building": "High School", "room": "214"},
     "hardware": {"model": "MacBook Pro (14-inch, 2023)", "os_version": "15.4",
                  "storage": [{"disk": "disk0", "size": 512000}]},
     "extension_attributes": [{"name": "Grade", "value": "11"}, {"name": "Cart", "value": "B"}]}
    """#.utf8))) ?? .emptyObject

    static let auditResults: [AuditResult] = {
        func finding(_ type: String, _ name: String, _ id: String, _ relationship: String) -> AuditFinding {
            AuditFinding(objectType: type, objectName: name, objectID: id, relationship: relationship, webPage: nil)
        }
        let server = "https://example.jamfcloud.com"
        return [
            AuditResult(report: StaticGroupDependencyAudit.reportName, runAt: Date().addingTimeInterval(-3600),
                        server: server,
                        subject: AuditSubject(kind: .mobile, id: "7", name: "Grade 5 iPads", memberCount: 148),
                        findings: [finding("Mobile Device Configuration Profile", "Wi-Fi - Students", "31", "Scoped"),
                                   finding("Mobile Device Configuration Profile", "Restrictions - Grade 5", "44", "Scoped"),
                                   finding("Mobile Device App", "Seesaw", "12", "Scoped"),
                                   finding("Mobile Device Configuration Profile", "Staff Mail", "52", "Excluded"),
                                   finding("Smart Mobile Device Group", "Grade 5 - Old iPadOS", "9", "Criterion (member of)")],
                        warnings: [], objectsScanned: 131),
            AuditResult(report: StaticGroupDependencyAudit.reportName, runAt: Date().addingTimeInterval(-86400 * 12),
                        server: server,
                        subject: AuditSubject(kind: .computer, id: "2", name: "Lab Macs", memberCount: 24),
                        findings: [], warnings: ["Skipped restricted software records: your account can't read them."],
                        objectsScanned: 22),
        ]
    }()

    static let merakiClient: JSONValue = (try? JSONValue.parse(Data(#"""
    {"description": "MBP-ARIVERA", "ip": "10.20.4.18", "ssid": "District-Staff",
     "recentDeviceName": "HS-AP-2nd-Floor-East", "lastSeen": 1791000000, "status": "Online",
     "recentDeviceConnection": "Wireless"}
    """#.utf8))) ?? .emptyObject
}
#endif

import Foundation

/// How a saved result is described and linked, shared by both apps' result views.
extension AuditResult {
    /// Rows pair a profile with one device (Devices Targeted and Excluded).
    public var pairsDevices: Bool { findings.contains { $0.device != nil } }

    /// Rows carry how the device is directly scoped (a device's Config
    /// Profiles in Scope), so scope changes can be offered.
    public var offersScopeChanges: Bool { findings.contains { $0.directScope != nil } }

    /// Rows say whether each profile is installed (a device's profiles).
    public var showsInstalled: Bool { findings.contains { $0.installed != nil } }

    /// The "Found" line: what the findings add up to.
    public var foundText: String {
        if pairsDevices {
            let devices = Set(findings.compactMap { $0.device?.id }).count
            let profiles = Set(findings.map(\.objectID)).count
            return "\(devices) device\(devices == 1 ? "" : "s") targeted and excluded, across \(profiles) profile\(profiles == 1 ? "" : "s")"
        }
        let counts = Dictionary(grouping: findings, by: \.objectType).mapValues(\.count)
        let total = findings.count
        let noun = reportID == AuditReports.groupDependenciesID ? "reference" : "finding"
        return "\(total) \(noun)\(total == 1 ? "" : "s"): " + AuditObjects.describeCounts(counts)
    }

    /// Shown when nothing was found.
    public var emptyText: String {
        if !warnings.isEmpty { return "Nothing found in what could be checked." }
        return reportID == AuditReports.groupDependenciesID ? "Nothing in Jamf Pro refers to this group." : "No issues found."
    }

    /// The finding's object in the Jamf Pro web interface.
    public func webURL(for finding: AuditFinding) -> URL? {
        guard !finding.objectID.isEmpty,
              let page = AuditObjects.webPage(forObjectType: finding.objectType) ?? finding.webPage else { return nil }
        return URL(string: "\(server)/\(page)?id=\(finding.objectID)&o=r")
    }

    /// The finding's device in the Jamf Pro web interface.
    public func deviceWebURL(for finding: AuditFinding) -> URL? {
        guard let device = finding.device else { return nil }
        let page = device.kind == .computer ? "computers.html" : "mobileDevices.html"
        return URL(string: "\(server)/\(page)?id=\(device.id)&o=r")
    }
}

extension AuditReports {
    /// Device-centric reports offered from a device's menu, with short titles.
    public static let deviceMenu: [(id: String, title: String)] = [
        ("groups-device-memberships", "Group Memberships"),
        ("profiles-device", "Profiles vs. Scope"),
        ("profiles-device-targeting", "Config Profiles in Scope"),
    ]
}

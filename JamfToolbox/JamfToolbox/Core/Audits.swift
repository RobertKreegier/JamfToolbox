import Foundation

// MARK: - Shared audit types

/// Computers or mobile devices: which side of Jamf Pro an audit looks at.
enum GroupKind: String, Codable, CaseIterable, Identifiable {
    case computer
    case mobile

    var id: String { rawValue }
    var label: String { self == .computer ? "Computer" : "Mobile Device" }
    var pluralLabel: String { self == .computer ? "computers" : "mobile devices" }

    /// Classic API resource for this kind of group.
    var resource: String { self == .computer ? "computergroups" : "mobiledevicegroups" }
    /// Classic API resource for this kind of device.
    var deviceResource: String { self == .computer ? "computers" : "mobiledevices" }
    /// The scope key that lists groups of this kind (`scope.computer_groups`, …).
    var scopeKey: String { self == .computer ? "computer_groups" : "mobile_device_groups" }
    /// The scope key that lists individual devices, and the group-record member list.
    var membersKey: String { self == .computer ? "computers" : "mobile_devices" }
    /// `scope.all_computers` / `scope.all_mobile_devices`.
    var allKey: String { self == .computer ? "all_computers" : "all_mobile_devices" }
    /// The smart-group / advanced-search criterion that names a group of this kind.
    var criterionName: String { self == .computer ? "Computer Group" : "Mobile Device Group" }

    var deviceType: DeviceType { self == .computer ? .computer : .mobile }
    init(_ type: DeviceType) { self = type == .computer ? .computer : .mobile }

    func groupLabel(smart: Bool) -> String { (smart ? "Smart " : "Static ") + label + " Group" }
}

/// A group as listed by Jamf Pro.
struct GroupSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let isSmart: Bool
}

/// What a group- or device-specific audit was run against.
struct AuditSubject: Codable, Hashable {
    var kind: GroupKind
    var id: String
    var name: String
    var memberCount: Int?
}

/// The inputs a report was run with. Saved with the result so it can be re-run.
struct AuditParameters: Codable, Hashable {
    var kind: GroupKind = .computer
    var groupID: String?
    var groupName: String?
    var deviceID: String?
    var deviceName: String?
    var days = 30
    var osVersion = ""
    var pastedList = ""
    var threshold = 5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(GroupKind.self, forKey: .kind)) ?? .computer
        groupID = try? c.decodeIfPresent(String.self, forKey: .groupID)
        groupName = try? c.decodeIfPresent(String.self, forKey: .groupName)
        deviceID = try? c.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try? c.decodeIfPresent(String.self, forKey: .deviceName)
        days = (try? c.decode(Int.self, forKey: .days)) ?? 30
        osVersion = (try? c.decode(String.self, forKey: .osVersion)) ?? ""
        pastedList = (try? c.decode(String.self, forKey: .pastedList)) ?? ""
        threshold = (try? c.decode(Int.self, forKey: .threshold)) ?? 5
    }
}

/// One row of an audit result.
struct AuditFinding: Codable, Hashable, Identifiable {
    var objectType: String
    var objectName: String
    var objectID: String
    /// The report-specific detail: a relationship, an issue, a date, …
    var detail: String
    /// Jamf Pro web page for the object type, e.g. `policies.html`.
    var webPage: String?
    /// For a device's profiles: how the device is directly scoped, which
    /// decides the scope changes offered for the row.
    var directScope: DirectScope?
    /// For a device's profiles: whether the profile is installed on the device.
    var installed: Bool?

    // "relationship" is the key results saved by the first audit used.
    enum CodingKeys: String, CodingKey {
        case objectType, objectName, objectID, detail = "relationship", webPage, directScope, installed
    }

    init(objectType: String, objectName: String, objectID: String, detail: String, webPage: String? = nil,
         directScope: DirectScope? = nil, installed: Bool? = nil) {
        self.objectType = objectType
        self.objectName = objectName
        self.objectID = objectID
        self.detail = detail
        self.webPage = webPage ?? AuditObjects.webPage(forObjectType: objectType)
        self.directScope = directScope
        self.installed = installed
    }

    var id: String { "\(objectType)|\(objectID)|\(objectName)|\(detail)" }

    /// "Yes", "No", or "" when the report doesn't say.
    var installedText: String { installed.map { $0 ? "Yes" : "No" } ?? "" }
}

/// A saved audit run.
struct AuditResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var reportID: String
    var report: String
    var runAt: Date
    /// The Jamf Pro server the audit ran against.
    var server: String
    /// The group or device the report was about, for group/device reports.
    var subject: AuditSubject?
    /// One line describing what was audited ("Mobile devices · not seen in 30 days").
    var subtitle: String
    /// Heading for the findings table's detail column.
    var detailHeading: String
    var parameters: AuditParameters?
    var findings: [AuditFinding]
    /// Object types that couldn't be read, and other caveats. Non-empty means
    /// the findings may be incomplete.
    var warnings: [String]
    var objectsScanned: Int

    init(reportID: String, report: String, runAt: Date, server: String, subject: AuditSubject?, subtitle: String,
         detailHeading: String, parameters: AuditParameters?, findings: [AuditFinding], warnings: [String],
         objectsScanned: Int) {
        self.reportID = reportID
        self.report = report
        self.runAt = runAt
        self.server = server
        self.subject = subject
        self.subtitle = subtitle
        self.detailHeading = detailHeading
        self.parameters = parameters
        self.findings = findings
        self.warnings = warnings
        self.objectsScanned = objectsScanned
    }

    /// Tolerates results saved by earlier versions (only the group-dependencies report existed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        reportID = (try? c.decode(String.self, forKey: .reportID)) ?? AuditReports.groupDependenciesID
        report = try c.decode(String.self, forKey: .report)
        runAt = try c.decode(Date.self, forKey: .runAt)
        server = try c.decode(String.self, forKey: .server)
        subject = try? c.decodeIfPresent(AuditSubject.self, forKey: .subject)
        subtitle = (try? c.decode(String.self, forKey: .subtitle))
            ?? subject.map { "\($0.kind.label) static group" } ?? ""
        detailHeading = (try? c.decode(String.self, forKey: .detailHeading)) ?? "Relationship"
        parameters = try? c.decodeIfPresent(AuditParameters.self, forKey: .parameters)
        findings = try c.decode([AuditFinding].self, forKey: .findings)
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
        objectsScanned = (try? c.decode(Int.self, forKey: .objectsScanned)) ?? 0
    }

    /// What the saved-results list shows in its Subject column.
    var subjectLabel: String { subject?.name ?? subtitle }
}

struct AuditProgress {
    var done: Int
    var total: Int
    var message: String
}

// MARK: - Jamf object types

/// The Jamf Pro object types audits read or report, with their classic API
/// resources and web pages (all page names confirmed against a real server).
enum AuditObjects {
    struct ObjectType: Hashable {
        let label: String           // title case, shown in findings
        let singular: String        // lower case, for summaries
        let plural: String
        let resource: String        // classic API resource
        /// Classic API subset to request instead of the full record, if supported.
        let subset: String?
        let webPage: String
        let kinds: Set<GroupKind>
        var onlySmartGroups = false // group resources: static groups can't reference others
    }

    static let policy = ObjectType(label: "Policy", singular: "policy", plural: "policies", resource: "policies",
                                   subset: "General&Scope&SelfService", webPage: "policies.html", kinds: [.computer])
    static let macProfile = ObjectType(label: "macOS Configuration Profile", singular: "macOS configuration profile",
                                       plural: "macOS configuration profiles", resource: "osxconfigurationprofiles",
                                       subset: "General&Scope", webPage: "OSXConfigurationProfiles.html", kinds: [.computer])
    static let macApp = ObjectType(label: "Mac App", singular: "Mac app", plural: "Mac apps", resource: "macapplications",
                                   subset: "General&Scope", webPage: "macApps.html", kinds: [.computer])
    static let restrictedSoftware = ObjectType(label: "Restricted Software", singular: "restricted software record",
                                               plural: "restricted software records", resource: "restrictedsoftware",
                                               subset: "General&Scope", webPage: "restrictedSoftware.html", kinds: [.computer])
    static let smartComputerGroup = ObjectType(label: "Smart Computer Group", singular: "smart computer group",
                                               plural: "smart computer groups", resource: "computergroups", subset: nil,
                                               webPage: "smartComputerGroups.html", kinds: [.computer], onlySmartGroups: true)
    static let computerSearch = ObjectType(label: "Advanced Computer Search", singular: "advanced computer search",
                                           plural: "advanced computer searches", resource: "advancedcomputersearches",
                                           subset: nil, webPage: "advancedComputerSearches.html", kinds: [.computer])
    static let mobileProfile = ObjectType(label: "Mobile Device Configuration Profile",
                                          singular: "mobile device configuration profile",
                                          plural: "mobile device configuration profiles",
                                          resource: "mobiledeviceconfigurationprofiles", subset: "General&Scope",
                                          webPage: "iOSConfigurationProfiles.html", kinds: [.mobile])
    static let mobileApp = ObjectType(label: "Mobile Device App", singular: "mobile device app", plural: "mobile device apps",
                                      resource: "mobiledeviceapplications", subset: "General&Scope",
                                      webPage: "mobileDeviceApps.html", kinds: [.mobile])
    static let ebook = ObjectType(label: "eBook", singular: "eBook", plural: "eBooks", resource: "ebooks",
                                  subset: "General&Scope", webPage: "eBooks.html", kinds: [.computer, .mobile])
    static let smartMobileGroup = ObjectType(label: "Smart Mobile Device Group", singular: "smart mobile device group",
                                             plural: "smart mobile device groups", resource: "mobiledevicegroups",
                                             subset: nil, webPage: "smartMobileDeviceGroups.html", kinds: [.mobile],
                                             onlySmartGroups: true)
    static let mobileSearch = ObjectType(label: "Advanced Mobile Device Search", singular: "advanced mobile device search",
                                         plural: "advanced mobile device searches",
                                         resource: "advancedmobiledevicesearches", subset: nil,
                                         webPage: "advancedMobileDeviceSearches.html", kinds: [.mobile])

    /// Everything that can refer to a group, in display order.
    static let scopedTypes: [ObjectType] = [policy, macProfile, macApp, restrictedSoftware, smartComputerGroup,
                                            computerSearch, mobileProfile, mobileApp, ebook, smartMobileGroup, mobileSearch]

    static func profileType(_ kind: GroupKind) -> ObjectType { kind == .computer ? macProfile : mobileProfile }

    /// Labels for rows that aren't scoped objects: devices, groups, pasted entries.
    private static let otherTypes: [(label: String, singular: String, plural: String, page: String?)] = [
        ("Computer", "computer", "computers", "computers.html"),
        ("Mobile Device", "mobile device", "mobile devices", "mobileDevices.html"),
        ("Static Computer Group", "static computer group", "static computer groups", "staticComputerGroups.html"),
        ("Static Mobile Device Group", "static mobile device group", "static mobile device groups",
         "staticMobileDeviceGroups.html"),
        ("Installed Profile", "installed profile", "installed profiles", nil),
        ("Pasted Entry", "pasted entry", "pasted entries", nil),
    ]

    /// Jamf Pro page for an object type, looked up when a link is opened so
    /// results saved before a page name was corrected still open correctly.
    static func webPage(forObjectType label: String) -> String? {
        if let type = scopedTypes.first(where: { $0.label == label }) { return type.webPage }
        return otherTypes.first { $0.label == label }?.page
    }

    /// "2 policies, 1 smart computer group".
    static func describeCounts(_ counts: [String: Int]) -> String {
        let forms = scopedTypes.map { ($0.label, $0.singular, $0.plural) } + otherTypes.map { ($0.label, $0.singular, $0.plural) }
        var parts = forms.compactMap { label, singular, plural -> String? in
            guard let count = counts[label], count > 0 else { return nil }
            return "\(count) \(count == 1 ? singular : plural)"
        }
        // Anything not in the table, so nothing is silently dropped.
        let known = Set(forms.map(\.0))
        for (label, count) in counts.sorted(by: { $0.key < $1.key }) where !known.contains(label) && count > 0 {
            parts.append("\(count) \(label)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Classic API record helpers

    /// `{"policies": [ … ]}` → the entries, whatever the wrapper key is called.
    static func entries(in listing: JSONValue) -> [(id: String, name: String, json: JSONValue)] {
        guard case .object(let top) = listing,
              let array = top.lazy.compactMap({ $0.value.arrayValue }).first else { return [] }
        return array.compactMap { item in
            let id = item["id"]?.text ?? ""
            return id.isEmpty ? nil : (id, item["name"]?.text ?? "", item)
        }
    }

    /// `{"policy": { … }}` → the inner record.
    static func rootObject(_ record: JSONValue) -> JSONValue? {
        guard case .object(let top) = record else { return nil }
        if top.count == 1, case .object = top[0].value { return top[0].value }
        return record
    }

    static func isTrue(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .string(let s)?: return s.lowercased() == "true"
        case .number(let n)?: return n != "0"
        default: return false
        }
    }

    /// The id inside a scope/member entry, tolerating the older wrapped shape
    /// (`{"computer_group": {"id": 1}}`).
    static func entryID(_ entry: JSONValue) -> String? {
        if let id = entry["id"]?.text, !id.isEmpty { return id }
        if case .object(let fields) = entry, fields.count == 1, let id = fields[0].value["id"]?.text, !id.isEmpty {
            return id
        }
        return nil
    }

    static func entryName(_ entry: JSONValue) -> String {
        if let name = entry["name"]?.text, !name.isEmpty { return name }
        if case .object(let fields) = entry, fields.count == 1 { return fields[0].value["name"]?.text ?? "" }
        return ""
    }
}

// MARK: - Group references and scopes

/// Where a record refers to a group of one kind.
struct GroupReference: Hashable {
    let groupID: String?
    let groupName: String?
    let relationship: String
}

enum ScopeReading {
    /// Every reference to a group of `kind` inside `root`: scope targets,
    /// exclusions and limitations, and smart-group / advanced-search criteria.
    /// Walks the whole record so it tolerates differences between object types.
    static func groupReferences(in root: JSONValue, kind: GroupKind) -> [GroupReference] {
        var found: [GroupReference] = []
        func add(_ reference: GroupReference) { if !found.contains(reference) { found.append(reference) } }

        func walk(_ value: JSONValue, path: [String]) {
            switch value {
            case .object(let entries):
                if value["name"]?.text == kind.criterionName, let target = value["value"]?.text, !target.isEmpty {
                    let searchType = value["search_type"]?.text ?? ""
                    add(GroupReference(groupID: nil, groupName: target,
                                       relationship: searchType.isEmpty ? "Criterion" : "Criterion (\(searchType))"))
                }
                for entry in entries {
                    if entry.key == kind.scopeKey, let groups = entry.value.arrayValue {
                        for group in groups {
                            add(GroupReference(groupID: AuditObjects.entryID(group),
                                               groupName: AuditObjects.entryName(group),
                                               relationship: relationship(path + [entry.key])))
                        }
                    } else {
                        walk(entry.value, path: path + [entry.key])
                    }
                }
            case .array(let items):
                for item in items { walk(item, path: path) }
            default:
                break
            }
        }
        walk(root, path: [])
        return found
    }

    /// Does this reference point at the given group? Scope entries match by id;
    /// criteria (which only carry a name) match the name, ignoring case.
    static func reference(_ reference: GroupReference, matches groupID: String, name: String) -> Bool {
        if let id = reference.groupID { return id == groupID }
        return reference.groupName?.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func relationship(_ path: [String]) -> String {
        if path.contains("exclusions") { return "Excluded" }
        if path.contains("limitations") { return "Limitation" }
        if path.contains("scope") { return "Scoped" }
        return "Referenced"
    }

    /// The parts of an object's scope that concern one kind of device.
    struct Scope {
        var all = false
        var devices: Set<String> = []
        var groups: [String: String] = [:]          // id → name
        /// Other non-empty target lists (buildings, departments, users…), which audits don't evaluate.
        var otherTargets: [String] = []
        var excludedDevices: Set<String> = []
        var excludedGroups: [String: String] = [:]
        /// Jamf user targets and exclusions, by lower-cased username.
        var users: Set<String> = []
        var excludedUsers: Set<String> = []
        /// Building and department targets and exclusions, id → name.
        var buildings: [String: String] = [:]
        var departments: [String: String] = [:]
        var excludedBuildings: [String: String] = [:]
        var excludedDepartments: [String: String] = [:]
        /// Jamf user group targets and exclusions, id → name, and "All Users".
        var userGroups: [String: String] = [:]
        var excludedUserGroups: [String: String] = [:]
        var allUsers = false

        var isEmpty: Bool { !all && !allUsers && devices.isEmpty && groups.isEmpty && otherTargets.isEmpty }
        /// True when any exclusion list is non-empty (devices, groups, users, buildings, departments, network segments…).
        var hasAnyExclusion = false
        var hasExclusions: Bool { hasAnyExclusion || !excludedDevices.isEmpty || !excludedGroups.isEmpty }
    }

    static func scope(of root: JSONValue, kind: GroupKind) -> Scope {
        var result = Scope()
        guard case .object(let entries)? = root["scope"] else { return result }
        let otherKind: GroupKind = kind == .computer ? .mobile : .computer
        let ignored: Set<String> = [otherKind.allKey, otherKind.membersKey, otherKind.scopeKey, "exclusions", "limitations"]

        for entry in entries where !ignored.contains(entry.key) {
            switch entry.key {
            case kind.allKey:
                result.all = AuditObjects.isTrue(entry.value)
            case kind.membersKey:
                result.devices = Set((entry.value.arrayValue ?? []).compactMap(AuditObjects.entryID))
            case kind.scopeKey:
                for group in entry.value.arrayValue ?? [] {
                    if let id = AuditObjects.entryID(group) { result.groups[id] = AuditObjects.entryName(group) }
                }
            default:
                if entry.key == "jss_users" { result.users = userNames(entry.value) }
                if entry.key == "buildings" { result.buildings = idNames(entry.value) }
                if entry.key == "departments" { result.departments = idNames(entry.value) }
                if entry.key == "jss_user_groups" { result.userGroups = idNames(entry.value) }
                if entry.key == "all_jss_users" { result.allUsers = AuditObjects.isTrue(entry.value) }
                if let items = entry.value.arrayValue, !items.isEmpty {
                    result.otherTargets.append(entry.key.replacingOccurrences(of: "_", with: " "))
                }
            }
        }
        if let exclusions = root["scope"]?["exclusions"] {
            if case .object(let lists) = exclusions {
                result.hasAnyExclusion = lists.contains { !($0.value.arrayValue ?? []).isEmpty }
            }
            result.excludedDevices = Set((exclusions[kind.membersKey]?.arrayValue ?? []).compactMap(AuditObjects.entryID))
            for group in exclusions[kind.scopeKey]?.arrayValue ?? [] {
                if let id = AuditObjects.entryID(group) { result.excludedGroups[id] = AuditObjects.entryName(group) }
            }
            result.excludedUsers = userNames(exclusions["jss_users"] ?? .array([]))
            result.excludedBuildings = idNames(exclusions["buildings"] ?? .array([]))
            result.excludedDepartments = idNames(exclusions["departments"] ?? .array([]))
            result.excludedUserGroups = idNames(exclusions["jss_user_groups"] ?? .array([]))
        }
        return result
    }

    private static func idNames(_ list: JSONValue) -> [String: String] {
        var result: [String: String] = [:]
        for (index, item) in (list.arrayValue ?? []).enumerated() {
            result[AuditObjects.entryID(item) ?? "#\(index)"] = AuditObjects.entryName(item)
        }
        return result
    }

    private static func userNames(_ list: JSONValue) -> Set<String> {
        Set((list.arrayValue ?? []).map { AuditObjects.entryName($0).lowercased() }.filter { !$0.isEmpty })
    }
}

// MARK: - Saved results

/// Saved audit results, one JSON file each, in an `Audits` folder beside settings.json.
final class AuditStore {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func loadAll() -> [AuditResult] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(AuditResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.runAt > $1.runAt }
    }

    func save(_ result: AuditResult) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(result).write(to: file(for: result.id), options: .atomic)
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids { try? FileManager.default.removeItem(at: file(for: id)) }
    }

    /// Deletes results run before `date`; returns how many were removed.
    @discardableResult
    func deleteOlder(than date: Date) -> Int {
        let old = loadAll().filter { $0.runAt < date }
        delete(Set(old.map(\.id)))
        return old.count
    }
}

import Foundation

// MARK: - Shared audit types

/// Which kind of static group an audit is about.
enum GroupKind: String, Codable, CaseIterable, Identifiable {
    case computer
    case mobile

    var id: String { rawValue }
    var label: String { self == .computer ? "Computer" : "Mobile Device" }

    /// Classic API resource for this kind of group.
    var resource: String { self == .computer ? "computergroups" : "mobiledevicegroups" }
    /// The scope key that lists groups of this kind (`scope.computer_groups`, …).
    var scopeKey: String { self == .computer ? "computer_groups" : "mobile_device_groups" }
    /// The smart-group / advanced-search criterion that names a group of this kind.
    var criterionName: String { self == .computer ? "Computer Group" : "Mobile Device Group" }
    /// Member list inside a group record.
    var membersKey: String { self == .computer ? "computers" : "mobile_devices" }
    var staticGroupPage: String { self == .computer ? "staticComputerGroups.html" : "staticMobileDeviceGroups.html" }
}

/// A group as listed by Jamf Pro.
struct GroupSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let isSmart: Bool
}

/// What an audit was run against.
struct AuditSubject: Codable, Hashable {
    var kind: GroupKind
    var id: String
    var name: String
    var memberCount: Int?
}

/// One object that depends on the audited group.
struct AuditFinding: Codable, Hashable, Identifiable {
    var objectType: String
    var objectName: String
    var objectID: String
    /// Scoped, Excluded, Limitation, Criterion (member of), …
    var relationship: String
    /// Jamf Pro web page for the object type, e.g. `policies.html`.
    var webPage: String?

    var id: String { "\(objectType)|\(objectID)|\(relationship)" }
}

/// A saved audit run.
struct AuditResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var report: String
    var runAt: Date
    /// The Jamf Pro server the audit ran against.
    var server: String
    var subject: AuditSubject
    var findings: [AuditFinding]
    /// Object types that couldn't be read, and other caveats. Non-empty means
    /// the findings may be incomplete.
    var warnings: [String]
    var objectsScanned: Int
}

struct AuditProgress {
    var done: Int
    var total: Int
    var message: String
}

// MARK: - Static Group Dependencies

/// Finds everything in Jamf Pro that refers to one static group: scope
/// targets, exclusions and limitations of policies, profiles, apps, eBooks and
/// restricted software, plus smart groups and advanced searches whose criteria
/// name the group. Read-only.
enum StaticGroupDependencyAudit {
    static let reportName = "Static Group Dependencies"

    struct ObjectType: Hashable {
        static let singulars: [String: String] = [
            "Policy": "policy", "macOS Configuration Profile": "macOS configuration profile", "Mac App": "Mac app",
            "Restricted Software": "restricted software record", "Smart Computer Group": "smart computer group",
            "Advanced Computer Search": "advanced computer search",
            "Mobile Device Configuration Profile": "mobile device configuration profile",
            "Mobile Device App": "mobile device app", "eBook": "eBook",
            "Smart Mobile Device Group": "smart mobile device group",
            "Advanced Mobile Device Search": "advanced mobile device search",
        ]

        let label: String           // for findings (title case)
        let plural: String          // for warnings and summaries
        var singular: String { Self.singulars[label] ?? label }
        let resource: String        // classic API resource
        let usesScopeSubset: Bool   // fetch only General & Scope
        let webPage: String
        let kinds: Set<GroupKind>
        var onlySmartGroups = false // for group resources: static groups can't reference others
    }

    /// "2 policies, 1 smart computer group": lower-case forms keyed by label.
    static func describeCounts(_ counts: [String: Int]) -> String {
        objectTypes.compactMap { type in
            guard let count = counts[type.label], count > 0 else { return nil }
            return "\(count) \(count == 1 ? type.singular : type.plural)"
        }.joined(separator: ", ")
    }

    static let objectTypes: [ObjectType] = [
        ObjectType(label: "Policy", plural: "policies", resource: "policies", usesScopeSubset: true,
                   webPage: "policies.html", kinds: [.computer]),
        ObjectType(label: "macOS Configuration Profile", plural: "macOS configuration profiles",
                   resource: "osxconfigurationprofiles", usesScopeSubset: true,
                   webPage: "OSXConfigurationProfiles.html", kinds: [.computer]),
        ObjectType(label: "Mac App", plural: "Mac apps", resource: "macapplications", usesScopeSubset: true,
                   webPage: "macApps.html", kinds: [.computer]),
        ObjectType(label: "Restricted Software", plural: "restricted software records", resource: "restrictedsoftware",
                   usesScopeSubset: true, webPage: "restrictedSoftware.html", kinds: [.computer]),
        ObjectType(label: "Smart Computer Group", plural: "smart computer groups", resource: "computergroups",
                   usesScopeSubset: false, webPage: "smartComputerGroups.html", kinds: [.computer],
                   onlySmartGroups: true),
        ObjectType(label: "Advanced Computer Search", plural: "advanced computer searches",
                   resource: "advancedcomputersearches", usesScopeSubset: false,
                   webPage: "advancedComputerSearches.html", kinds: [.computer]),
        ObjectType(label: "Mobile Device Configuration Profile", plural: "mobile device configuration profiles",
                   resource: "mobiledeviceconfigurationprofiles", usesScopeSubset: true,
                   webPage: "mobileDeviceConfigurationProfiles.html", kinds: [.mobile]),
        ObjectType(label: "Mobile Device App", plural: "mobile device apps", resource: "mobiledeviceapplications",
                   usesScopeSubset: true, webPage: "mobileDeviceApps.html", kinds: [.mobile]),
        ObjectType(label: "eBook", plural: "eBooks", resource: "ebooks", usesScopeSubset: true,
                   webPage: "eBooks.html", kinds: [.computer, .mobile]),
        ObjectType(label: "Smart Mobile Device Group", plural: "smart mobile device groups",
                   resource: "mobiledevicegroups", usesScopeSubset: false,
                   webPage: "smartMobileDeviceGroups.html", kinds: [.mobile], onlySmartGroups: true),
        ObjectType(label: "Advanced Mobile Device Search", plural: "advanced mobile device searches",
                   resource: "advancedmobiledevicesearches", usesScopeSubset: false,
                   webPage: "advancedMobileDeviceSearches.html", kinds: [.mobile]),
    ]

    // MARK: Listing groups

    /// Static groups of one kind, sorted by name, for the picker.
    static func staticGroups(_ kind: GroupKind, client: JamfClient) async throws -> [GroupSummary] {
        let listing = try await client.get("/JSSResource/\(kind.resource)")
        return entries(in: listing)
            .map { GroupSummary(id: $0.id, name: $0.name, isSmart: isTrue($0.json["is_smart"])) }
            .filter { !$0.isSmart }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Running

    private struct WorkItem {
        let type: ObjectType
        let id: String
        let name: String
    }

    static func run(subject: AuditSubject, client: JamfClient, concurrency: Int = 6,
                    progress: @escaping @MainActor (AuditProgress) -> Void) async throws -> AuditResult {
        var subject = subject
        var warnings: [String] = []
        await progress(AuditProgress(done: 0, total: 0, message: "Reading “\(subject.name)”…"))

        // Member count, for context in the report.
        if let record = try? await client.get("/JSSResource/\(subject.kind.resource)/id/\(subject.id)"),
           let root = rootObject(record) {
            subject.memberCount = root[subject.kind.membersKey]?.arrayValue?.count
        }

        // List every object type that can refer to this kind of group.
        var items: [WorkItem] = []
        for type in objectTypes where type.kinds.contains(subject.kind) {
            try Task.checkCancellation()
            await progress(AuditProgress(done: 0, total: 0, message: "Listing \(type.plural)…"))
            do {
                let listing = try await client.get("/JSSResource/\(type.resource)")
                for entry in entries(in: listing) {
                    if type.onlySmartGroups {
                        guard isTrue(entry.json["is_smart"]) else { continue }
                        if type.resource == subject.kind.resource && entry.id == subject.id { continue }
                    }
                    items.append(WorkItem(type: type, id: entry.id, name: entry.name))
                }
            } catch let error as ServiceError {
                warnings.append(error.isPermissionDenied
                    ? "Skipped \(type.plural): your account can't read them."
                    : "Skipped \(type.plural): \(error.message)")
            }
        }

        // Read each object's scope / criteria, a few at a time.
        var findings: [AuditFinding] = []
        var unreadable: [String: Int] = [:]
        var done = 0
        let total = items.count
        try await withThrowingTaskGroup(of: (WorkItem, JSONValue?).self) { group in
            var next = 0
            func enqueue(_ item: WorkItem) {
                group.addTask { (item, try? await fetchDetail(item, client: client)) }
            }
            while next < min(concurrency, items.count) { enqueue(items[next]); next += 1 }

            while let (item, record) = try await group.next() {
                try Task.checkCancellation()
                done += 1
                if let record, let root = rootObject(record) {
                    for relationship in relationships(in: root, to: subject) {
                        findings.append(AuditFinding(objectType: item.type.label, objectName: item.name,
                                                     objectID: item.id, relationship: relationship,
                                                     webPage: item.type.webPage))
                    }
                } else {
                    unreadable[item.type.plural, default: 0] += 1
                }
                await progress(AuditProgress(done: done, total: total,
                                             message: "Checked \(done) of \(total): \(item.name)"))
                if next < items.count { enqueue(items[next]); next += 1 }
            }
        }
        for (plural, count) in unreadable.sorted(by: { $0.key < $1.key }) {
            let noun = plural.prefix(1).uppercased() + plural.dropFirst()
            warnings.append("\(noun): \(count) couldn't be read, so \(count == 1 ? "it wasn't" : "they weren't") checked.")
        }

        let order = Dictionary(uniqueKeysWithValues: objectTypes.enumerated().map { ($1.label, $0) })
        findings.sort {
            let a = order[$0.objectType] ?? 0, b = order[$1.objectType] ?? 0
            return a != b ? a < b : $0.objectName.localizedStandardCompare($1.objectName) == .orderedAscending
        }
        return AuditResult(report: reportName, runAt: Date(), server: client.baseURL, subject: subject,
                           findings: findings, warnings: warnings, objectsScanned: total)
    }

    /// General & Scope only where the API supports it (much smaller); the full
    /// record if the server rejects the subset.
    private static func fetchDetail(_ item: WorkItem, client: JamfClient) async throws -> JSONValue {
        let base = "/JSSResource/\(item.type.resource)/id/\(item.id)"
        guard item.type.usesScopeSubset else { return try await client.get(base) }
        do {
            return try await client.get(base + "/subset/General&Scope")
        } catch let error as ServiceError where !error.isPermissionDenied && !error.isNotFound {
            return try await client.get(base)
        }
    }

    // MARK: Matching

    /// How `root` refers to the group, if at all. Walks the whole record so it
    /// tolerates the small differences in shape between object types.
    static func relationships(in root: JSONValue, to subject: AuditSubject) -> [String] {
        var found: [String] = []
        func add(_ relationship: String) { if !found.contains(relationship) { found.append(relationship) } }

        func walk(_ value: JSONValue, path: [String]) {
            switch value {
            case .object(let entries):
                // A smart-group or advanced-search criterion naming the group.
                if value["name"]?.text == subject.kind.criterionName,
                   value["value"]?.text.caseInsensitiveCompare(subject.name) == .orderedSame {
                    let searchType = value["search_type"]?.text ?? ""
                    add(searchType.isEmpty ? "Criterion" : "Criterion (\(searchType))")
                }
                for entry in entries {
                    if entry.key == subject.kind.scopeKey, let groups = entry.value.arrayValue {
                        for group in groups where matches(group, subject) {
                            add(scopeRelationship(path + [entry.key]))
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

    private static func matches(_ group: JSONValue, _ subject: AuditSubject) -> Bool {
        // Older payloads wrap each entry: {"computer_group": {"id": …}}.
        let entry = group[subject.kind.scopeKey.replacingOccurrences(of: "_groups", with: "_group")] ?? group
        if let id = entry["id"]?.text, !id.isEmpty { return id == subject.id }
        return entry["name"]?.text == subject.name
    }

    private static func scopeRelationship(_ path: [String]) -> String {
        if path.contains("exclusions") { return "Excluded" }
        if path.contains("limitations") { return "Limitation" }
        if path.contains("scope") { return "Scoped" }
        return "Referenced"
    }

    // MARK: Classic API helpers

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

    private static func isTrue(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .string(let s)?: return s.lowercased() == "true"
        default: return false
        }
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

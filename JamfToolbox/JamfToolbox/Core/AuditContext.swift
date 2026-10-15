import Foundation

/// A Jamf object an audit read, with its record (scope, criteria, payloads…).
struct ScopedObject {
    let type: AuditObjects.ObjectType
    let id: String
    let name: String
    let root: JSONValue
}

/// A group with its members.
struct GroupRecord {
    struct Member: Hashable {
        let id: String
        let name: String
        let serial: String
        let udid: String
        let mac: String
    }

    let kind: GroupKind
    let id: String
    let name: String
    let isSmart: Bool
    let members: [Member]

    var objectType: String { kind.groupLabel(smart: isSmart) }
}

/// One device from the Jamf Pro API inventory.
struct DeviceRecord {
    let kind: GroupKind
    let id: String
    let name: String
    let serial: String
    let username: String
    let osVersion: String
    let managementID: String
    /// Computers: last check-in. Mobile devices: last inventory update (they have no separate check-in).
    let lastSeen: Date?
    let supervised: Bool?
    let managed: Bool?
    let fileVaultEnabled: Bool?
    let fileVaultState: String
    /// From User and Location. The Jamf Pro API gives ids; names when it has them.
    var buildingID = ""
    var departmentID = ""
    var building = ""
    var department = ""

    var objectType: String { kind.label }
}

/// One MDM command from the Jamf Pro API.
struct MDMCommandRecord {
    let managementID: String
    let clientType: String
    let state: String
    let commandType: String
    let dateSent: Date?
    let profileID: String?
    let error: String
}

/// Everything an audit run reads from Jamf Pro, fetched at most once per run.
/// Read-only: only GET requests are made.
final class AuditContext {
    let client: JamfClient
    let progress: @MainActor (AuditProgress) -> Void
    /// Caveats collected while reading (types skipped, records unreadable…).
    private(set) var warnings: [String] = []
    private let concurrency = 6

    private var scopedCache: [String: [ScopedObject]] = [:]
    private var groupCache: [GroupKind: [GroupRecord]] = [:]
    private var inventoryCache: [GroupKind: [DeviceRecord]] = [:]

    init(client: JamfClient, progress: @escaping @MainActor (AuditProgress) -> Void) {
        self.client = client
        self.progress = progress
    }

    func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }

    func status(_ message: String) async {
        await progress(AuditProgress(done: 0, total: 0, message: message))
    }

    // MARK: Concurrent reads

    /// Reads `items` a few at a time, reporting progress. A failed read yields nil.
    func readAll<Item>(_ items: [Item], verb: String = "Reading", name: @escaping (Item) -> String,
                       read: @escaping (Item) async throws -> JSONValue) async throws -> [(Item, JSONValue?)] {
        var results: [(Item, JSONValue?)] = []
        var done = 0
        try await withThrowingTaskGroup(of: (Int, JSONValue?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let item = items[index]
                group.addTask { (index, try? await read(item)) }
            }
            while next < min(concurrency, items.count) { enqueue(next); next += 1 }
            var byIndex: [Int: JSONValue?] = [:]
            while let (index, value) = try await group.next() {
                try Task.checkCancellation()
                byIndex[index] = value
                done += 1
                await progress(AuditProgress(done: done, total: items.count,
                                             message: "\(verb) \(done) of \(items.count): \(name(items[index]))"))
                if next < items.count { enqueue(next); next += 1 }
            }
            results = items.indices.map { (items[$0], byIndex[$0] ?? nil) }
        }
        return results
    }

    /// A classic list, or nil (with a warning) if it can't be read.
    func list(_ type: AuditObjects.ObjectType) async throws -> [(id: String, name: String, json: JSONValue)]? {
        try Task.checkCancellation()
        await status("Listing \(type.plural)…")
        do {
            return AuditObjects.entries(in: try await client.get("/JSSResource/\(type.resource)"))
        } catch let error as ServiceError {
            warn(error.isPermissionDenied ? "Skipped \(type.plural): your account can't read them."
                                          : "Skipped \(type.plural): \(error.message)")
            return nil
        }
    }

    /// One record, asking for a subset where supported and falling back to
    /// the full record if the server rejects it.
    private func record(_ type: AuditObjects.ObjectType, id: String) async throws -> JSONValue {
        let base = "/JSSResource/\(type.resource)/id/\(id)"
        guard let subset = type.subset else { return try await client.get(base) }
        do {
            return try await client.get(base + "/subset/" + subset)
        } catch let error as ServiceError where !error.isPermissionDenied && !error.isNotFound {
            return try await client.get(base)
        }
    }

    // MARK: Scoped objects

    /// Every object of the given types, with its record. Cached per run.
    func scopedObjects(_ types: [AuditObjects.ObjectType]) async throws -> [ScopedObject] {
        var all: [ScopedObject] = []
        var pending: [(AuditObjects.ObjectType, String, String)] = []
        for type in types {
            if let cached = scopedCache[type.resource] { all += cached; continue }
            guard let entries = try await list(type) else { scopedCache[type.resource] = []; continue }
            for entry in entries {
                if type.onlySmartGroups && !AuditObjects.isTrue(entry.json["is_smart"]) { continue }
                pending.append((type, entry.id, entry.name))
            }
        }
        let read = try await readAll(pending, name: { $0.2 }) { item in try await self.record(item.0, id: item.1) }
        var fresh: [String: [ScopedObject]] = [:]
        var unreadable: [String: Int] = [:]
        for ((type, id, name), json) in read {
            if let json, let root = AuditObjects.rootObject(json) {
                fresh[type.resource, default: []].append(ScopedObject(type: type, id: id, name: name, root: root))
            } else {
                unreadable[type.plural, default: 0] += 1
            }
        }
        for type in types where scopedCache[type.resource] == nil {
            scopedCache[type.resource] = fresh[type.resource] ?? []
            all += fresh[type.resource] ?? []
        }
        for (plural, count) in unreadable.sorted(by: { $0.key < $1.key }) {
            let noun = plural.prefix(1).uppercased() + plural.dropFirst()
            warn("\(noun): \(count) couldn't be read, so \(count == 1 ? "it wasn't" : "they weren't") checked.")
        }
        return all
    }

    // MARK: Groups

    /// Every group of a kind (static and smart) with its members. Cached per run.
    func groups(_ kind: GroupKind) async throws -> [GroupRecord] {
        if let cached = groupCache[kind] { return cached }
        try Task.checkCancellation()
        await status("Listing \(kind.label.lowercased()) groups…")
        let entries: [(id: String, name: String, json: JSONValue)]
        do {
            entries = AuditObjects.entries(in: try await client.get("/JSSResource/\(kind.resource)"))
        } catch let error as ServiceError {
            warn(error.isPermissionDenied ? "Skipped \(kind.label.lowercased()) groups: your account can't read them."
                                          : "Skipped \(kind.label.lowercased()) groups: \(error.message)")
            groupCache[kind] = []
            return []
        }
        let read = try await readAll(entries, name: { $0.name }) { entry in
            try await self.client.get("/JSSResource/\(kind.resource)/id/\(entry.id)")
        }
        var records: [GroupRecord] = []
        var unreadable = 0
        for (entry, json) in read {
            guard let json, let root = AuditObjects.rootObject(json) else { unreadable += 1; continue }
            records.append(Self.groupRecord(root, kind: kind, id: entry.id, fallbackName: entry.name,
                                            isSmart: AuditObjects.isTrue(entry.json["is_smart"])))
        }
        if unreadable > 0 { warn("\(unreadable) \(kind.label.lowercased()) group(s) couldn't be read.") }
        groupCache[kind] = records
        return records
    }

    /// One group with its members (no list fetch).
    func group(_ kind: GroupKind, id: String) async throws -> GroupRecord {
        if let cached = groupCache[kind]?.first(where: { $0.id == id }) { return cached }
        await status("Reading group…")
        let json = try await client.get("/JSSResource/\(kind.resource)/id/\(id)")
        guard let root = AuditObjects.rootObject(json) else { throw ServiceError("The group record couldn't be read.") }
        return Self.groupRecord(root, kind: kind, id: id, fallbackName: "", isSmart: AuditObjects.isTrue(root["is_smart"]))
    }

    private static func groupRecord(_ root: JSONValue, kind: GroupKind, id: String, fallbackName: String,
                                    isSmart: Bool) -> GroupRecord {
        let members = AuditObjects.items(root[kind.membersKey]).compactMap { member -> GroupRecord.Member? in
            guard let memberID = AuditObjects.entryID(member) else { return nil }
            let body = member[kind == .computer ? "computer" : "mobile_device"] ?? member
            return GroupRecord.Member(id: memberID, name: AuditObjects.entryName(member),
                                      serial: body["serial_number"]?.text ?? "", udid: body["udid"]?.text ?? "",
                                      mac: (body["wifi_mac_address"] ?? body["mac_address"])?.text ?? "")
        }
        let name = root["name"]?.text ?? ""
        return GroupRecord(kind: kind, id: id, name: name.isEmpty ? fallbackName : name,
                           isSmart: isSmart || AuditObjects.isTrue(root["is_smart"]), members: members)
    }

    // MARK: Inventory (Jamf Pro API, paginated)

    /// Every device of a kind with the fields audits need. Cached per run.
    func inventory(_ kind: GroupKind) async throws -> [DeviceRecord] {
        if let cached = inventoryCache[kind] { return cached }
        let pageSize = 200
        let records: [JSONValue]
        switch kind {
        case .computer:
            let sections = ["GENERAL", "HARDWARE", "OPERATING_SYSTEM", "USER_AND_LOCATION", "DISK_ENCRYPTION"]
                .map { "section=\($0)" }.joined(separator: "&")
            // The endpoint is versioned; prefer the newest and fall back if the server doesn't have it.
            records = try await paged(paths: ["/api/v3/computers-inventory", "/api/v1/computers-inventory"],
                                      query: sections, pageSize: pageSize, noun: "computer inventory")
        case .mobile:
            let sections = ["GENERAL", "HARDWARE", "USER_AND_LOCATION"].map { "section=\($0)" }.joined(separator: "&")
            records = try await paged(paths: ["/api/v2/mobile-devices/detail"], query: sections,
                                      pageSize: pageSize, noun: "mobile device inventory")
        }
        let devices = records.compactMap { Self.device($0, kind: kind) }
        inventoryCache[kind] = devices
        return devices
    }

    private func paged(paths: [String], query: String, pageSize: Int, noun: String) async throws -> [JSONValue] {
        var lastError: Error?
        for path in paths {
            var collected: [JSONValue] = []
            var page = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let response = try await client.get("\(path)?\(query)&page=\(page)&page-size=\(pageSize)")
                    let results = response["results"]?.arrayValue ?? []
                    collected += results
                    let total = Int(response["totalCount"]?.text ?? "") ?? collected.count
                    await progress(AuditProgress(done: collected.count, total: max(total, collected.count),
                                                 message: "Reading \(noun): \(collected.count) of \(total)"))
                    if results.count < pageSize || collected.count >= total { return collected }
                    page += 1
                }
            } catch let error as ServiceError where error.isNotFound && page == 0 {
                lastError = error   // this API version isn't on the server; try the next
            }
        }
        throw lastError ?? ServiceError("Couldn't read \(noun).")
    }

    private static func device(_ json: JSONValue, kind: GroupKind) -> DeviceRecord? {
        let general = json["general"] ?? .emptyObject
        let hardware = json["hardware"] ?? .emptyObject
        let user = json["userAndLocation"] ?? .emptyObject
        func text(_ values: JSONValue?...) -> String { values.compactMap { $0?.text }.first { !$0.isEmpty } ?? "" }
        func flag(_ value: JSONValue?) -> Bool? {
            guard let value else { return nil }
            if case .bool(let b) = value { return b }
            return nil
        }
        let id = text(json["id"], json["mobileDeviceId"])
        guard !id.isEmpty else { return nil }
        var record: DeviceRecord
        switch kind {
        case .computer:
            let encryption = json["diskEncryption"] ?? .emptyObject
            record = DeviceRecord(
                kind: kind, id: id, name: text(general["name"]), serial: text(hardware["serialNumber"]),
                username: text(user["username"]), osVersion: text(json["operatingSystem"]?["version"]),
                managementID: text(general["managementId"]),
                lastSeen: parseJamfDate(text(general["lastContactTime"])),
                supervised: flag(general["supervised"]), managed: flag(general["remoteManagement"]?["managed"]),
                fileVaultEnabled: flag(encryption["fileVault2Enabled"]),
                fileVaultState: text(encryption["bootPartitionEncryptionDetails"]?["partitionFileVault2State"],
                                     json["operatingSystem"]?["fileVault2Status"]))
        case .mobile:
            record = DeviceRecord(
                kind: kind, id: id, name: text(general["displayName"], general["name"]),
                serial: text(hardware["serialNumber"]), username: text(user["username"]),
                osVersion: text(general["osVersion"]), managementID: text(general["managementId"]),
                lastSeen: parseJamfDate(text(general["lastInventoryUpdateDate"])),
                supervised: flag(general["supervised"]), managed: flag(general["managed"]),
                fileVaultEnabled: nil, fileVaultState: "")
        }
        record.buildingID = text(user["buildingId"])
        record.departmentID = text(user["departmentId"])
        record.building = text(user["buildingName"], user["building"])
        record.department = text(user["departmentName"], user["department"])
        return record
    }

    // MARK: MDM commands

    /// MDM commands in one state (e.g. "Pending", "Error"), newest first.
    /// Stops after `limit` commands and says so.
    func mdmCommands(state: String, limit: Int = 5000) async throws -> [MDMCommandRecord] {
        let pageSize = 200
        var collected: [JSONValue] = []
        // The filter's value spelling isn't pinned down by the API docs; try both.
        var lastError: Error?
        for value in [state, state.uppercased()] {
            collected = []
            var page = 0
            do {
                while collected.count < limit {
                    try Task.checkCancellation()
                    let filter = queryEscape("status==\(value)")
                    let response = try await client.get(
                        "/api/v2/mdm/commands?page=\(page)&page-size=\(pageSize)&sort=dateSent%3Adesc&filter=\(filter)")
                    let results = response["results"]?.arrayValue ?? []
                    collected += results
                    let total = Int(response["totalCount"]?.text ?? "") ?? collected.count
                    await progress(AuditProgress(done: collected.count, total: max(total, collected.count),
                                                 message: "Reading \(state.lowercased()) MDM commands: \(collected.count) of \(total)"))
                    if results.count < pageSize || collected.count >= total { break }
                    page += 1
                }
                if collected.count >= limit {
                    warn("Only the newest \(limit) \(state.lowercased()) MDM commands were read.")
                }
                lastError = nil
                break
            } catch let error as ServiceError where !error.isPermissionDenied && page == 0 {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return collected.map { command in
            let client = command["client"] ?? .emptyObject
            let error = command["commandError"] ?? .emptyObject
            let profile = command["profileId"]?.text ?? ""
            return MDMCommandRecord(
                managementID: client["managementId"]?.text ?? "", clientType: client["clientType"]?.text ?? "",
                state: command["commandState"]?.text ?? "", commandType: command["commandType"]?.text ?? "",
                dateSent: parseJamfDate(command["dateSent"]?.text ?? ""),
                profileID: profile.isEmpty || profile == "0" ? nil : profile,
                error: [error["errorEnglishDescription"]?.text, error["errorLocalizedDescription"]?.text]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? "")
        }
    }

    private func queryEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: Device records and history (classic API)

    func classicDevice(_ kind: GroupKind, id: String) async throws -> JSONValue {
        await status("Reading the device record…")
        let json = try await client.get("/JSSResource/\(kind.deviceResource)/id/\(id)")
        guard let root = AuditObjects.rootObject(json) else { throw ServiceError("The device record couldn't be read.") }
        return root
    }

    /// Which of the given Jamf user groups list `username` as a member.
    func userGroups(containing username: String, among ids: Set<String>) async throws -> Set<String> {
        guard !username.isEmpty else { return [] }
        return Set(try await userGroupMembers(ids).filter { $0.value.contains(username) }.keys)
    }

    /// The members (lower-cased usernames) of each of the given Jamf user groups.
    /// Groups that can't be read are left out, with a warning.
    func userGroupMembers(_ ids: Set<String>) async throws -> [String: Set<String>] {
        guard !ids.isEmpty else { return [:] }
        let read = try await readAll(ids.sorted(), verb: "Reading user groups", name: { "user group \($0)" }) { id in
            try await self.client.get("/JSSResource/usergroups/id/\(id)")
        }
        var members: [String: Set<String>] = [:], unreadable = 0
        for (id, json) in read {
            guard let json, let root = AuditObjects.rootObject(json) else { unreadable += 1; continue }
            members[id] = Set(AuditObjects.items(root["users"]).compactMap { ($0["username"] ?? $0["name"])?.text.lowercased() })
        }
        if unreadable > 0 {
            warn("\(unreadable) user group(s) couldn't be read, so targets and exclusions through them weren't checked.")
        }
        return members
    }

    /// Specific device groups with their members, read a few at a time.
    /// Groups that can't be read are left out, with a warning.
    func groups(_ kind: GroupKind, ids: Set<String>) async throws -> [String: GroupRecord] {
        guard !ids.isEmpty else { return [:] }
        if let cached = groupCache[kind] { return Dictionary(cached.filter { ids.contains($0.id) }.map { ($0.id, $0) }) { a, _ in a } }
        let read = try await readAll(ids.sorted(), verb: "Reading \(kind.label.lowercased()) groups", name: { "group \($0)" }) { id in
            try await self.client.get("/JSSResource/\(kind.resource)/id/\(id)")
        }
        var records: [String: GroupRecord] = [:], unreadable = 0
        for (id, json) in read {
            guard let json, let root = AuditObjects.rootObject(json) else { unreadable += 1; continue }
            records[id] = Self.groupRecord(root, kind: kind, id: id, fallbackName: "", isSmart: false)
        }
        if unreadable > 0 {
            warn("\(unreadable) \(kind.label.lowercased()) group(s) couldn't be read, so targets and exclusions through them weren't checked.")
        }
        return records
    }

    /// Policy log entries for each computer (classic computer history).
    func policyLogs(_ computers: [DeviceRecord]) async throws -> [(DeviceRecord, [JSONValue])] {
        let read = try await readAll(computers, verb: "Reading policy history", name: { $0.name }) { device in
            try await self.client.get("/JSSResource/computerhistory/id/\(device.id)/subset/PolicyLogs")
        }
        var unreadable = 0
        let logs = read.map { device, json -> (DeviceRecord, [JSONValue]) in
            guard let json else { unreadable += 1; return (device, []) }
            let root = AuditObjects.rootObject(json) ?? json
            return (device, root["policy_logs"]?.arrayValue ?? [])
        }
        if unreadable > 0 { warn("Policy history for \(unreadable) computer(s) couldn't be read.") }
        return logs
    }
}

/// Jamf dates arrive as ISO 8601 with or without fractional seconds or a zone.
func parseJamfDate(_ text: String) -> Date? {
    guard !text.isEmpty else { return nil }
    if let date = parseISO8601(text) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}

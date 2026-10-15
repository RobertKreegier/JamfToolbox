import Foundation

enum AuditCategory: String, CaseIterable, Identifiable {
    case groups = "Static Groups"
    case profiles = "Configuration Profiles"
    case health = "Device Health"
    case policies = "Policies"

    var id: String { rawValue }
}

/// What a report asks for before it runs.
enum AuditInput: Hashable {
    case kind          // computers or mobile devices
    case group         // a static group of the chosen kind
    case device        // a device from the working list of the chosen kind
    case days
    case osVersion
    case pastedList
    case threshold
}

/// What a report produced; the runner turns it into a saved `AuditResult`.
struct AuditOutput {
    var findings: [AuditFinding]
    var scanned: Int
    var subject: AuditSubject? = nil
    var subtitle: String
    var warnings: [String] = []
}

struct AuditReport: Identifiable {
    let id: String
    let category: AuditCategory
    let title: String
    let summary: String
    let inputs: [AuditInput]
    /// Which device kinds the kind picker offers (one entry hides the picker).
    var kinds: [GroupKind] = GroupKind.allCases
    let detailHeading: String
    let run: (AuditContext, AuditParameters) async throws -> AuditOutput

    func needs(_ input: AuditInput) -> Bool { inputs.contains(input) }
}

/// The audit catalog and the runner. Every report is read-only.
enum AuditReports {
    static let groupDependenciesID = "group-dependencies"

    static func report(_ id: String) -> AuditReport? { all.first { $0.id == id } }
    static func reports(in category: AuditCategory) -> [AuditReport] { all.filter { $0.category == category } }

    /// Runs a report and packages the outcome for saving.
    static func run(_ report: AuditReport, parameters: AuditParameters, client: JamfClient,
                    progress: @escaping @MainActor (AuditProgress) -> Void) async throws -> AuditResult {
        let context = AuditContext(client: client, progress: progress)
        let output = try await report.run(context, parameters)
        return AuditResult(reportID: report.id, report: report.title, runAt: Date(), server: client.baseURL,
                           subject: output.subject, subtitle: output.subtitle, detailHeading: report.detailHeading,
                           parameters: parameters, findings: output.findings,
                           warnings: context.warnings + output.warnings, objectsScanned: output.scanned)
    }

    // MARK: Catalog

    static let all: [AuditReport] = [
        // Static groups
        AuditReport(id: groupDependenciesID, category: .groups, title: "Group Dependencies",
                    summary: "Everything that depends on a static group: what it's scoped to, excluded from, or limited by, and any smart group or advanced search whose criteria name it. Use before renaming or deleting a group.",
                    inputs: [.kind, .group], detailHeading: "Relationship", run: groupDependencies),
        AuditReport(id: "groups-empty", category: .groups, title: "Empty Groups",
                    summary: "Static and smart groups, computer and mobile, that have no members.",
                    inputs: [], detailHeading: "Issue", run: emptyGroups),
        AuditReport(id: "groups-unused", category: .groups, title: "Unused Groups",
                    summary: "Groups nothing refers to: not in the scope, exclusions or limitations of any policy, profile, app, eBook or restricted software, and not named by any smart group or advanced search.",
                    inputs: [], detailHeading: "Issue", run: unusedGroups),
        AuditReport(id: "groups-stale-members", category: .groups, title: "Stale Group Members",
                    summary: "Members of a static group that haven't checked in (computers) or updated inventory (mobile devices) for a number of days.",
                    inputs: [.kind, .group, .days], detailHeading: "Last seen", run: staleGroupMembers),
        AuditReport(id: "groups-duplicate-names", category: .groups, title: "Duplicate Group Names",
                    summary: "Groups whose names are the same or nearly the same (ignoring case, spaces and punctuation, or one or two letters apart), which are easy to pick by mistake.",
                    inputs: [], detailHeading: "Similar to", run: duplicateGroupNames),
        AuditReport(id: "groups-compare-list", category: .groups, title: "Compare Group to a List",
                    summary: "Compares a static group's members with a pasted list or CSV column of serial numbers, names, UDIDs or MAC addresses: who's missing from the group, and who's in it but not on your list.",
                    inputs: [.kind, .group, .pastedList], detailHeading: "Difference", run: compareGroupToList),
        AuditReport(id: "groups-device-memberships", category: .groups, title: "Device's Group Memberships",
                    summary: "Every static and smart group one device belongs to.",
                    inputs: [.kind, .device], detailHeading: "Membership", run: deviceGroupMemberships),

        // Configuration profiles
        AuditReport(id: "profiles-scope-gaps", category: .profiles, title: "Unscoped or Scoped to All",
                    summary: "Profiles with no scope (they install nowhere), and profiles scoped to every device with no exclusions.",
                    inputs: [], detailHeading: "Issue", run: profileScopeGaps),
        AuditReport(id: "profiles-devices-targeted-excluded", category: .profiles, title: "Devices Targeted and Excluded",
                    summary: "Every device that a profile both targets and excludes, by any route: for example targeted through one group and excluded through another, or targeted to all devices and excluded through the device's user, user group, building or department. The exclusion wins, so these devices don't get the profile.",
                    inputs: [.kind], detailHeading: "Targeted", run: devicesTargetedAndExcluded),
        AuditReport(id: "profiles-bad-groups", category: .profiles, title: "Deleted or Empty Groups in Scope",
                    summary: "Profiles whose scope or exclusions point at a group that no longer exists, or that target an empty group.",
                    inputs: [], detailHeading: "Issue", run: profileBadGroups),
        AuditReport(id: "profiles-overlap", category: .profiles, title: "Overlapping Payloads",
                    summary: "Pairs of profiles that configure the same payload type for overlapping devices, which can conflict. Payload types designed to stack (Wi-Fi, certificates, VPN, web clips, fonts, accounts) are ignored.",
                    inputs: [.kind], detailHeading: "Overlap", run: profileOverlap),
        AuditReport(id: "profiles-install-status", category: .profiles, title: "Failed or Pending Installs",
                    summary: "Profiles with failed or pending install commands, from Jamf Pro's MDM command history.",
                    inputs: [], detailHeading: "Install status", run: profileInstallStatus),
        AuditReport(id: "profiles-device", category: .profiles, title: "Device's Profiles vs. Scope",
                    summary: "Compares the profiles installed on one device with the profiles scoped to it: what's missing, and what's installed but no longer scoped.",
                    inputs: [.kind, .device], detailHeading: "Status", run: deviceProfiles),
        AuditReport(id: "profiles-device-targeting", category: .profiles, title: "Device's Config Profiles in Scope",
                    summary: "Every configuration profile that targets, excludes or is installed on one device, and how it applies: to all devices, through a static or smart group, directly, or through the device's assigned user, the user's groups, or its building or department. Right-click profiles to exclude the device from them or remove a direct target.",
                    inputs: [.kind, .device], detailHeading: "Targeting", run: deviceProfileTargeting),

        // Device health
        AuditReport(id: "health-stale", category: .health, title: "Stale Check-in",
                    summary: "Devices that haven't checked in (computers) or updated inventory (mobile devices) for a number of days.",
                    inputs: [.kind, .days], detailHeading: "Last seen", run: staleDevices),
        AuditReport(id: "health-unsupervised", category: .health, title: "Unsupervised Mobile Devices",
                    summary: "Managed mobile devices that aren't supervised, so supervised-only commands and restrictions don't apply.",
                    inputs: [], kinds: [.mobile], detailHeading: "Issue", run: unsupervisedDevices),
        AuditReport(id: "health-os", category: .health, title: "OS Below Target",
                    summary: "Devices running an operating system older than the version you enter.",
                    inputs: [.kind, .osVersion], detailHeading: "OS version", run: osBelowTarget),
        AuditReport(id: "health-filevault", category: .health, title: "FileVault Off",
                    summary: "Computers whose boot volume isn't fully encrypted with FileVault.",
                    inputs: [], kinds: [.computer], detailHeading: "FileVault", run: fileVaultOff),
        AuditReport(id: "health-no-user", category: .health, title: "No Assigned User",
                    summary: "Devices with no username in User and Location.",
                    inputs: [.kind], detailHeading: "Issue", run: noAssignedUser),
        AuditReport(id: "health-duplicate-serials", category: .health, title: "Duplicate Serial Numbers",
                    summary: "Serial numbers that appear on more than one device record, usually from re-enrollment.",
                    inputs: [], detailHeading: "Duplicate", run: duplicateSerials),
        AuditReport(id: "health-pending-commands", category: .health, title: "Pending MDM Commands",
                    summary: "Devices with at least the number of MDM commands you choose waiting to be delivered.",
                    inputs: [.threshold], detailHeading: "Pending commands", run: pendingCommands),

        // Policies
        AuditReport(id: "policies-disabled-scoped", category: .policies, title: "Disabled but Still Scoped",
                    summary: "Disabled policies that still have a scope, which is easy to mistake for an active policy.",
                    inputs: [], kinds: [.computer], detailHeading: "Issue", run: disabledScopedPolicies),
        AuditReport(id: "policies-no-scope", category: .policies, title: "Enabled with No Scope",
                    summary: "Enabled policies that are scoped to nothing, so they never run.",
                    inputs: [], kinds: [.computer], detailHeading: "Issue", run: unscopedPolicies),
        AuditReport(id: "policies-failures", category: .policies, title: "Recent Failures",
                    summary: "Policies that failed on computers within a number of days, from each computer's policy history. Reads every computer's history, so it takes longer than the other reports.",
                    inputs: [.days], kinds: [.computer], detailHeading: "Failures", run: recentPolicyFailures),
        AuditReport(id: "policies-ongoing-no-trigger", category: .policies, title: "Ongoing with No Trigger",
                    summary: "Policies set to run Ongoing that have no trigger and aren't in Self Service, so nothing ever runs them.",
                    inputs: [], kinds: [.computer], detailHeading: "Issue", run: ongoingWithoutTrigger),
    ]

    // MARK: Helpers

    private static func deviceFinding(_ device: DeviceRecord, _ detail: String) -> AuditFinding {
        AuditFinding(objectType: device.objectType, objectName: device.name.isEmpty ? device.serial : device.name,
                     objectID: device.id, detail: detail)
    }

    private static func objectFinding(_ object: ScopedObject, _ detail: String) -> AuditFinding {
        AuditFinding(objectType: object.type.label, objectName: object.name, objectID: object.id, detail: detail,
                     webPage: object.type.webPage)
    }

    private static func groupFinding(_ group: GroupRecord, _ detail: String) -> AuditFinding {
        AuditFinding(objectType: group.objectType, objectName: group.name, objectID: group.id, detail: detail,
                     webPage: group.isSmart ? (group.kind == .computer ? AuditObjects.smartComputerGroup.webPage
                                                                        : AuditObjects.smartMobileGroup.webPage)
                                            : nil)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func lastSeenText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        return "\(dayFormat.string(from: date)) (\(days) day\(days == 1 ? "" : "s") ago)"
    }

    private static func requireGroup(_ p: AuditParameters) throws -> String {
        guard let id = p.groupID, !id.isEmpty else { throw ServiceError("Choose a group first.") }
        return id
    }

    private static func requireDevice(_ p: AuditParameters) throws -> String {
        guard let id = p.deviceID, !id.isEmpty else { throw ServiceError("Choose a device first.") }
        return id
    }

    private static func sortFindings(_ findings: [AuditFinding]) -> [AuditFinding] {
        findings.sorted {
            $0.objectType != $1.objectType ? $0.objectType < $1.objectType
                : $0.objectName.localizedStandardCompare($1.objectName) == .orderedAscending
        }
    }

    // MARK: - Static groups

    static func groupDependencies(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let groupID = try requireGroup(p)
        let group = try await context.group(p.kind, id: groupID)
        let name = group.name.isEmpty ? (p.groupName ?? groupID) : group.name
        let objects = try await context.scopedObjects(AuditObjects.scopedTypes.filter { $0.kinds.contains(p.kind) })
        var findings: [AuditFinding] = []
        for object in objects {
            if object.type.resource == p.kind.resource && object.id == groupID { continue }
            for reference in ScopeReading.groupReferences(in: object.root, kind: p.kind)
            where ScopeReading.reference(reference, matches: groupID, name: name) {
                findings.append(objectFinding(object, reference.relationship))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: AuditObjects.scopedTypes.enumerated().map { ($1.label, $0) })
        findings.sort {
            let a = order[$0.objectType] ?? 99, b = order[$1.objectType] ?? 99
            return a != b ? a < b : $0.objectName.localizedStandardCompare($1.objectName) == .orderedAscending
        }
        return AuditOutput(findings: findings, scanned: objects.count,
                           subject: AuditSubject(kind: p.kind, id: groupID, name: name, memberCount: group.members.count),
                           subtitle: "\(p.kind.label) static group · \(group.members.count) member(s)")
    }

    static func emptyGroups(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        var findings: [AuditFinding] = []
        var scanned = 0
        for kind in GroupKind.allCases {
            let groups = try await context.groups(kind)
            scanned += groups.count
            findings += groups.filter { $0.members.isEmpty }.map { groupFinding($0, "No members") }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: scanned, subtitle: "All computer and mobile device groups")
    }

    static func unusedGroups(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let objects = try await context.scopedObjects(AuditObjects.scopedTypes)
        var findings: [AuditFinding] = []
        var scanned = 0
        for kind in GroupKind.allCases {
            let groups = try await context.groups(kind)
            scanned += groups.count
            let references = objects.flatMap { object in
                ScopeReading.groupReferences(in: object.root, kind: kind).map { (object, $0) }
            }
            for group in groups {
                let used = references.contains { object, reference in
                    // A smart group's own criteria don't count as using it.
                    !(object.type.resource == kind.resource && object.id == group.id)
                        && ScopeReading.reference(reference, matches: group.id, name: group.name)
                }
                if !used { findings.append(groupFinding(group, "Not referenced anywhere")) }
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: scanned,
                           subtitle: "All groups, checked against \(objects.count) scoped objects")
    }

    static func staleGroupMembers(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let groupID = try requireGroup(p)
        let group = try await context.group(p.kind, id: groupID)
        let inventory = Dictionary(try await context.inventory(p.kind).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cutoff = Date().addingTimeInterval(-Double(p.days) * 86_400)
        var findings: [AuditFinding] = []
        for member in group.members {
            guard let device = inventory[member.id] else {
                findings.append(AuditFinding(objectType: p.kind.label, objectName: member.name, objectID: member.id,
                                             detail: "Not found in inventory"))
                continue
            }
            if (device.lastSeen ?? .distantPast) < cutoff {
                findings.append(deviceFinding(device, lastSeenText(device.lastSeen)))
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: group.members.count,
                           subject: AuditSubject(kind: p.kind, id: groupID, name: group.name, memberCount: group.members.count),
                           subtitle: "\(p.kind.label) static group · not seen in \(p.days) days")
    }

    /// Lower-case letters and digits only.
    private static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func duplicateGroupNames(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        var findings: [AuditFinding] = []
        var scanned = 0
        for kind in GroupKind.allCases {
            await context.status("Listing \(kind.label.lowercased()) groups…")
            let entries: [(id: String, name: String, json: JSONValue)]
            do {
                entries = AuditObjects.entries(in: try await context.client.get("/JSSResource/\(kind.resource)"))
            } catch let error as ServiceError {
                context.warn("Skipped \(kind.label.lowercased()) groups: \(error.isPermissionDenied ? "your account can't read them." : error.message)")
                continue
            }
            scanned += entries.count
            let keys = entries.map { normalized($0.name) }
            for i in entries.indices {
                var similar: [String] = []
                for j in entries.indices where i != j {
                    let same = keys[i] == keys[j]
                    let near = min(keys[i].count, keys[j].count) >= 6 && editDistance(keys[i], keys[j]) <= 2
                    if same || near { similar.append("“\(entries[j].name)”") }
                }
                if !similar.isEmpty {
                    let group = entries[i]
                    let smart = AuditObjects.isTrue(group.json["is_smart"])
                    findings.append(AuditFinding(objectType: kind.groupLabel(smart: smart), objectName: group.name,
                                                 objectID: group.id, detail: similar.joined(separator: ", "),
                                                 webPage: smart ? (kind == .computer ? AuditObjects.smartComputerGroup.webPage
                                                                                     : AuditObjects.smartMobileGroup.webPage) : nil))
                }
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: scanned, subtitle: "All computer and mobile device groups")
    }

    /// Splits a pasted list or CSV into values: one per line, first column.
    static func pastedValues(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let first = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == ";" }).first.map(String.init) ?? ""
            let value = first.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    static func compareGroupToList(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let groupID = try requireGroup(p)
        let values = pastedValues(p.pastedList)
        guard !values.isEmpty else { throw ServiceError("Paste at least one serial number, name, UDID or MAC address.") }
        let group = try await context.group(p.kind, id: groupID)

        func keys(_ member: GroupRecord.Member) -> Set<String> {
            Set([member.serial, member.name, member.udid, normalizeMAC(member.mac)].filter { !$0.isEmpty }.map { $0.lowercased() })
        }
        let memberKeys = group.members.map { ($0, keys($0)) }
        var matched = Set<String>()
        var findings: [AuditFinding] = []
        var unmatchedHeader = false
        for (index, value) in values.enumerated() {
            let candidates: Set<String> = [value.lowercased(), normalizeMAC(value)]
            if let hit = memberKeys.first(where: { !$0.1.isDisjoint(with: candidates) }) {
                matched.insert(hit.0.id)
            } else if index == 0 && ["serial", "serial number", "name", "udid", "mac", "mac address", "device"]
                        .contains(value.lowercased()) {
                unmatchedHeader = true   // a CSV header row, not a device
            } else {
                findings.append(AuditFinding(objectType: "Pasted Entry", objectName: value, objectID: "",
                                             detail: "On your list, not in the group"))
            }
        }
        for member in group.members where !matched.contains(member.id) {
            findings.append(AuditFinding(objectType: p.kind.label, objectName: member.name.isEmpty ? member.serial : member.name,
                                         objectID: member.id, detail: "In the group, not on your list"))
        }
        let listCount = values.count - (unmatchedHeader ? 1 : 0)
        return AuditOutput(findings: findings, scanned: group.members.count + listCount,
                           subject: AuditSubject(kind: p.kind, id: groupID, name: group.name, memberCount: group.members.count),
                           subtitle: "\(group.members.count) member(s) compared with \(listCount) listed")
    }

    static func deviceGroupMemberships(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let deviceID = try requireDevice(p)
        let record = try await context.classicDevice(p.kind, id: deviceID)
        let name = record["general"]?["name"]?.text ?? p.deviceName ?? deviceID
        await context.status("Listing \(p.kind.label.lowercased()) groups…")
        let groups = AuditObjects.entries(in: (try? await context.client.get("/JSSResource/\(p.kind.resource)")) ?? .emptyObject)
        func smart(id: String?, name: String) -> Bool {
            let match = groups.first { $0.id == id } ?? groups.first { $0.name == name }
            return AuditObjects.isTrue(match?.json["is_smart"])
        }
        var findings: [AuditFinding] = []
        switch p.kind {
        case .computer:
            // Classic computer records list membership by name only.
            for item in AuditObjects.items(record["groups_accounts"]?["computer_group_memberships"]) {
                let groupName = item.text.isEmpty ? AuditObjects.entryName(item) : item.text
                guard !groupName.isEmpty else { continue }
                let id = groups.first { $0.name == groupName }?.id ?? ""
                let isSmart = smart(id: nil, name: groupName)
                findings.append(AuditFinding(objectType: p.kind.groupLabel(smart: isSmart), objectName: groupName, objectID: id,
                                             detail: isSmart ? "Matches the smart group's criteria" : "Static member",
                                             webPage: isSmart ? AuditObjects.smartComputerGroup.webPage : nil))
            }
        case .mobile:
            for item in AuditObjects.items(record["mobile_device_groups"]) {
                let id = AuditObjects.entryID(item)
                let groupName = AuditObjects.entryName(item)
                let isSmart = smart(id: id, name: groupName)
                findings.append(AuditFinding(objectType: p.kind.groupLabel(smart: isSmart), objectName: groupName,
                                             objectID: id ?? "", detail: isSmart ? "Matches the smart group's criteria" : "Static member",
                                             webPage: isSmart ? AuditObjects.smartMobileGroup.webPage : nil))
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: findings.count,
                           subject: AuditSubject(kind: p.kind, id: deviceID, name: name), subtitle: "\(p.kind.label) · group memberships")
    }

    // MARK: - Configuration profiles

    private static func profiles(_ context: AuditContext, kinds: [GroupKind]) async throws -> [(GroupKind, ScopedObject)] {
        var result: [(GroupKind, ScopedObject)] = []
        for kind in kinds {
            result += try await context.scopedObjects([AuditObjects.profileType(kind)]).map { (kind, $0) }
        }
        return result
    }

    static func profileScopeGaps(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await profiles(context, kinds: GroupKind.allCases)
        var findings: [AuditFinding] = []
        for (kind, profile) in all {
            let scope = ScopeReading.scope(of: profile.root, kind: kind)
            if scope.isEmpty {
                findings.append(objectFinding(profile, "No scope: installs on nothing"))
            } else if scope.all && !scope.hasExclusions {
                findings.append(objectFinding(profile, "Scoped to all \(kind.pluralLabel) with no exclusions"))
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count, subtitle: "All configuration profiles")
    }

    static func profileBadGroups(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await profiles(context, kinds: GroupKind.allCases)
        var groupsByKind: [GroupKind: [String: GroupRecord]] = [:]
        for kind in GroupKind.allCases {
            groupsByKind[kind] = Dictionary(try await context.groups(kind).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var findings: [AuditFinding] = []
        for (kind, profile) in all {
            let groups = groupsByKind[kind] ?? [:]
            guard !groups.isEmpty else { continue }   // couldn't read groups; already warned
            let scope = ScopeReading.scope(of: profile.root, kind: kind)
            for (id, name) in scope.groups.sorted(by: { $0.key < $1.key }) {
                if let group = groups[id] {
                    if group.members.isEmpty { findings.append(objectFinding(profile, "Targets empty group “\(group.name)”")) }
                } else {
                    findings.append(objectFinding(profile, "Targets deleted group “\(name.isEmpty ? "ID \(id)" : name)”"))
                }
            }
            for (id, name) in scope.excludedGroups.sorted(by: { $0.key < $1.key }) where groups[id] == nil {
                findings.append(objectFinding(profile, "Excludes deleted group “\(name.isEmpty ? "ID \(id)" : name)”"))
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count, subtitle: "All configuration profiles")
    }

    /// Payload types meant to be installed several times side by side.
    static let stackingPayloadTypes: Set<String> = [
        "com.apple.wifi.managed", "com.apple.security.pkcs1", "com.apple.security.pkcs12", "com.apple.security.root",
        "com.apple.security.pem", "com.apple.security.scep", "com.apple.security.acme", "com.apple.vpn.managed",
        "com.apple.vpn.managed.applayer", "com.apple.webClip.managed", "com.apple.font", "com.apple.mail.managed",
        "com.apple.eas.account", "com.apple.ldap.account", "com.apple.caldav.account", "com.apple.carddav.account",
        "com.apple.subscribedcalendar.account", "com.apple.airprint", "com.apple.TCC.configuration-profile-policy",
        "com.apple.google-oauth", "com.apple.cellularprivatenetwork.managed",
    ]

    /// PayloadType values inside a profile's payload plist (top-level "Configuration" excluded).
    static func payloadTypes(_ profile: JSONValue) -> Set<String> {
        let plist = profile["general"]?["payloads"]?.text ?? ""
        guard !plist.isEmpty,
              let regex = try? NSRegularExpression(pattern: "<key>PayloadType</key>\\s*<string>([^<]+)</string>") else { return [] }
        let ns = plist as NSString
        return Set(regex.matches(in: plist, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
            .filter { $0 != "Configuration" })
    }

    static func profileOverlap(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await context.scopedObjects([AuditObjects.profileType(p.kind)])
        let prepared = all.map { profile in
            (profile, ScopeReading.scope(of: profile.root, kind: p.kind),
             payloadTypes(profile.root).subtracting(stackingPayloadTypes))
        }
        var findings: [AuditFinding] = []
        for i in prepared.indices {
            for j in prepared.indices where j > i {
                let (a, scopeA, typesA) = prepared[i], (b, scopeB, typesB) = prepared[j]
                let shared = typesA.intersection(typesB)
                guard !shared.isEmpty, !scopeA.isEmpty, !scopeB.isEmpty else { continue }
                var overlap: String?
                if scopeA.all || scopeB.all {
                    overlap = scopeA.all && scopeB.all ? "both scoped to all" : "one is scoped to all"
                } else if let group = scopeA.groups.keys.first(where: { scopeB.groups[$0] != nil }) {
                    overlap = "both target “\(scopeA.groups[group] ?? group)”"
                } else if !scopeA.devices.isDisjoint(with: scopeB.devices) {
                    overlap = "\(scopeA.devices.intersection(scopeB.devices).count) device(s) targeted by both"
                }
                guard let overlap else { continue }
                findings.append(objectFinding(a, "\(shared.sorted().joined(separator: ", ")) also set by “\(b.name)” (\(overlap))"))
            }
        }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count,
                           subtitle: "\(p.kind.label) configuration profiles",
                           warnings: findings.isEmpty ? [] : ["Overlap is judged from direct device and group targets; buildings, departments, users and smart-group membership aren't evaluated."])
    }

    static func profileInstallStatus(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let failed = try await context.mdmCommands(state: "Error")
        let pending = try await context.mdmCommands(state: "Pending")
        // Profile names, by id, for both kinds.
        var names: [String: (AuditObjects.ObjectType, String)] = [:]
        for kind in GroupKind.allCases {
            let type = AuditObjects.profileType(kind)
            for entry in try await context.list(type) ?? [] { names["\(kind.rawValue)|\(entry.id)"] = (type, entry.name) }
        }
        var tally: [String: (failed: Set<String>, pending: Set<String>, errors: Set<String>)] = [:]
        func key(_ command: MDMCommandRecord) -> String? {
            guard let profile = command.profileID else { return nil }
            return "\(command.clientType == "COMPUTER" || command.clientType == "COMPUTER_USER" ? "computer" : "mobile")|\(profile)"
        }
        for command in failed { if let k = key(command) {
            tally[k, default: ([], [], [])].failed.insert(command.managementID)
            if !command.error.isEmpty { tally[k]?.errors.insert(command.error) }
        } }
        for command in pending { if let k = key(command) { tally[k, default: ([], [], [])].pending.insert(command.managementID) } }

        let findings = tally.map { key, counts -> AuditFinding in
            let parts = key.split(separator: "|").map(String.init)
            let kind = GroupKind(rawValue: parts[0]) ?? .mobile
            let (type, name) = names[key] ?? (AuditObjects.profileType(kind), "Profile ID \(parts[1])")
            var detail = [counts.failed.isEmpty ? nil : "\(counts.failed.count) failed",
                          counts.pending.isEmpty ? nil : "\(counts.pending.count) pending"]
                .compactMap { $0 }.joined(separator: ", ")
            if let error = counts.errors.sorted().first { detail += " — \(error)" }
            return AuditFinding(objectType: type.label, objectName: name, objectID: parts[1], detail: detail, webPage: type.webPage)
        }
        return AuditOutput(findings: sortFindings(findings), scanned: failed.count + pending.count,
                           subtitle: "MDM command history: \(failed.count) failed, \(pending.count) pending commands read")
    }

    /// What a device's classic record says about its groups and installed profiles.
    struct DeviceFacts {
        let id: String
        let name: String
        let groupIDs: Set<String>
        /// Lower-cased; computer records list memberships by name only.
        let groupNames: Set<String>
        let installed: [(id: String, name: String, uuid: String)]
        /// The assigned user's username, lower-cased ("" if none).
        let username: String
        /// From User and Location, as names ("" if none).
        let building: String
        let department: String
        /// The Jamf user groups (ids) the assigned user belongs to, among those
        /// the profiles refer to. Filled in by `loadUserGroups`.
        var userGroupIDs: Set<String> = []
        /// Building and department ids, when known (the Jamf Pro API inventory has them).
        var buildingID = ""
        var departmentID = ""

        /// How the device's assigned user, building and department reach a
        /// profile's scope: "user “jdoe”", "department “Tech”", ….
        struct LocationMatch {
            var targets: [String] = []
            var exclusions: [String] = []
            var targetedByUser = false
            var excludedByUser = false
        }

        func locationMatch(_ scope: ScopeReading.Scope) -> LocationMatch {
            var match = LocationMatch()
            /// The scope entry's name if the device's building/department is in `list` (by id, else name).
            func find(_ list: [String: String], id: String, name: String) -> String? {
                if !id.isEmpty, let found = list[id] { return found.isEmpty ? name : found }
                guard !name.isEmpty else { return nil }
                return list.values.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            if !username.isEmpty && scope.users.contains(username) {
                match.targetedByUser = true
                match.targets.append("user “\(username)”")
            }
            if let found = find(scope.buildings, id: buildingID, name: building) { match.targets.append("building “\(found)”") }
            if let found = find(scope.departments, id: departmentID, name: department) { match.targets.append("department “\(found)”") }
            if scope.allUsers && !username.isEmpty { match.targets.append("all users") }
            for (id, name) in scope.userGroups.sorted(by: { $0.value < $1.value }) where userGroupIDs.contains(id) {
                match.targets.append("user group “\(name)”")
            }
            if !username.isEmpty && scope.excludedUsers.contains(username) {
                match.excludedByUser = true
                match.exclusions.append("user “\(username)”")
            }
            if let found = find(scope.excludedBuildings, id: buildingID, name: building) { match.exclusions.append("building “\(found)”") }
            if let found = find(scope.excludedDepartments, id: departmentID, name: department) {
                match.exclusions.append("department “\(found)”")
            }
            for (id, name) in scope.excludedUserGroups.sorted(by: { $0.value < $1.value }) where userGroupIDs.contains(id) {
                match.exclusions.append("user group “\(name)”")
            }
            return match
        }

        func inGroup(_ id: String, _ name: String) -> Bool {
            groupIDs.contains(id) || (!name.isEmpty && groupNames.contains(name.lowercased()))
        }

        /// The installed entry that is this Jamf profile, if any.
        func installedIndex(of profile: ScopedObject, kind: GroupKind) -> Int? {
            let uuid = profile.root["general"]?["uuid"]?.text ?? ""
            return installed.firstIndex { item in
                (!item.id.isEmpty && item.id == profile.id && kind == .computer)
                    || (!uuid.isEmpty && item.uuid == uuid)
                    || (!item.name.isEmpty && item.name == profile.name)
            }
        }
    }

    static func deviceFacts(_ context: AuditContext, _ p: AuditParameters) async throws -> DeviceFacts {
        let deviceID = try requireDevice(p)
        let record = try await context.classicDevice(p.kind, id: deviceID)
        let name = record["general"]?[p.kind == .computer ? "name" : "display_name"]?.text
            ?? record["general"]?["name"]?.text ?? p.deviceName ?? deviceID
        var groupIDs = Set<String>(), groupNames = Set<String>()
        if p.kind == .computer {
            for item in AuditObjects.items(record["groups_accounts"]?["computer_group_memberships"]) {
                let n = item.text.isEmpty ? AuditObjects.entryName(item) : item.text
                if !n.isEmpty { groupNames.insert(n.lowercased()) }
            }
        } else {
            for item in AuditObjects.items(record["mobile_device_groups"]) {
                if let id = AuditObjects.entryID(item) { groupIDs.insert(id) }
                groupNames.insert(AuditObjects.entryName(item).lowercased())
            }
        }
        let installed = AuditObjects.items(record["configuration_profiles"]).map { item -> (id: String, name: String, uuid: String) in
            (AuditObjects.entryID(item) ?? "", (item["display_name"] ?? item["name"])?.text ?? "", item["uuid"]?.text ?? "")
        }
        let username = (record["location"]?["username"]?.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        func location(_ key: String) -> String {
            (record["location"]?[key]?.text ?? "").trimmingCharacters(in: .whitespaces)
        }
        return DeviceFacts(id: deviceID, name: name, groupIDs: groupIDs, groupNames: groupNames, installed: installed,
                           username: username, building: location("building"), department: location("department"))
    }

    /// Looks up which user groups the profiles refer to contain the device's user.
    static func loadUserGroups(_ device: inout DeviceFacts, _ profiles: [ScopedObject], kind: GroupKind,
                               _ context: AuditContext) async throws {
        var ids = Set<String>()
        for profile in profiles {
            let scope = ScopeReading.scope(of: profile.root, kind: kind)
            ids.formUnion(scope.userGroups.keys)
            ids.formUnion(scope.excludedUserGroups.keys)
        }
        device.userGroupIDs = try await context.userGroups(containing: device.username,
                                                           among: ids.filter { !$0.hasPrefix("#") })
    }

    static func deviceProfiles(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        var device = try await deviceFacts(context, p)
        let profiles = try await context.scopedObjects([AuditObjects.profileType(p.kind)])
        try await loadUserGroups(&device, profiles, kind: p.kind, context)
        let deviceID = device.id, name = device.name, installed = device.installed
        func inGroup(_ id: String, _ groupName: String) -> Bool { device.inGroup(id, groupName) }

        var findings: [AuditFinding] = []
        var matchedInstalled = Set<Int>()
        for profile in profiles {
            let scope = ScopeReading.scope(of: profile.root, kind: p.kind)
            let location = device.locationMatch(scope)
            let excluded = scope.excludedDevices.contains(deviceID)
                || scope.excludedGroups.contains { inGroup($0.key, $0.value) } || !location.exclusions.isEmpty
            let targeted = scope.all || scope.devices.contains(deviceID) || scope.groups.contains { inGroup($0.key, $0.value) }
                || !location.targets.isEmpty
            let expected = targeted && !excluded
            let installedIndex = device.installedIndex(of: profile, kind: p.kind)
            if let installedIndex { matchedInstalled.insert(installedIndex) }

            if expected && installedIndex == nil {
                findings.append(objectFinding(profile, "Scoped to this device but not installed"))
            } else if !expected && installedIndex != nil {
                findings.append(objectFinding(profile, excluded ? "Installed, but the device is excluded"
                                              : "Installed, but no longer scoped to this device"))
            }
        }
        for (index, item) in installed.enumerated() where !matchedInstalled.contains(index) {
            let label = item.name.isEmpty ? (item.uuid.isEmpty ? "ID \(item.id)" : item.uuid) : item.name
            findings.append(AuditFinding(objectType: "Installed Profile", objectName: label, objectID: "",
                                         detail: "Installed, not a Jamf configuration profile (e.g. the MDM profile)"))
        }
        return AuditOutput(findings: sortFindings(findings), scanned: profiles.count + installed.count,
                           subject: AuditSubject(kind: p.kind, id: deviceID, name: name),
                           subtitle: "\(p.kind.label) · \(installed.count) installed profile(s) vs. \(profiles.count) in Jamf")
    }

    /// "directly", "via static group “X”", "directly and via all mobile devices", or "".
    private static func how(directly: Bool, via: [String]) -> String {
        let viaText = via.isEmpty ? "" : "via " + via.joined(separator: ", ")
        if directly { return viaText.isEmpty ? "directly" : "directly and \(viaText)" }
        return viaText
    }

    /// How a profile's scope reaches one device: "directly", "via static group “X”, user “jdoe”", …
    struct Routes {
        var targets = ""
        var exclusions = ""
        var targetedDirectly = false
        var excludedDirectly = false
        var location = DeviceFacts.LocationMatch()
    }

    static func routes(_ scope: ScopeReading.Scope, to device: DeviceFacts, kind: GroupKind,
                       groupLabel: (String, String) -> String) -> Routes {
        var routes = Routes()
        var targetVia: [String] = []
        if scope.all { targetVia.append("all \(kind.pluralLabel)") }
        for (id, name) in scope.groups.sorted(by: { $0.value < $1.value }) where device.inGroup(id, name) {
            targetVia.append(groupLabel(id, name))
        }
        routes.targetedDirectly = scope.devices.contains(device.id)
        routes.location = device.locationMatch(scope)
        targetVia += routes.location.targets
        var excludeVia: [String] = []
        for (id, name) in scope.excludedGroups.sorted(by: { $0.value < $1.value }) where device.inGroup(id, name) {
            excludeVia.append(groupLabel(id, name))
        }
        routes.excludedDirectly = scope.excludedDevices.contains(device.id)
        excludeVia += routes.location.exclusions
        routes.targets = how(directly: routes.targetedDirectly, via: targetVia)
        routes.exclusions = how(directly: routes.excludedDirectly, via: excludeVia)
        return routes
    }

    /// Every profile that targets, excludes or is installed on one device, and how.
    static func deviceProfileTargeting(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        var device = try await deviceFacts(context, p)
        // Group list, to tell static from smart groups.
        await context.status("Listing \(p.kind.label.lowercased()) groups…")
        let groupList = AuditObjects.entries(in: (try? await context.client.get("/JSSResource/\(p.kind.resource)")) ?? .emptyObject)
        func groupLabel(_ id: String, _ name: String) -> String {
            let entry = groupList.first { $0.id == id } ?? groupList.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let shown = name.isEmpty ? (entry?.name ?? "ID \(id)") : name
            return "\(AuditObjects.isTrue(entry?.json["is_smart"]) ? "smart" : "static") group “\(shown)”"
        }

        let profiles = try await context.scopedObjects([AuditObjects.profileType(p.kind)])
        try await loadUserGroups(&device, profiles, kind: p.kind, context)
        var findings: [AuditFinding] = []
        var matchedInstalled = Set<Int>()
        for profile in profiles {
            let scope = ScopeReading.scope(of: profile.root, kind: p.kind)
            let route = routes(scope, to: device, kind: p.kind, groupLabel: groupLabel)
            let targets = route.targets, exclusions = route.exclusions
            let installedIndex = device.installedIndex(of: profile, kind: p.kind)
            if let installedIndex { matchedInstalled.insert(installedIndex) }
            guard !targets.isEmpty || !exclusions.isEmpty || installedIndex != nil else { continue }
            let detail: String
            if !exclusions.isEmpty {
                detail = "Excluded \(exclusions)" + (targets.isEmpty ? "" : " (targeted \(targets))")
            } else if !targets.isEmpty {
                detail = "Targeted \(targets)"
            } else {
                detail = "Not scoped to this device"
            }
            var finding = objectFinding(profile, detail)
            finding.directScope = DirectScope(targetedDirectly: route.targetedDirectly,
                                              targetedByUser: route.location.targetedByUser,
                                              excludedDirectly: route.excludedDirectly,
                                              excludedByUser: route.location.excludedByUser)
            finding.installed = installedIndex != nil
            findings.append(finding)
        }
        for (index, item) in device.installed.enumerated() where !matchedInstalled.contains(index) {
            let label = item.name.isEmpty ? (item.uuid.isEmpty ? "ID \(item.id)" : item.uuid) : item.name
            findings.append(AuditFinding(objectType: "Installed Profile", objectName: label, objectID: "",
                                         detail: "Not a Jamf configuration profile (e.g. the MDM profile)",
                                         installed: true))
        }
        // Targeted first, then excluded, then installed-only, each alphabetical.
        func rank(_ finding: AuditFinding) -> Int {
            finding.detail.hasPrefix("Targeted") ? 0 : finding.detail.hasPrefix("Excluded") ? 1
                : finding.objectType == "Installed Profile" ? 3 : 2
        }
        findings.sort {
            rank($0) != rank($1) ? rank($0) < rank($1)
                : $0.objectName.localizedStandardCompare($1.objectName) == .orderedAscending
        }
        let targetedCount = findings.filter { rank($0) == 0 }.count
        return AuditOutput(findings: findings, scanned: profiles.count + device.installed.count,
                           subject: AuditSubject(kind: p.kind, id: device.id, name: device.name),
                           subtitle: "\(p.kind.label) · \(targetedCount) profile(s) targeting this device")
    }

    /// Every device that a profile both targets and excludes, by any route: e.g.
    /// targeted through a group and excluded through another group, its user or
    /// its department. The exclusion wins, so these devices don't get the profile.
    static func devicesTargetedAndExcluded(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let kind = p.kind
        let profiles = try await context.scopedObjects([AuditObjects.profileType(kind)])
        let scoped = profiles.map { ($0, ScopeReading.scope(of: $0.root, kind: kind)) }.filter { $0.1.hasExclusions }
        let subtitle = "\(kind.label) · \(scoped.count) of \(profiles.count) profile(s) have exclusions"
        guard !scoped.isEmpty else { return AuditOutput(findings: [], scanned: profiles.count, subtitle: subtitle) }

        let devices = try await context.inventory(kind)
        var groupIDs = Set<String>(), userGroupIDs = Set<String>()
        for (_, scope) in scoped {
            groupIDs.formUnion(scope.groups.keys)
            groupIDs.formUnion(scope.excludedGroups.keys)
            userGroupIDs.formUnion(scope.userGroups.keys)
            userGroupIDs.formUnion(scope.excludedUserGroups.keys)
        }
        let groups = try await context.groups(kind, ids: groupIDs)
        let userGroupMembers = try await context.userGroupMembers(userGroupIDs.filter { !$0.hasPrefix("#") })
        var memberships: [String: Set<String>] = [:]   // device id → group ids
        for group in groups.values {
            for member in group.members { memberships[member.id, default: []].insert(group.id) }
        }
        func groupLabel(_ id: String, _ name: String) -> String {
            let shown = name.isEmpty ? (groups[id]?.name ?? "ID \(id)") : name
            return "\(groups[id]?.isSmart == true ? "smart" : "static") group “\(shown)”"
        }

        await context.status("Checking \(devices.count) \(kind.pluralLabel) against \(scoped.count) profile(s)…")
        var findings: [AuditFinding] = []
        for device in devices {
            try Task.checkCancellation()
            let username = device.username.trimmingCharacters(in: .whitespaces).lowercased()
            let facts = DeviceFacts(id: device.id, name: device.name, groupIDs: memberships[device.id] ?? [],
                                    groupNames: [], installed: [], username: username,
                                    building: device.building, department: device.department,
                                    userGroupIDs: username.isEmpty ? []
                                        : Set(userGroupMembers.filter { $0.value.contains(username) }.keys),
                                    buildingID: device.buildingID, departmentID: device.departmentID)
            for (profile, scope) in scoped {
                let route = routes(scope, to: facts, kind: kind, groupLabel: groupLabel)
                guard !route.targets.isEmpty, !route.exclusions.isEmpty else { continue }
                var finding = objectFinding(profile, route.targets)
                finding.device = FindingDevice(kind: kind, id: device.id, name: device.name.isEmpty ? "ID \(device.id)" : device.name)
                finding.excludedVia = route.exclusions
                findings.append(finding)
            }
        }
        findings.sort {
            let byProfile = $0.objectName.localizedStandardCompare($1.objectName)
            return byProfile != .orderedSame ? byProfile == .orderedAscending
                : $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending
        }
        return AuditOutput(findings: findings, scanned: profiles.count + devices.count, subtitle: subtitle)
    }

    // MARK: - Device health

    static func staleDevices(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let devices = try await context.inventory(p.kind)
        let cutoff = Date().addingTimeInterval(-Double(p.days) * 86_400)
        let findings = devices.filter { ($0.lastSeen ?? .distantPast) < cutoff }
            .sorted { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
            .map { deviceFinding($0, lastSeenText($0.lastSeen)) }
        return AuditOutput(findings: findings, scanned: devices.count,
                           subtitle: "\(p.kind.pluralLabel.capitalized) · not seen in \(p.days) days")
    }

    static func unsupervisedDevices(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let devices = try await context.inventory(.mobile)
        let findings = devices.filter { $0.supervised == false && $0.managed != false }
            .map { deviceFinding($0, "Not supervised") }
        return AuditOutput(findings: sortFindings(findings), scanned: devices.count, subtitle: "Managed mobile devices")
    }

    /// Compares dotted version strings numerically: 14.10 > 14.9.
    static func version(_ a: String, isBelow b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func osBelowTarget(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let target = p.osVersion.trimmingCharacters(in: .whitespaces)
        guard target.first?.isNumber == true else { throw ServiceError("Enter a target version, such as 15.4 or 18.0.") }
        let devices = try await context.inventory(p.kind)
        let unknown = devices.filter { $0.osVersion.isEmpty }.count
        let findings = devices.filter { !$0.osVersion.isEmpty && version($0.osVersion, isBelow: target) }
            .sorted { version($0.osVersion, isBelow: $1.osVersion) }
            .map { deviceFinding($0, $0.osVersion) }
        return AuditOutput(findings: findings, scanned: devices.count,
                           subtitle: "\(p.kind.pluralLabel.capitalized) · below \(target)",
                           warnings: unknown > 0 ? ["\(unknown) device(s) haven't reported an OS version and weren't checked."] : [])
    }

    static func fileVaultOff(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let devices = try await context.inventory(.computer)
        let findings = devices.compactMap { device -> AuditFinding? in
            let state = device.fileVaultState.uppercased()
            let encrypted = state == "ENCRYPTED" || state == "ALL_ENCRYPTED" || state == "BOOT_ENCRYPTED"
            if encrypted || (device.fileVaultEnabled == true && state.isEmpty) { return nil }
            let shown = state.isEmpty ? "Off" : state.replacingOccurrences(of: "_", with: " ").capitalized
            return deviceFinding(device, shown)
        }
        return AuditOutput(findings: sortFindings(findings), scanned: devices.count, subtitle: "All computers")
    }

    static func noAssignedUser(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let devices = try await context.inventory(p.kind)
        let findings = devices.filter { $0.username.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { deviceFinding($0, "No username") }
        return AuditOutput(findings: sortFindings(findings), scanned: devices.count,
                           subtitle: "\(p.kind.pluralLabel.capitalized) · User and Location")
    }

    static func duplicateSerials(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        var devices: [DeviceRecord] = []
        for kind in GroupKind.allCases { devices += try await context.inventory(kind) }
        let bySerial = Dictionary(grouping: devices.filter { !$0.serial.isEmpty }, by: { $0.serial.uppercased() })
        var findings: [AuditFinding] = []
        for (serial, matches) in bySerial where matches.count > 1 {
            for device in matches {
                findings.append(deviceFinding(device, "\(serial) is on \(matches.count) records"))
            }
        }
        findings.sort { $0.detail != $1.detail ? $0.detail < $1.detail : $0.objectID < $1.objectID }
        return AuditOutput(findings: findings, scanned: devices.count, subtitle: "All computers and mobile devices")
    }

    static func pendingCommands(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let threshold = max(1, p.threshold)
        let pending = try await context.mdmCommands(state: "Pending")
        var devices: [String: DeviceRecord] = [:]
        for kind in GroupKind.allCases {
            for device in try await context.inventory(kind) where !device.managementID.isEmpty {
                devices[device.managementID] = device
            }
        }
        let byClient = Dictionary(grouping: pending.filter { !$0.managementID.isEmpty }, by: \.managementID)
        var findings: [AuditFinding] = []
        for (managementID, commands) in byClient.sorted(by: { $0.value.count > $1.value.count })
        where commands.count >= threshold {
            let oldest = commands.compactMap(\.dateSent).min()
            let types = Dictionary(grouping: commands, by: \.commandType).sorted { $0.value.count > $1.value.count }
                .prefix(3).map { "\($0.key.replacingOccurrences(of: "_", with: " ").lowercased()) ×\($0.value.count)" }
            let detail = "\(commands.count) pending" + (oldest.map { ", oldest \(dayFormat.string(from: $0))" } ?? "")
                + (types.isEmpty ? "" : " (\(types.joined(separator: ", ")))")
            if let device = devices[managementID] {
                findings.append(deviceFinding(device, detail))
            } else {
                findings.append(AuditFinding(objectType: "Unknown Device", objectName: managementID, objectID: "", detail: detail))
            }
        }
        return AuditOutput(findings: findings, scanned: pending.count,
                           subtitle: "Devices with \(threshold) or more pending commands")
    }

    // MARK: - Policies

    private static func policies(_ context: AuditContext) async throws -> [ScopedObject] {
        try await context.scopedObjects([AuditObjects.policy])
    }

    static func disabledScopedPolicies(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await policies(context)
        let findings = all.filter { policy in
            !AuditObjects.isTrue(policy.root["general"]?["enabled"])
                && !ScopeReading.scope(of: policy.root, kind: .computer).isEmpty
        }.map { objectFinding($0, "Disabled, but still has a scope") }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count, subtitle: "All policies")
    }

    static func unscopedPolicies(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await policies(context)
        let findings = all.filter { policy in
            AuditObjects.isTrue(policy.root["general"]?["enabled"])
                && ScopeReading.scope(of: policy.root, kind: .computer).isEmpty
        }.map { objectFinding($0, "Enabled, but scoped to nothing") }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count, subtitle: "All policies")
    }

    static func recentPolicyFailures(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let computers = try await context.inventory(.computer)
        let cutoff = Date().addingTimeInterval(-Double(p.days) * 86_400)
        let history = try await context.policyLogs(computers)
        var failures: [String: (name: String, computers: Set<String>, latest: Date)] = [:]
        for (computer, logs) in history {
            for log in logs {
                let entry = log["policy_log"] ?? log
                guard entry["status"]?.text.lowercased() == "failed" else { continue }
                let date: Date?
                if let epoch = Double(entry["date_completed_epoch"]?.text ?? "") {
                    date = Date(timeIntervalSince1970: epoch / 1000)
                } else {
                    date = parseJamfDate(entry["date_completed_utc"]?.text ?? entry["date_completed"]?.text ?? "")
                }
                guard let date, date >= cutoff else { continue }
                let id = entry["policy_id"]?.text ?? ""
                let name = entry["policy_name"]?.text ?? "Policy \(id)"
                var current = failures[id] ?? (name, [], date)
                current.computers.insert(computer.id)
                current.latest = max(current.latest, date)
                failures[id] = current
            }
        }
        let findings = failures.sorted { $0.value.computers.count > $1.value.computers.count }.map { id, value in
            AuditFinding(objectType: AuditObjects.policy.label, objectName: value.name, objectID: id,
                         detail: "Failed on \(value.computers.count) computer(s), latest \(dayFormat.string(from: value.latest))",
                         webPage: AuditObjects.policy.webPage)
        }
        return AuditOutput(findings: findings, scanned: computers.count,
                           subtitle: "Policy history of \(computers.count) computers · last \(p.days) days")
    }

    static func ongoingWithoutTrigger(_ context: AuditContext, _ p: AuditParameters) async throws -> AuditOutput {
        let all = try await policies(context)
        let triggers = ["trigger_checkin", "trigger_enrollment_complete", "trigger_login", "trigger_logout",
                        "trigger_network_state_changed", "trigger_startup"]
        let findings = all.filter { policy in
            let general = policy.root["general"] ?? .emptyObject
            guard general["frequency"]?.text.lowercased() == "ongoing" else { return false }
            let anyTrigger = triggers.contains { AuditObjects.isTrue(general[$0]) }
                || !(general["trigger_other"]?.text.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let selfService = AuditObjects.isTrue(policy.root["self_service"]?["use_for_self_service"])
            return !anyTrigger && !selfService
        }.map { objectFinding($0, "Ongoing, no trigger, not in Self Service") }
        return AuditOutput(findings: sortFindings(findings), scanned: all.count, subtitle: "All policies")
    }
}

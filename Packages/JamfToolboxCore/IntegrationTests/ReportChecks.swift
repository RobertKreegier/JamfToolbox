import Foundation
var fails = 0
func ck(_ c: Bool, _ m: String) { print(c ? "  ok   \(m)" : "  FAIL \(m)"); if !c { fails += 1 } }

@main struct ReportChecks { static func main() async {
    let client = JamfClient(baseURL: "https://localhost:18446", authMethod: .basic, credentialA: "u", credentialB: "p",
                            tls: TLSPolicy(verify: true, caBundlePath: CommandLine.arguments[1] + "/cert.pem"))
    func run(_ id: String, _ configure: (inout AuditParameters) -> Void = { _ in }) async -> AuditResult? {
        var p = AuditParameters(); configure(&p)
        guard let report = AuditReports.report(id) else { ck(false, "no report \(id)"); return nil }
        do { return try await AuditReports.run(report, parameters: p, client: client) { _ in } }
        catch { ck(false, "\(id) threw \(error)"); return nil }
    }
    func rows(_ r: AuditResult?) -> [String] { (r?.findings ?? []).map { "\($0.objectName) | \($0.detail)" } }
    func show(_ title: String, _ r: AuditResult?) { print("\n[\(title)] \(r?.findings.count ?? -1) finding(s) of \(r?.objectsScanned ?? -1) scanned"); for f in r?.findings ?? [] { print("   · \(f.objectType) | \(f.objectName) | \(f.detail)") }; for w in r?.warnings ?? [] { print("   ⚠ \(w)") } }
    func names(_ r: AuditResult?) -> Set<String> { Set((r?.findings ?? []).map(\.objectName)) }

    var r = await run("group-dependencies") { $0.kind = .computer; $0.groupID = "1" }
    show("Dependencies", r)
    ck(r?.findings.count == 7 && r?.subject?.memberCount == 3, "dependencies: 7 findings, 3 members")
    ck(!names(r).contains("Keynote") && !names(r).contains("Lab-Macs"), "dependencies: no false matches")

    r = await run("groups-empty"); show("Empty", r)
    ck(names(r) == ["Empty Static"], "empty groups")

    r = await run("groups-unused"); show("Unused", r)
    ck(names(r) == ["Lab Macs - Old OS", "Lab-Macs"], "unused groups")
    ck(r?.warnings.contains { $0.contains("restricted software") } == true, "unused: warns restricted software unreadable")

    r = await run("groups-stale-members") { $0.kind = .computer; $0.groupID = "1"; $0.days = 30 }; show("Stale members", r)
    ck(names(r) == ["MBP-2", "MBP-3"] && rows(r).contains("MBP-3 | Never"), "stale members (60 days, never)")

    r = await run("groups-duplicate-names"); show("Duplicate names", r)
    ck(names(r) == ["Lab Macs", "Lab-Macs"], "duplicate names")

    r = await run("groups-compare-list") { $0.kind = .mobile; $0.groupID = "7"; $0.pastedList = "Serial,Notes\nDMP1,x\naa-00-00-00-01-01\nDMP9\nipad-102\n" }
    show("Compare list", r)
    ck(rows(r).contains("DMP9 | On your list, not in the group") && rows(r).contains("iPad-103 | In the group, not on your list")
       && r?.findings.count == 2, "compare: 1 missing, 1 extra; header, MAC and case-insensitive name matched")

    r = await run("groups-device-memberships") { $0.kind = .computer; $0.deviceID = "1" }; show("Device groups", r)
    ck(names(r) == ["Lab Macs", "Lab Macs - Old OS", "Lab-Macs"] && r?.findings.contains { $0.objectType == "Smart Computer Group" } == true,
       "device memberships with smart/static")

    r = await run("profiles-scope-gaps"); show("Scope gaps", r)
    ck(names(r) == ["Dock A", "Unscoped"], "unscoped / all-without-exclusions")


    r = await run("profiles-devices-targeted-excluded") { $0.kind = .mobile }; show("Targeted and excluded (mobile)", r)
    ck((r?.findings ?? []).map { "\($0.objectName) | \($0.deviceName) | \($0.detail) | \($0.excludedText)" } == [
        "Direct Exclude | iPad-101 | directly | directly",
        "Excluded One | iPad-102 | via all mobile devices | via smart group “Old iPadOS”",
        "No Staff | iPad-101 | via all mobile devices | via user group “Staff”",
        "Not Tech | iPad-101 | via all mobile devices | via department “tech”",
        "Not Tech | iPad-102 | via all mobile devices | via department “tech”",
        "User Excluded | iPad-101 | via static group “Grade 5 iPads” | via user “jdoe”"],
       "targeted+excluded: groups, smart groups, direct, user, user group, department by id and by name")
    ck(names(r).isSuperset(of: ["Direct Exclude"]), "covers the old Included and Excluded case: same device in both lists")
    ck(Set((r?.findings ?? []).map(\.id)).count == r?.findings.count && r?.findings.first?.device?.id == "101", "rows have distinct ids and carry the device")
    r = await run("profiles-devices-targeted-excluded") { $0.kind = .computer }; show("Targeted and excluded (mac)", r)
    ck((r?.findings ?? []).map { "\($0.objectName) | \($0.deviceName) | \($0.detail) | \($0.excludedText)" } == [
        "Conflict | MBP-4 | via static group “All Faculty” | via static group “All Faculty”"], "computers: same group in both lists (the old Included and Excluded case)")
    ck(AuditReports.report("profiles-include-exclude") == nil, "Included and Excluded is gone from the catalog")

    r = await run("profiles-bad-groups"); show("Bad groups", r)
    ck(rows(r).contains("Ghost Group | Targets deleted group “Deleted Group”") && rows(r).contains("Empty Target | Targets empty group “Empty Static”")
       && r?.findings.count == 2, "deleted and empty groups")

    r = await run("profiles-overlap") { $0.kind = .computer }; show("Overlap (mac)", r)
    ck(r?.findings.count == 1 && rows(r).first?.contains("com.apple.dock") == true, "mac overlap: Dock A/B only (Wi-Fi ignored)")
    r = await run("profiles-overlap") { $0.kind = .mobile }; show("Overlap (mobile)", r)
    ck(r?.findings.count == 1 && rows(r).first?.contains("Wallpaper Alt") == true, "mobile overlap via shared group")

    r = await run("profiles-install-status"); show("Install status", r)
    ck(rows(r).contains("Restrictions | 1 failed, 1 pending — Profile installation failed")
       && rows(r).contains { $0.hasPrefix("Wi-Fi Labs | 1 failed") }, "install status per profile")

    r = await run("profiles-device") { $0.kind = .mobile; $0.deviceID = "101" }; show("Device profiles (mobile)", r)
    ck(rows(r).contains("Restrictions | Scoped to this device but not installed") && rows(r).contains("Wallpaper Alt | Scoped to this device but not installed")
       && rows(r).contains("User Target | Scoped to this device but not installed") && !names(r).contains("User Excluded") && !names(r).contains("Someone Else")
       && rows(r).contains { $0.hasPrefix("Stray |") } && rows(r).contains("High School Only | Scoped to this device but not installed")
       && rows(r).contains("All Users | Scoped to this device but not installed") && !names(r).contains("Staff Only")
       && !names(r).contains("Tech Dept") && !names(r).contains("Not Tech") && !names(r).contains("No Staff") && !names(r).contains("Middle School")
       && rows(r).contains("Wrapped User | Scoped to this device but not installed")
       && r?.findings.count == 7, "mobile device profiles (user incl. wrapped list, user group, all users, building, department)")
    r = await run("profiles-device") { $0.kind = .computer; $0.deviceID = "1" }; show("Device profiles (mac)", r)
    ck(rows(r).contains("Dock A | Scoped to this device but not installed") && rows(r).contains("Dock B | Scoped to this device but not installed")
       && rows(r).contains("Unscoped | Installed, but no longer scoped to this device") && r?.findings.count == 4, "mac device profiles")

    r = await run("profiles-device-targeting") { $0.kind = .mobile; $0.deviceID = "101" }; show("Profile targeting (mobile)", r)
    ck((r?.findings ?? []).map { "\($0.objectName) | \($0.detail) | \($0.installedText)" } == [
        "All Users | Targeted via all users | No",
        "High School Only | Targeted via building “High School”, user group “Staff” | No",
        "Old | Targeted directly | Yes",
        "Restrictions | Targeted via static group “Grade 5 iPads” | No",
        "Staff Only | Targeted via user group “Staff” | Yes",
        "Tech Dept | Targeted via department “Tech” | Yes",
        "User Target | Targeted via user “jdoe” | No",
        "Wallpaper Alt | Targeted via static group “Grade 5 iPads” | No",
        "Wallpaper Lock | Targeted via static group “Grade 5 iPads” | Yes",
        "Wrapped User | Targeted via user “jdoe” | No",
        "Direct Exclude | Excluded directly (targeted directly) | No",
        "Excluded One | Excluded via smart group “Old iPadOS” (targeted via all mobile devices) | No",
        "No Staff | Excluded via user group “Staff” (targeted via all mobile devices) | No",
        "Not Tech | Excluded via department “tech” (targeted via all mobile devices) | No",
        "User Excluded | Excluded via user “jdoe” (targeted via static group “Grade 5 iPads”) | No",
        "Stray | Not a Jamf configuration profile (e.g. the MDM profile) | Yes"], "mobile targeting: users, user groups, buildings, departments")
    ck(r?.warnings == ["1 user group(s) couldn't be read, so targets and exclusions through them weren't checked."], "unreadable user group warned: \(r?.warnings ?? [])")
    ck(r?.findings.first { $0.objectName == "Staff Only" }?.directScope?.allows(.removeTarget) == false, "user group target: no Remove Target")
    ck(r?.findings.first { $0.objectName == "Tech Dept" }?.directScope?.allows(.removeTarget) == false, "department target: no Remove Target")
    ck(!names(r).contains("Carts Only") && !names(r).contains("Someone Else") && r?.subject?.name == "iPad-101", "profile for a group the device isn't in is not listed")
    func ds(_ n: String) -> DirectScope? { r?.findings.first { $0.objectName == n }?.directScope }
    ck(ds("Old")?.allows(.removeTarget) == true && ds("Restrictions")?.allows(.removeTarget) == false
       && ds("User Target")?.targetedByUser == true && ds("Direct Exclude")?.allows(.exclude) == false
       && ds("Direct Exclude")?.allows(.removeExclusion) == true && ds("User Excluded")?.excludedByUser == true
       && ds("Stray") == nil && ds("Restrictions")?.allows(.exclude) == true, "direct scope flags drive the actions")
    ck(r?.warnings.count == 1, "only the unreadable user group is warned about")
    r = await run("profiles-device-targeting") { $0.kind = .computer; $0.deviceID = "1" }; show("Profile targeting (mac)", r)
    ck(rows(r).contains("Dock A | Targeted via all computers") && rows(r).contains("Wi-Fi Labs | Targeted via static group “Lab Macs”")
       && rows(r).contains("Unscoped | Not scoped to this device") && r?.findings.first { $0.objectName == "Unscoped" }?.installed == true, "computer targeting by name-only group membership")
    r = await run("health-stale") { $0.kind = .computer; $0.days = 30 }; show("Stale (mac)", r)
    ck(r?.findings.map(\.objectName) == ["MBP-3", "MBP-2"], "stale computers, never-seen first")
    r = await run("health-stale") { $0.kind = .mobile; $0.days = 30 }; show("Stale (mobile)", r)
    ck(names(r) == ["iPad-103"], "stale mobile")

    r = await run("health-unsupervised"); show("Unsupervised", r)
    ck(names(r) == ["iPad-102"], "unsupervised (unmanaged excluded)")

    r = await run("health-os") { $0.kind = .computer; $0.osVersion = "15.0" }; show("OS (mac)", r)
    ck(r?.findings.map(\.detail) == ["13.6", "14.7"], "OS below 15.0 (15.10 not flagged), oldest first")
    r = await run("health-os") { $0.kind = .mobile; $0.osVersion = "18.0" }; show("OS (mobile)", r)
    ck(names(r) == ["iPad-102", "iPad-104"], "mobile OS below 18.0")

    r = await run("health-filevault"); show("FileVault", r)
    ck(rows(r).contains("MBP-2 | Unencrypted") && rows(r).contains("MBP-3 | Off") && r?.findings.count == 2, "FileVault off")

    r = await run("health-no-user") { $0.kind = .computer }; show("No user (mac)", r)
    ck(names(r) == ["MBP-3"], "no user")

    r = await run("health-duplicate-serials"); show("Duplicate serials", r)
    ck(names(r) == ["MBP-1", "MBP-3", "MBP-4", "iPad-104"], "duplicate serials incl. cross-kind")

    r = await run("health-pending-commands") { $0.threshold = 5 }; show("Pending", r)
    ck(r?.findings.count == 1 && rows(r).first?.hasPrefix("iPad-102 | 7 pending, oldest") == true, "pending ≥5")

    r = await run("policies-disabled-scoped"); show("Disabled scoped", r)
    ck(names(r) == ["Old Policy"], "disabled but scoped")
    r = await run("policies-no-scope"); show("No scope", r)
    ck(names(r) == ["Nothing", "Only Legacy Limit"], "enabled with no scope: wrapped user targets count, legacy limit_to_users does not")
    r = await run("policies-failures") { $0.days = 30 }; show("Failures", r)
    ck(rows(r) == ["Lab Cleanup | Failed on 2 computer(s), latest " + {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date().addingTimeInterval(-2 * 86400)) }()], "recent failures (old one excluded)")
    r = await run("policies-ongoing-no-trigger"); show("Ongoing", r)
    ck(names(r) == ["Ongoing None"], "ongoing with no trigger (self service / triggered excluded)")

    // Old saved results still decode.
    let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","report":"Static Group Dependencies","runAt":"2026-10-01T10:00:00Z","server":"https://x","subject":{"kind":"mobile","id":"7","name":"Grade 5"},"findings":[{"objectType":"Policy","objectName":"A","objectID":"1","relationship":"Scoped","webPage":"policies.html"}],"warnings":[],"objectsScanned":3}"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let decoded = try? d.decode(AuditResult.self, from: Data(old.utf8))
    ck(decoded?.reportID == "group-dependencies" && decoded?.findings.first?.detail == "Scoped" && decoded?.detailHeading == "Relationship",
       "results saved by the first version still load")
    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILURE(S)"); exit(fails == 0 ? 0 : 1)
} }

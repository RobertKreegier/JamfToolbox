import Foundation
var fails = 0
func ck(_ c: Bool, _ m: String) { print(c ? "  ok   \(m)" : "  FAIL \(m)"); if !c { fails += 1 } }

@main struct ScopeChangeChecks { static func main() async {
    let client = JamfClient(baseURL: "https://localhost:18448", authMethod: .basic, credentialA: "u", credentialB: "p",
                            tls: TLSPolicy(verify: true, caBundlePath: CommandLine.arguments[1] + "/cert.pem"))
    let type = AuditObjects.mobileProfile
    func scope(_ id: String) async -> ScopeReading.Scope {
        let xml = try! await client.profileScopeXML(type, id: id)
        let fp = ProfileScopeEditor.fingerprint(of: xml)!
        _ = fp
        // Reuse JSON reading by converting the few lists we care about.
        let doc = try! XMLDocument(data: xml)
        func ids(_ x: String) -> Set<String> { Set(((try? doc.nodes(forXPath: x)) ?? []).compactMap { $0.stringValue }) }
        var s = ScopeReading.Scope()
        s.devices = ids("/*/scope/mobile_devices/mobile_device/id")
        s.excludedDevices = ids("/*/scope/exclusions/mobile_devices/mobile_device/id")
        s.users = Set(ids("/*/scope/jss_users/user/name").map { $0.lowercased() })
        s.excludedUsers = Set(ids("/*/scope/exclusions/jss_users/user/name").map { $0.lowercased() })
        s.groups = Dictionary(uniqueKeysWithValues: ids("/*/scope/mobile_device_groups/mobile_device_group/id").map { ($0, "") })
        return s
    }
    func apply(_ change: ScopeChange, _ id: String) async throws -> [String] {
        let before = try await client.profileScopeXML(type, id: id)
        let edit = try ProfileScopeEditor.apply(change, to: before, kind: .mobile, deviceID: "101", username: "jdoe")
        guard !edit.changes.isEmpty else { return [] }
        try await client.putProfileScope(type, id: id, body: edit.body)
        let after = try await client.profileScopeXML(type, id: id)
        let diff = ProfileScopeEditor.differences(edit.expected, ProfileScopeEditor.fingerprint(of: after)!)
        ck(diff.isEmpty, "\(change) \(id): reads back as expected \(diff)")
        return edit.changes
    }
    let before148 = ProfileScopeEditor.fingerprint(of: try! await client.profileScopeXML(type, id: "148"))!
    print(before148.keys.sorted())

    // Remove target: device and user, others untouched.
    var c = try! await apply(.removeTarget, "148"); print(c)
    var s = await scope("148")
    ck(s.devices == ["102"] && s.users == ["other"] && s.groups.keys.contains("7"), "remove target: device + jdoe gone, 102/other/group kept")
    let after148 = ProfileScopeEditor.fingerprint(of: try! await client.profileScopeXML(type, id: "148"))!
    ck(ProfileScopeEditor.differences(before148, after148) == ["scope/jss_users", "scope/mobile_devices"], "only the two target lists changed")
    ck(after148["scope/limitations/users"] == ["name:ldapbob"] && after148["scope/limitations/network_segments"] == ["id:3"]
       && after148["scope/exclusions/mobile_device_groups"] == ["id:9"], "limitations and group exclusions intact")
    c = try! await apply(.removeTarget, "148"); ck(c.isEmpty, "remove target again: no-op, no PUT")

    // Exclude, then undo.
    c = try! await apply(.exclude, "148"); s = await scope("148")
    ck(c == ["added the device to Exclusions"] && s.excludedDevices == ["101"], "exclude adds device exclusion")
    c = try! await apply(.exclude, "148"); ck(c.isEmpty, "exclude again: no-op")
    c = try! await apply(.removeExclusion, "148"); s = await scope("148")
    ck(s.excludedDevices.isEmpty, "remove exclusion undoes it")

    // Remove exclusion removes user exclusion case-insensitively.
    c = try! await apply(.removeExclusion, "149"); s = await scope("149"); print(c)
    ck(s.excludedDevices.isEmpty && s.excludedUsers.isEmpty && c.count == 2, "remove exclusion: device + user (JDoe)")

    // All devices: exclude works; remove target finds nothing.
    c = try! await apply(.removeTarget, "150"); ck(c.isEmpty, "all devices: nothing direct to remove")
    c = try! await apply(.exclude, "150"); s = await scope("150"); ck(s.excludedDevices == ["101"], "all devices: exclude")

    // Permission denied on PUT.
    do { _ = try await apply(.removeTarget, "403"); ck(false, "403 should throw") }
    catch let e as ServiceError { ck(e.isPermissionDenied, "403 → permission denied") } catch { ck(false, "\(error)") }

    // Request shape.
    let puts = try! await client.get("/__puts")
    let first = puts.arrayValue!.first!
    ck(first["ctype"]?.text == "application/xml" && first["body"]!.text.hasPrefix("<?xml"), "PUT is XML: \(first["body"]!.text.prefix(80))")
    ck(puts.arrayValue!.count == 6, "PUT count 6 (\(puts.arrayValue!.count)); no-ops sent nothing")

    // DirectScope rules
    ck(DirectScope(targetedDirectly: false, targetedByUser: false).allows(.removeTarget) == false, "group-only target: no Remove Target")
    ck(DirectScope(targetedByUser: true).allows(.removeTarget), "user target: Remove Target")
    ck(DirectScope(excludedDirectly: true).allows(.exclude) == false, "already excluded: no Exclude")
    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
} }

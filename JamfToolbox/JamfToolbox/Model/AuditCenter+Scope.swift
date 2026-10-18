import Foundation
import JamfToolboxCore

/// Changing how a device is scoped by configuration profiles, from a
/// Config Profiles in Scope result.
extension AuditCenter {
    /// The findings `change` can apply to.
    func candidates(_ change: ScopeChange, in findings: [AuditFinding]) -> [AuditFinding] {
        findings.filter { !$0.objectID.isEmpty && $0.directScope?.allows(change) == true }
    }

    func applyScopeChange(_ change: ScopeChange, to selected: [AuditFinding], in result: AuditResult) async {
        guard !isRunning, !changingScope, let model else { return }
        let targets = candidates(change, in: selected)
        guard !targets.isEmpty, let subject = result.subject else { return }
        guard let client = await model.requireClient() else { return }
        guard client.baseURL.caseInsensitiveCompare(result.server) == .orderedSame else {
            await Dialogs.warning("This result is from \(result.server), but you're connected to \(client.baseURL). "
                                  + "Run the audit again on this server first.")
            return
        }
        changingScope = true
        defer { changingScope = false }

        let kind = subject.kind, deviceID = subject.id, device = subject.name
        let type = AuditObjects.profileType(kind)
        let privilege = "\(kind == .computer ? "macOS" : "Mobile Device") Configuration Profiles: Update"
        let noun = targets.count == 1 ? "profile" : "profiles"

        // Fresh facts: the device's assigned user now, and how each profile redistributes.
        var username = ""
        var redistributeAll: [String] = []
        let checked = await model.busyScope("Checking \(targets.count) \(noun)…") { () async throws -> Void in
            let record = try await client.get("/JSSResource/\(kind.deviceResource)/id/\(URLEncoding.quote(deviceID))/subset/Location")
            username = (AuditObjects.rootObject(record)?["location"]?["username"]?.text ?? "")
                .trimmingCharacters(in: .whitespaces)
            for finding in targets {
                let json = try await client.get("/JSSResource/\(type.resource)/id/\(URLEncoding.quote(finding.objectID))/subset/General")
                let redeploy = AuditObjects.rootObject(json)?["general"]?["redeploy_on_update"]?.text ?? ""
                if redeploy.caseInsensitiveCompare("All") == .orderedSame { redistributeAll.append(finding.objectName) }
            }
        }
        if case .failure(let error) = checked {
            await Dialogs.error(model.failureMessage(error, doing: "read the profiles and the device"))
            return
        }

        guard await Dialogs.show(confirmation(change, targets, device: device, username: username,
                                              redistributeAll: redistributeAll),
                                 title: "\(change.title) “\(device)”?", style: .warning,
                                 buttons: [change.title, "Cancel"]) == 0 else { return }

        var problems: [String] = []
        var changed = 0, stopped = false
        for (index, finding) in targets.enumerated() {
            let label = "\(change.title) “\(device)” on “\(finding.objectName)”"
            let outcome = await model.busyScope("\(label) (\(index + 1) of \(targets.count))…") { () async throws -> String in
                let before = try await client.profileScopeXML(type, id: finding.objectID)
                let edit = try ProfileScopeEditor.apply(change, to: before, kind: kind, deviceID: deviceID, username: username)
                guard !edit.changes.isEmpty else { return "" }
                try await client.putProfileScope(type, id: finding.objectID, body: edit.body)
                let after = try await client.profileScopeXML(type, id: finding.objectID)
                guard let readBack = ProfileScopeEditor.fingerprint(of: after) else {
                    throw ServiceError("The change was sent, but the scope couldn't be read back to check it.")
                }
                let differences = ProfileScopeEditor.differences(edit.expected, readBack)
                guard differences.isEmpty else {
                    throw ServiceError("The change was sent, but the scope reads back differently than expected in: "
                                       + differences.joined(separator: ", ") + ". Check the profile in Jamf Pro.")
                }
                return edit.changes.joined(separator: "; ")
            }
            switch outcome {
            case .success(let summary) where summary.isEmpty:
                model.log.add("No change needed — \(label): already done.")
            case .success(let summary):
                changed += 1
                model.log.add("OK — \(label): \(summary).")
            case .failure(let error):
                let message = model.failureMessage(error, doing: "change the scope of \(type.plural)", privilege: privilege)
                model.log.add("FAILED — \(label): \(message.components(separatedBy: "\n").first ?? message)")
                // Without the privilege every profile would fail the same way.
                let denied = (error as? ServiceError)?.isPermissionDenied == true
                problems.append(denied ? message : "“\(finding.objectName)”: \(message)")
                if denied { stopped = true }
            }
            if stopped { break }
        }

        if !problems.isEmpty {
            await Dialogs.error((changed > 0 ? "\(changed) of \(targets.count) \(noun) changed.\n\n" : "")
                                + problems.joined(separator: "\n\n"))
        }
        // Show the new state.
        if changed > 0 { rerun(result, replacing: true) }
    }

    private func confirmation(_ change: ScopeChange, _ targets: [AuditFinding], device: String, username: String,
                              redistributeAll: [String]) -> String {
        let list = targets.prefix(12).map { "• \($0.objectName)" }.joined(separator: "\n")
            + (targets.count > 12 ? "\n• …and \(targets.count - 12) more" : "")
        var parts: [String] = []
        let usersInvolved = !username.isEmpty && targets.contains {
            change == .removeTarget ? $0.directScope?.targetedByUser == true : $0.directScope?.excludedByUser == true
        }
        switch change {
        case .exclude:
            parts.append("Adds “\(device)” to the exclusions of:\n\(list)")
            parts.append("Exclusions win over every target, so Jamf Pro removes these profiles from the device at "
                         + "its next check-in, however they reach it. Undo with Remove Exclusion.")
        case .removeTarget:
            parts.append("Removes “\(device)”"
                         + (usersInvolved ? " and its assigned user “\(username)”" : "")
                         + " from the targets of:\n\(list)")
            parts.append("Group and all-device targets aren't changed. If the device is still targeted that way, the "
                         + "profile stays; otherwise Jamf Pro removes it from the device at its next check-in.")
            if usersInvolved {
                parts.append("Removing the user target also removes these profiles from that user's other devices.")
            }
        case .removeExclusion:
            parts.append("Removes “\(device)”"
                         + (usersInvolved ? " and its assigned user “\(username)”" : "")
                         + " from the exclusions of:\n\(list)")
            parts.append("If the device is still targeted, Jamf Pro installs these profiles again.")
            if usersInvolved {
                parts.append("Removing the user exclusion also affects that user's other devices.")
            }
        }
        if !redistributeAll.isEmpty {
            parts.append("Set to redistribute to all devices when changed: "
                         + redistributeAll.map { "“\($0)”" }.joined(separator: ", ")
                         + ". Jamf Pro may push these again to every device in their scope.")
        }
        parts.append("Only the device's own entries in each profile's scope change; nothing else about the profiles is sent.")
        return parts.joined(separator: "\n\n")
    }
}

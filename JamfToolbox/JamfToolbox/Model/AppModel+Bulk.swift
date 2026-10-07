import AppKit
import SwiftUI

extension AppModel {
    typealias Gathered = (device: DeviceRef, record: JSONValue, tags: TagValues)

    /// Cap absurdly long confirmation lists so the dialog stays usable.
    private func capped(_ lines: [String], limit: Int = 200) -> [String] {
        lines.count <= limit ? lines : Array(lines.prefix(limit)) + ["… and \(lines.count - limit) more"]
    }

    /// Fetch each device's record (sequentially, so the server isn't hammered)
    /// for bulk actions that need per-device data to build a preview.
    private func bulkPrefetch(_ devices: [DeviceRef], client: JamfClient) async -> [Gathered]? {
        let progress = BulkProgress(total: devices.count)
        let handle = Sheets.show { ProgressSheet(title: "Preparing…", progress: progress) }
        var gathered: [Gathered] = []
        var failures: [(DeviceRef, String)] = []

        for (index, device) in devices.enumerated() {
            if progress.cancelled { break }
            progress.step(index, "Reading \(device.name) (\(index + 1) of \(devices.count))…")
            do {
                let record = try await client.record(for: device.type, id: device.id)
                gathered.append((device, record, Templates.buildTagValues(record: record, type: device.type,
                                                                          deviceID: device.id)))
            } catch {
                failures.append((device, describe(error)))
            }
        }
        let cancelled = progress.cancelled
        handle.dismiss()
        await sheetSettle()

        if cancelled {
            log.add("Bulk action cancelled while reading devices.")
            return nil
        }
        for (device, message) in failures { log.add("Skipped \(device.name): \(message)") }
        if gathered.isEmpty {
            await Dialogs.error("None of the selected devices could be read. See the activity log for details.")
            return nil
        }
        return gathered
    }

    /// Run `work` for each device, one at a time, with progress and Cancel.
    /// Every result is logged and a summary closes it out.
    private func bulkRun(_ title: String, devices: [DeviceRef], work: (DeviceRef) async throws -> String) async {
        let progress = BulkProgress(total: devices.count)
        let handle = Sheets.show { ProgressSheet(title: title, progress: progress) }
        var succeeded = 0, failed = 0, skipped = 0

        for (index, device) in devices.enumerated() {
            if progress.cancelled {
                skipped = devices.count - index
                break
            }
            progress.step(index, "\(device.name) (\(index + 1) of \(devices.count))…")
            do {
                let note = try await work(device)
                succeeded += 1
                log.add("OK — \(device.name)." + (note.isEmpty ? "" : " \(note)"))
            } catch {
                failed += 1
                log.add("FAILED — \(device.name): \(describe(error))")
            }
        }
        handle.dismiss()
        await sheetSettle()

        var parts = ["\(succeeded) succeeded"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped (cancelled)") }
        let summary = parts.joined(separator: ", ") + "."
        log.add("\(title): \(summary)")
        log.status = summary
        if failed > 0 {
            await Dialogs.warning("\(title)\n\n\(summary)\n\nSee the activity log for the devices that failed.")
        }
    }

    // MARK: Actions

    func bulkRename() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let type = devices.first?.type else { return }
        let template = settings.prefs.renameFormat(for: type)
        guard let gathered = await bulkPrefetch(devices, client: client) else { return }

        var planned: [(device: DeviceRef, newName: String)] = []
        for item in gathered {
            let newName = Templates.render(template, item.tags)
            if !newName.isEmpty && newName != item.device.name {
                planned.append((item.device, newName))
            } else {
                log.add("Skipped \(item.device.name): "
                        + (newName.isEmpty ? "template produced an empty name." : "name already matches."))
            }
        }
        guard !planned.isEmpty else {
            await Dialogs.info("Nothing to rename — every selected device already matches the template.")
            return
        }
        let confirmed = await Sheets.present { done in
            BulkConfirmSheet(
                title: "Rename Devices",
                intro: "\(planned.count) device(s) will be renamed using the template “\(template)”. "
                    + "Review the new names below.",
                lines: capped(planned.map { "\($0.device.name)  →  \($0.newName)" }),
                confirmLabel: "Rename \(planned.count) Device(s)",
                done: done)
        }
        guard confirmed else {
            log.add("Bulk rename cancelled.")
            return
        }
        let names = Dictionary(planned.map { ($0.device.id, $0.newName) }, uniquingKeysWith: { $1 })
        await bulkRun("Rename devices", devices: planned.map(\.device)) { device in
            let newName = names[device.id] ?? device.name
            let note: String
            if device.type == .computer {
                note = try await client.renameComputer(id: device.id, newName: newName)
            } else {
                note = try await client.renameMobileDevice(id: device.id, newName: newName)
            }
            self.updateListEntry(type: device.type, id: device.id, fields: ["name": newName])
            return note
        }
    }

    func bulkToggleLostMode() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let first = devices.first else { return }
        guard first.type == .mobile else {
            await Dialogs.info("Lost Mode is only available for mobile devices.")
            return
        }
        guard let gathered = await bulkPrefetch(devices, client: client) else { return }

        let states = gathered.map { Templates.lostModeEnabled(in: $0.record) }
        let on = states.filter { $0 == true }.count
        let off = states.filter { $0 == false }.count
        let unknown = states.count - on - off
        let choice = await Dialogs.choose(
            "\(gathered.count) mobile device(s) selected.\n"
            + "Currently on: \(on)   off: \(off)   not reported: \(unknown)\n\n"
            + "One direction is applied to every selected device, which keeps the result "
            + "predictable when the devices are in mixed states.",
            first: "Enable on All", second: "Disable on All")
        guard let choice else {
            log.add("Bulk Lost Mode cancelled.")
            return
        }
        let targets = gathered.map { ($0.device, $0.tags) }

        if choice == 0 {
            let prefs = settings.prefs
            let sound = prefs.lostModeSound
            let lines = capped(targets.map { "\($0.0.name)  →  \(Templates.render(prefs.lostModeMessage, $0.1))" })
            let confirmed = await Sheets.present { done in
                BulkConfirmSheet(
                    title: "Enable Lost Mode",
                    intro: "Lost Mode will be enabled on \(targets.count) device(s), locking each one and "
                        + "showing this message on its screen.",
                    lines: lines,
                    confirmLabel: "Enable on \(targets.count) Device(s)",
                    warning: "Each device becomes unusable until Lost Mode is turned off.",
                    done: done)
            }
            guard confirmed else {
                log.add("Bulk Enable Lost Mode cancelled.")
                return
            }
            let tagsByID = Dictionary(targets.map { ($0.0.id, $0.1) }, uniquingKeysWith: { $1 })
            await bulkRun("Enable Lost Mode", devices: targets.map(\.0)) { device in
                let tags = tagsByID[device.id] ?? [:]
                return try await client.enableLostMode(
                    id: device.id,
                    message: Templates.render(prefs.lostModeMessage, tags),
                    phone: Templates.render(prefs.lostModePhone, tags),
                    footnote: Templates.render(prefs.lostModeFootnote, tags),
                    playSound: sound)
            }
        } else {
            let lines = capped(targets.map { $0.0.name })
            let confirmed = await Sheets.present { done in
                BulkConfirmSheet(
                    title: "Disable Lost Mode",
                    intro: "Lost Mode will be turned off on \(targets.count) device(s).",
                    lines: lines,
                    confirmLabel: "Disable on \(targets.count) Device(s)",
                    done: done)
            }
            guard confirmed else {
                log.add("Bulk Disable Lost Mode cancelled.")
                return
            }
            await bulkRun("Disable Lost Mode", devices: targets.map(\.0)) { device in
                try await client.disableLostMode(id: device.id)
            }
        }
    }

    func bulkLock() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let type = devices.first?.type else { return }
        let lines = capped(devices.map(\.name))

        if type == .computer {
            let message = Templates.render(settings.prefs.lockMessage, [:])
            guard let result = await askPreview(
                title: "Lock computers",
                intro: "Lock \(devices.count) Mac(s). The PIN below will be required to unlock every one of "
                    + "them — record it before continuing.",
                fields: [PreviewField(label: "6-digit PIN", value: ""),
                         PreviewField(label: "Lock message", value: message, multiline: true)],
                confirm: "Continue") else {
                log.add("Bulk lock cancelled.")
                return
            }
            let pin = result["6-digit PIN"] ?? ""
            let lockMessage = result["Lock message"] ?? message
            guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                await Dialogs.error("The PIN must be exactly 6 digits.")
                return
            }
            let confirmed = await Sheets.present { done in
                BulkConfirmSheet(
                    title: "Lock Computers",
                    intro: "\(devices.count) Mac(s) will be locked immediately and will require the PIN \(pin) to unlock.",
                    lines: lines,
                    confirmLabel: "Lock \(devices.count) Mac(s)",
                    warning: "Write this PIN down now — the same PIN unlocks every device in this batch.",
                    done: done)
            }
            guard confirmed else {
                log.add("Bulk lock cancelled.")
                return
            }
            log.add("Bulk lock PIN for this batch: \(pin)")
            await bulkRun("Lock devices", devices: devices) { device in
                try await client.lockComputer(id: device.id, passcode: pin, message: lockMessage)
            }
        } else {
            let confirmed = await Sheets.present { done in
                BulkConfirmSheet(
                    title: "Lock Devices",
                    intro: "\(devices.count) mobile device(s) will be locked immediately. "
                        + "Each one locks with its existing passcode.",
                    lines: lines,
                    confirmLabel: "Lock \(devices.count) Device(s)",
                    done: done)
            }
            guard confirmed else {
                log.add("Bulk lock cancelled.")
                return
            }
            await bulkRun("Lock devices", devices: devices) { device in
                try await client.lockMobileDevice(id: device.id)
            }
        }
    }

    func bulkOpenInJamf() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard !devices.isEmpty else { return }
        if devices.count > 10,
           !(await Dialogs.confirm("This will open \(devices.count) browser tabs. Continue?", yes: "Open", no: "Cancel")) {
            return
        }
        for device in devices {
            if let url = client.deviceWebURL(type: device.type, id: device.id) { NSWorkspace.shared.open(url) }
        }
        log.add("Opened \(devices.count) device(s) in Jamf Pro.")
    }
}

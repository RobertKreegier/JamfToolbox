import Foundation

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
        let dismiss = ui.showProgress(title: "Preparing…", progress: progress)
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
        dismiss()
        await sheetSettle()

        if cancelled {
            log.add("Bulk action cancelled while reading devices.")
            return nil
        }
        for (device, message) in failures { log.add("Skipped \(device.name): \(message)") }
        if gathered.isEmpty {
            await ui.error("None of the selected devices could be read. See the activity log for details.")
            return nil
        }
        return gathered
    }

    /// Run `work` for each device, one at a time, with progress and Cancel.
    /// Every result is logged and a summary closes it out. With `showResults`,
    /// a list of every device's outcome follows; otherwise only failures raise
    /// an alert. `stopOnPermissionDenied` ends the run at the first "permission
    /// denied", since every other device would fail the same way.
    @discardableResult
    private func bulkRun(_ title: String, devices: [DeviceRef], privilege: String? = nil,
                         stopOnPermissionDenied: Bool = false, showResults: Bool = false,
                         work: (DeviceRef) async throws -> String) async -> [BulkResult] {
        let progress = BulkProgress(total: devices.count)
        let dismiss = ui.showProgress(title: title, progress: progress)
        var results: [BulkResult] = []
        var stopReason: String?

        for (index, device) in devices.enumerated() {
            if let stopReason {
                results.append(BulkResult(device: device.name, outcome: .notSent, detail: stopReason))
                continue
            }
            if progress.cancelled {
                stopReason = "Not sent: stopped before this device."
                results.append(BulkResult(device: device.name, outcome: .notSent, detail: stopReason!))
                continue
            }
            progress.step(index, "\(device.name) (\(index + 1) of \(devices.count))…")
            do {
                let note = try await work(device)
                results.append(BulkResult(device: device.name, outcome: .succeeded, detail: note))
                log.add("OK — \(device.name)." + (note.isEmpty ? "" : " \(note)"))
            } catch {
                let message = failureMessage(error, doing: title.lowercased(), privilege: privilege)
                let firstLine = message.components(separatedBy: "\n").first ?? message
                results.append(BulkResult(device: device.name, outcome: .failed, detail: firstLine))
                log.add("FAILED — \(device.name): \(firstLine)")
                if stopOnPermissionDenied, (error as? ServiceError)?.isPermissionDenied == true {
                    stopReason = "Not sent: stopped after “permission denied”."
                    if let privilege { log.add("Stopped: your account needs the “\(privilege)” privilege.") }
                }
            }
        }
        dismiss()
        await sheetSettle()

        let succeeded = results.filter { $0.outcome == .succeeded }.count
        let failed = results.filter { $0.outcome == .failed }.count
        let notSent = results.filter { $0.outcome == .notSent }.count
        var parts = ["\(succeeded) succeeded"]
        if failed > 0 { parts.append("\(failed) failed") }
        if notSent > 0 { parts.append("\(notSent) not sent") }
        let summary = parts.joined(separator: ", ") + "."
        log.add("\(title): \(summary)")
        log.status = summary
        if showResults {
            await ui.showBulkResults(title: title, summary: summary, results: results)
        } else if failed > 0 {
            await ui.warning("\(title)\n\n\(summary)\n\nSee the activity log for the devices that failed.")
        }
        return results
    }

    // MARK: Actions

    public func bulkRename() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard !devices.isEmpty else { return }
        let saved = settings.prefs.namePresets
        guard let template = await choosePreset(
            title: "Rename devices", intro: "Which name format should the \(devices.count) device(s) get?",
            options: saved.map { ($0.name, $0.template) }).map({ saved[$0].template }) else {
            log.add("Bulk rename cancelled.")
            return
        }
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
            await ui.info("Nothing to rename — every selected device already matches the template.")
            return
        }
        let confirmed = await ui.confirmBulk(title: "Rename Devices",
                intro: "\(planned.count) device(s) will be renamed using the template “\(template)”. "
                    + "Review the new names below.",
                lines: capped(planned.map { "\($0.device.name)  →  \($0.newName)" }),
                confirmLabel: "Rename \(planned.count) Device(s)",
                    warning: "")
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

    public func bulkToggleLostMode() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let first = devices.first else { return }
        guard first.type == .mobile else {
            await ui.info("Lost Mode is only available for mobile devices.")
            return
        }
        guard let gathered = await bulkPrefetch(devices, client: client) else { return }

        let states = gathered.map { Templates.lostModeEnabled(in: $0.record) }
        let on = states.filter { $0 == true }.count
        let off = states.filter { $0 == false }.count
        let unknown = states.count - on - off
        let choice = await ui.choose(
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
            guard let preset = await choosePreset(
                title: "Enable Lost Mode", intro: "Which Lost Mode message should the \(targets.count) device(s) show?",
                options: prefs.lostModePresets.map { ($0.name, $0.message) }).map({ prefs.lostModePresets[$0] }) else {
                log.add("Bulk Enable Lost Mode cancelled.")
                return
            }
            let lines = capped(targets.map { "\($0.0.name)  →  \(Templates.render(preset.message, $0.1))" })
            let confirmed = await ui.confirmBulk(title: "Enable Lost Mode",
                    intro: "Lost Mode will be enabled on \(targets.count) device(s), locking each one and "
                        + "showing this message on its screen.",
                    lines: lines,
                    confirmLabel: "Enable on \(targets.count) Device(s)",
                    warning: "Each device becomes unusable until Lost Mode is turned off.")
            guard confirmed else {
                log.add("Bulk Enable Lost Mode cancelled.")
                return
            }
            let tagsByID = Dictionary(targets.map { ($0.0.id, $0.1) }, uniquingKeysWith: { $1 })
            await bulkRun("Enable Lost Mode", devices: targets.map(\.0)) { device in
                let tags = tagsByID[device.id] ?? [:]
                return try await client.enableLostMode(
                    id: device.id,
                    message: Templates.render(preset.message, tags),
                    phone: Templates.render(preset.phone, tags),
                    footnote: Templates.render(preset.footnote, tags),
                    playSound: sound)
            }
        } else {
            let lines = capped(targets.map { $0.0.name })
            let confirmed = await ui.confirmBulk(title: "Disable Lost Mode",
                    intro: "Lost Mode will be turned off on \(targets.count) device(s).",
                    lines: lines,
                    confirmLabel: "Disable on \(targets.count) Device(s)",
                    warning: "")
            guard confirmed else {
                log.add("Bulk Disable Lost Mode cancelled.")
                return
            }
            await bulkRun("Disable Lost Mode", devices: targets.map(\.0)) { device in
                try await client.disableLostMode(id: device.id)
            }
        }
    }

    /// With several saved presets, ask which one to use; with one, use it.
    /// Returns the chosen index, or nil when cancelled.
    private func choosePreset(title: String, intro: String, options: [(String, String)]) async -> Int? {
        guard options.count > 1 else { return 0 }
        return await ui.choosePreset(title: title, intro: intro, options: options.map { (name: $0.0, text: $0.1) },
                                     confirmLabel: "Continue")
    }

    /// Tag values per device, read only when the message actually uses tags.
    /// Returns the devices that can proceed (unreadable ones are skipped and
    /// logged) with their tags, or nil when cancelled.
    private func tagsIfNeeded(_ template: String, devices: [DeviceRef],
                              client: JamfClient) async -> [(device: DeviceRef, tags: TagValues)]? {
        guard template.contains("{") else { return devices.map { ($0, [:]) } }
        guard let gathered = await bulkPrefetch(devices, client: client) else { return nil }
        return gathered.map { ($0.device, $0.tags) }
    }

    public func bulkLock() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let type = devices.first?.type else { return }
        let presets = lockPreviewPresets(nil)   // templates; rendered per device below

        if type == .computer {
            guard let result = await askPreview(
                title: "Lock computers",
                intro: "Lock \(devices.count) Mac(s). The PIN below will be required to unlock every one of "
                    + "them — record it before continuing. {tags} in the message are filled in for each Mac.",
                fields: [PreviewField(label: "6-digit PIN", value: ""),
                         PreviewField(label: "Lock message", value: presets[0].values["Lock message"] ?? "", multiline: true)],
                confirm: "Continue", presets: presets) else {
                log.add("Bulk lock cancelled.")
                return
            }
            let pin = result["6-digit PIN"] ?? ""
            let template = result["Lock message"] ?? ""
            guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                await ui.error("The PIN must be exactly 6 digits.")
                return
            }
            guard let targets = await tagsIfNeeded(template, devices: devices, client: client) else {
                log.add("Bulk lock cancelled.")
                return
            }
            let lines = capped(targets.map { "\($0.device.name)  →  \(Templates.render(template, $0.tags))" })
            let confirmed = await ui.confirmBulk(title: "Lock Computers",
                    intro: "\(targets.count) Mac(s) will be locked immediately and will require the PIN \(pin) to unlock.",
                    lines: lines,
                    confirmLabel: "Lock \(targets.count) Mac(s)",
                    warning: "Write this PIN down now — the same PIN unlocks every device in this batch.")
            guard confirmed else {
                log.add("Bulk lock cancelled.")
                return
            }
            log.add("Bulk lock PIN for this batch: \(pin)")
            let tagsByID = Dictionary(targets.map { ($0.device.id, $0.tags) }, uniquingKeysWith: { $1 })
            await bulkRun("Lock devices", devices: targets.map(\.device)) { device in
                try await client.lockComputer(id: device.id, passcode: pin,
                                              message: Templates.render(template, tagsByID[device.id] ?? [:]))
            }
        } else {
            let saved = settings.prefs.lockPresets
            guard let preset = await choosePreset(
                title: "Lock devices", intro: "Which lock message should the \(devices.count) device(s) show?",
                options: saved.map { ($0.name, $0.message) }).map({ saved[$0] }),
                  let targets = await tagsIfNeeded(preset.message, devices: devices, client: client) else {
                log.add("Bulk lock cancelled.")
                return
            }
            let lines = capped(targets.map { target in
                let message = Templates.render(preset.message, target.tags)
                return message.isEmpty ? target.device.name : "\(target.device.name)  →  \(message)"
            })
            let confirmed = await ui.confirmBulk(title: "Lock Devices",
                    intro: "\(targets.count) mobile device(s) will be locked immediately. "
                        + "Each one locks with its existing passcode and shows the message on its lock screen.",
                    lines: lines,
                    confirmLabel: "Lock \(targets.count) Device(s)",
                    warning: "")
            guard confirmed else {
                log.add("Bulk lock cancelled.")
                return
            }
            let tagsByID = Dictionary(targets.map { ($0.device.id, $0.tags) }, uniquingKeysWith: { $1 })
            await bulkRun("Lock devices", devices: targets.map(\.device)) { device in
                try await client.lockMobileDevice(id: device.id,
                                                  message: Templates.render(preset.message, tagsByID[device.id] ?? [:]))
            }
        }
    }

    // MARK: Wipe and delete (typed confirmation, results list)

    /// The review list: each selected device's name, with its serial number when known.
    private func reviewLines() -> [String] {
        capped(selectedEntries.map { entry in
            let name = entry.value(.name).isEmpty ? entry.id : entry.value(.name)
            let serial = entry.value(.serial)
            return serial.isEmpty ? name : "\(name)  ·  \(serial)"
        })
    }

    /// Wipes several iPhones, iPads or Apple TVs with the same options as a
    /// single wipe: Activation Lock cleared, data plan kept, Proximity Setup
    /// suppressed, and one Return to Service choice for the batch.
    public func bulkWipe() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard !devices.isEmpty else { return }
        guard devices.allSatisfy({ $0.type == .mobile }) else {
            await ui.info("Bulk wipe is for iPhones, iPads and Apple TVs. Wipe Macs one at a time: each needs its own PIN.")
            return
        }
        let count = devices.count
        guard let options = await ui.confirmDestructiveBulk(
            title: "Wipe \(count) Devices",
            intro: "Every device below will be erased. Activation Lock is cleared (supervised devices), any "
                + "cellular data plan is kept, and Proximity Setup is suppressed. Return to Service reconnects "
                + "the devices to Wi-Fi and re-enrolls them after the erase, using your Jamf Pro Return to "
                + "Service settings.",
            lines: reviewLines(),
            options: [.toggle(Self.returnToServiceLabel)],
            confirmLabel: "Wipe \(count) Devices",
            warning: "This erases ALL data on \(count) devices and can't be undone.",
            typedConfirmation: String(count)) else {
            return log.add("Bulk wipe cancelled.")
        }
        let returnToService = options[Self.returnToServiceLabel] == "true"
        log.add("Bulk wipe of \(count) devices" + (returnToService ? " with Return to Service." : "."))
        await bulkRun("Wipe devices", devices: devices,
                      privilege: AdvancedCommand.wipe.privilegeHint(for: .mobile),
                      stopOnPermissionDenied: true, showResults: true) { device in
            try await client.eraseDevice(type: .mobile, id: device.id, returnToService: returnToService)
        }
    }

    /// Deletes several device records from Jamf Pro. Records deleted
    /// successfully also leave this app's list.
    public func bulkDelete() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard let type = devices.first?.type else { return }
        let count = devices.count
        guard await ui.confirmDestructiveBulk(
            title: "Delete \(count) Device Records",
            intro: "Every device below will be removed from Jamf Pro. The devices themselves aren't changed.",
            lines: reviewLines(),
            options: [],
            confirmLabel: "Delete \(count) Records",
            warning: "Wipe first, and wait until the wipes have finished: deleting a record also discards its "
                + "pending commands, including a wipe that hasn't reached the device yet. Once a record is "
                + "gone, Jamf Pro can't send that device commands. This can't be undone.",
            typedConfirmation: String(count)) != nil else {
            return log.add("Bulk delete cancelled.")
        }
        var deleted = Set<String>()
        await bulkRun("Delete device records", devices: devices,
                      privilege: AdvancedCommand.delete.privilegeHint(for: type),
                      stopOnPermissionDenied: true, showResults: true) { device in
            let note = try await client.deleteDevice(type: device.type, id: device.id)
            deleted.insert(device.id)
            return note
        }
        if !deleted.isEmpty {
            mutateList(type) { $0.removeAll { deleted.contains($0.id) } }
            setSelection([], for: type)
        }
    }

    public func bulkOpenInJamf() async {
        guard let client = await requireClient() else { return }
        let devices = await selectedDevices()
        guard !devices.isEmpty else { return }
        if devices.count > 10,
           !(await ui.confirm("This will open \(devices.count) browser tabs. Continue?", yes: "Open", no: "Cancel")) {
            return
        }
        for device in devices {
            if let url = client.deviceWebURL(type: device.type, id: device.id) { ui.openURL(url) }
        }
        log.add("Opened \(devices.count) device(s) in Jamf Pro.")
    }
}

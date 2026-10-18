import Foundation

extension AppModel {
    // MARK: Dispatch

    public func canPerform(_ action: DeviceAction) -> Bool {
        guard showingDevices, action.isAvailable(for: deviceType) else { return false }
        if selection.count > 1 { return action.supportsBulk }
        return true
    }

    /// Menu / context-menu entry point: one device runs the action, several
    /// run its bulk form.
    public func perform(_ action: DeviceAction) {
        let bulk = selection.count > 1 && action.supportsBulk
        Task { await run(action, bulk: bulk) }
    }

    /// Double-click always targets the clicked row, so it runs the single-device form.
    public func performDoubleClickAction() {
        Task { await run(settings.prefs.doubleClickAction, bulk: false) }
    }

    func run(_ action: DeviceAction, bulk: Bool) async {
        switch action {
        case .showInfo: await actionShowInfo()
        case .networkInfo: await actionMerakiInfo()
        case .toggleLostMode:
            if bulk { await bulkToggleLostMode() } else { await actionToggleLostMode() }
        case .lock:
            if bulk { await bulkLock() } else { await actionLock() }
        case .rename:
            if bulk { await bulkRename() } else { await actionRename() }
        case .updateInventory:
            await actionUpdateInventory()
        case .openInJamf:
            if bulk { await bulkOpenInJamf() } else { await actionOpenInJamf() }
        }
    }

    // MARK: Selection helpers

    public func selectedDevice() async -> DeviceRef? {
        let chosen = selectedEntries
        if chosen.isEmpty {
            await ui.info("Select a device in the list first.")
            return nil
        }
        if chosen.count > 1 {
            await ui.info("Select a single device for this action.")
            return nil
        }
        return DeviceRef(id: chosen[0].id, name: chosen[0].value(.name).isEmpty ? chosen[0].id : chosen[0].value(.name),
                         type: deviceType)
    }

    public func selectedDevices() async -> [DeviceRef] {
        let chosen = selectedEntries
        if chosen.isEmpty {
            await ui.info("Select one or more devices in the list first.")
            return []
        }
        return chosen.map {
            DeviceRef(id: $0.id, name: $0.value(.name).isEmpty ? $0.id : $0.value(.name), type: deviceType)
        }
    }

    /// Fetch the full record (for tags), reporting any failure to the user.
    public func loadRecord(_ device: DeviceRef, client: JamfClient) async -> (record: JSONValue, tags: TagValues)? {
        switch await busyScope("Fetching \(device.name)…", { try await client.record(for: device.type, id: device.id) }) {
        case .success(let record):
            return (record, Templates.buildTagValues(record: record, type: device.type, deviceID: device.id))
        case .failure(let error):
            let message = describe(error)
            log.add("Could not load device record: \(message)")
            await ui.error(message)
            return nil
        }
    }

    /// Message for a failed command. A missing privilege gets a specific
    /// explanation (and, when known, the privilege to ask for) instead of a bare 403.
    public func failureMessage(_ error: Error, doing description: String, privilege: String? = nil,
                        note: String? = nil) -> String {
        var message = describe(error)
        if let service = error as? ServiceError, service.isPermissionDenied {
            message = "Permission denied. Your Jamf Pro account isn't allowed to \(description). "
                + "Nothing was sent.\n\nAsk a Jamf Pro admin to grant "
                + (privilege.map { "the “\($0)” privilege" } ?? "the matching privilege")
                + " to your account or API role (Settings > System > API roles and clients)."
        } else if let note, message.hasPrefix("HTTP 4") {
            message += "\n\n" + note
        }
        return message
    }

    /// Send a command, logging the outcome and alerting on failure.
    public func send(_ description: String, privilege: String? = nil, note: String? = nil,
              work: () async throws -> String, onSuccess: (() -> Void)? = nil) async {
        switch await busyScope(description, work) {
        case .success(let result):
            log.add("OK — \(description)." + (result.isEmpty ? "" : " \(result)"))
            onSuccess?()
        case .failure(let error):
            let message = failureMessage(error, doing: description, privilege: privilege, note: note)
            log.add("FAILED — \(description): \(message.components(separatedBy: "\n").first ?? message)")
            await ui.error(message)
        }
    }

    /// Ask the user to review/edit values; returns trimmed values keyed by label.
    public func askPreview(title: String, intro: String, fields: [PreviewField], confirm: String,
                    presets: [PreviewPreset] = [], presetLabel: String = "Preset") async -> [String: String]? {
        await ui.preview(title: title, intro: intro, fields: fields, confirm: confirm,
                         presets: presets, presetLabel: presetLabel)
    }

    /// Saved Lost Mode presets rendered for one device, for the preview's picker.
    public func lostModePreviewPresets(_ tags: TagValues) -> [PreviewPreset] {
        settings.prefs.lostModePresets.map { preset in
            PreviewPreset(name: preset.name, values: ["Message": Templates.render(preset.message, tags),
                                                      "Phone": Templates.render(preset.phone, tags),
                                                      "Footnote": Templates.render(preset.footnote, tags)])
        }
    }

    /// Saved lock messages rendered for one device (or left as templates when `tags` is nil).
    public func lockPreviewPresets(_ tags: TagValues?) -> [PreviewPreset] {
        settings.prefs.lockPresets.map { preset in
            PreviewPreset(name: preset.name,
                          values: ["Lock message": tags.map { Templates.render(preset.message, $0) } ?? preset.message])
        }
    }

    // MARK: Single-device actions

    public func actionShowInfo() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard let (record, _) = await loadRecord(device, client: client) else { return }
        let noun = device.type == .computer ? "Computer" : "Mobile device"
        ui.showRecord(title: "\(device.name) — \(noun) info (ID \(device.id))", record: record)
        log.add("Showing device info for \(device.name).")
    }

    public func actionOpenInJamf() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard let url = client.deviceWebURL(type: device.type, id: device.id) else {
            await ui.error("Could not build the Jamf Pro URL. Check the server URL in Settings.")
            return
        }
        ui.openURL(url)
        log.add("Opened \(device.name) in your browser.")
    }

    public func actionRename() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard let (_, tags) = await loadRecord(device, client: client) else { return }

        let presets = settings.prefs.namePresets.map { preset in
            PreviewPreset(name: preset.name, values: ["New name": Templates.render(preset.template, tags)])
        }
        let proposed = presets[0].values["New name"] ?? ""   // the default preset
        var newName = proposed
        if settings.prefs.verifyNotes {
            guard let result = await askPreview(
                title: "Rename device",
                intro: "Rename “\(device.name)” using a saved name format. Edit the result below if needed.",
                fields: [PreviewField(label: "New name", value: proposed)],
                confirm: "Rename", presets: presets) else {
                log.add("Rename cancelled.")
                return
            }
            newName = result["New name"] ?? ""
        }
        guard !newName.isEmpty else {
            await ui.warning("The new name is empty — check the name format in Settings > Templates.")
            return
        }
        await send("Rename \(device.name) → \(newName)", work: {
            if device.type == .mobile {
                return try await client.renameMobileDevice(id: device.id, newName: newName)
            }
            return try await client.renameComputer(id: device.id, newName: newName)
        }, onSuccess: {
            self.updateListEntry(type: device.type, id: device.id, fields: ["name": newName])
        })
    }

    /// One command for both directions: read the device's current Lost Mode
    /// state, then offer the opposite.
    public func actionToggleLostMode() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard device.type == .mobile else {
            await ui.info("Lost Mode is only available for mobile devices.")
            return
        }
        guard let (record, tags) = await loadRecord(device, client: client) else { return }

        switch Templates.lostModeEnabled(in: record) {
        case true?:
            log.add("Lost Mode is currently ON for \(device.name).")
            await disableLostMode(device, client: client)
        case false?:
            log.add("Lost Mode is currently OFF for \(device.name).")
            await enableLostMode(device, tags: tags, client: client)
        case nil:
            // Ask rather than guess: guessing wrong either strands a device or
            // unlocks a lost one.
            log.add("Jamf Pro did not report a Lost Mode state for \(device.name).")
            let choice = await ui.choose(
                "Jamf Pro didn't report whether Lost Mode is on for “\(device.name)”.",
                first: "Enable Lost Mode", second: "Disable Lost Mode")
            switch choice {
            case 0: await enableLostMode(device, tags: tags, client: client)
            case 1: await disableLostMode(device, client: client)
            default: log.add("Lost Mode cancelled.")
            }
        }
    }

    private func enableLostMode(_ device: DeviceRef, tags: TagValues, client: JamfClient) async {
        let prefs = settings.prefs
        let presets = lostModePreviewPresets(tags)
        var message = presets[0].values["Message"] ?? ""   // the default preset
        var phone = presets[0].values["Phone"] ?? ""
        var footnote = presets[0].values["Footnote"] ?? ""
        let sound = prefs.lostModeSound

        if prefs.verifyNotes {
            guard let result = await askPreview(
                title: "Enable Lost Mode",
                intro: "Lost Mode will lock “\(device.name)” and show this on its screen. "
                    + "The device becomes unusable until Lost Mode is turned off.",
                fields: [PreviewField(label: "Message", value: message, multiline: true),
                         PreviewField(label: "Phone", value: phone),
                         PreviewField(label: "Footnote", value: footnote)],
                confirm: "Enable Lost Mode", presets: presets) else {
                log.add("Enable Lost Mode cancelled.")
                return
            }
            message = result["Message"] ?? message
            phone = result["Phone"] ?? phone
            footnote = result["Footnote"] ?? footnote
        }
        await send("Enable Lost Mode on \(device.name)", work: {
            try await client.enableLostMode(id: device.id, message: message, phone: phone,
                                            footnote: footnote, playSound: sound)
        })
    }

    private func disableLostMode(_ device: DeviceRef, client: JamfClient) async {
        guard await ui.confirm("Lost Mode is on for “\(device.name)”.\n\nTurn it off?",
                                    yes: "Turn Off", no: "Cancel") else {
            log.add("Disable Lost Mode cancelled.")
            return
        }
        await send("Disable Lost Mode on \(device.name)", work: {
            try await client.disableLostMode(id: device.id)
        })
    }

    public func actionLock() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard let (_, tags) = await loadRecord(device, client: client) else { return }
        let presets = lockPreviewPresets(tags)
        let message = presets[0].values["Lock message"] ?? ""   // the default preset

        if device.type == .mobile {
            // The mobile DeviceLock command takes no PIN: the device locks
            // immediately with its existing passcode, showing the message.
            guard let result = await askPreview(
                title: "Lock device",
                intro: "Lock “\(device.name)” now? It locks with its existing passcode (mobile device locks don't "
                    + "use a PIN); if it has no passcode, it can be unlocked with a swipe. The message shows on "
                    + "its lock screen.",
                fields: [PreviewField(label: "Lock message", value: message, multiline: true)],
                confirm: "Lock", presets: presets) else {
                log.add("Lock cancelled.")
                return
            }
            let lockMessage = result["Lock message"] ?? ""
            await send("Lock \(device.name)", work: {
                try await client.lockMobileDevice(id: device.id, message: lockMessage)
            })
            return
        }

        guard let result = await askPreview(
            title: "Lock device",
            intro: "Lock “\(device.name)”. The PIN below will be required to unlock it — record it before continuing.",
            fields: [PreviewField(label: "6-digit PIN", value: ""),
                     PreviewField(label: "Lock message", value: message, multiline: true)],
            confirm: "Lock", presets: presets) else {
            log.add("Lock cancelled.")
            return
        }
        let pin = result["6-digit PIN"] ?? ""
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            await ui.warning("The PIN must be exactly 6 digits.")
            return
        }
        let lockMessage = result["Lock message"] ?? ""
        log.add("Lock PIN for \(device.name): \(pin)  (save this!)")
        await send("Lock \(device.name)", work: {
            try await client.lockComputer(id: device.id, passcode: pin, message: lockMessage)
        })
    }

    public func actionUpdateInventory() async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard device.type == .mobile else {
            await ui.info(
                "Jamf Pro has no remote “Update Inventory” command for computers — a Mac reports "
                + "inventory by running its own recon (e.g. `sudo jamf recon`, or on the device's next "
                + "check-in). This action is available for mobile devices only.")
            return
        }
        await send("Update inventory for \(device.name)", work: {
            try await client.updateInventoryMobile(id: device.id)
        })
    }
}

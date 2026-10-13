import AppKit
import SwiftUI

extension AppModel {
    /// Advanced commands act on one device at a time: they are disruptive
    /// enough that each should be confirmed against a specific device.
    func canPerform(_ command: AdvancedCommand) -> Bool {
        showingDevices && selection.count == 1 && command.applies(to: deviceType)
    }

    func perform(_ command: AdvancedCommand) {
        Task { await run(command) }
    }

    private func run(_ command: AdvancedCommand) async {
        guard let client = await requireClient(), let device = await selectedDevice() else { return }
        guard command.applies(to: device.type) else {
            await Dialogs.info("“\(command.label)” is only available for mobile devices.")
            return
        }
        let type = device.type
        let privilege = command.privilegeHint(for: type)

        switch command {
        case .restart:
            guard await Dialogs.confirm(
                "Restart “\(device.name)” now?\n\nThe device restarts immediately. Unsaved work on a Mac is lost.",
                yes: "Restart", no: "Cancel") else { return log.add("Restart cancelled.") }
            await send("Restart \(device.name)", privilege: privilege, note: command.supervisionNote, work: {
                try await client.restartDevice(type: type, id: device.id)
            })

        case .shutDown:
            guard await Dialogs.confirm(
                "Shut down “\(device.name)”?\n\nA device that has been shut down can't be turned back on "
                + "remotely. Someone has to power it on by hand.", yes: "Shut Down", no: "Cancel") else {
                return log.add("Shut down cancelled.")
            }
            await send("Shut down \(device.name)", privilege: privilege, note: command.supervisionNote, work: {
                try await client.shutDownDevice(type: type, id: device.id)
            })

        case .blankPush:
            await send("Send blank push to \(device.name)", privilege: privilege, work: {
                try await client.blankPush(type: type, id: device.id)
            })

        case .clearPasscode:
            guard await Dialogs.confirm(
                "Clear the passcode on “\(device.name)”?\n\nThe device stops requiring a passcode until the "
                + "user sets a new one.", yes: "Clear Passcode", no: "Cancel") else {
                return log.add("Clear passcode cancelled.")
            }
            await send("Clear passcode on \(device.name)", privilege: privilege, work: {
                try await client.clearPasscode(id: device.id)
            })

        case .clearScreenTime:
            guard await Dialogs.confirm(
                "Clear the Screen Time passcode on “\(device.name)”?\n\nThe restrictions passcode is removed. "
                + "This only works on supervised devices.", yes: "Clear Passcode", no: "Cancel") else {
                return log.add("Clear Screen Time passcode cancelled.")
            }
            await send("Clear Screen Time passcode on \(device.name)", privilege: privilege,
                       note: command.supervisionNote, work: {
                try await client.clearScreenTimePasscode(id: device.id)
            })

        case .wipe:
            await wipe(device, client: client, privilege: privilege)

        case .delete:
            await deleteRecord(device, client: client, privilege: privilege)
        }
    }

    /// Wipe asks the user to type the device's name, so a stray click can't erase the wrong machine.
    private func wipe(_ device: DeviceRef, client: JamfClient, privilege: String) async {
        let isComputer = device.type == .computer
        var fields: [PreviewField] = []
        if isComputer { fields.append(PreviewField(label: "6-digit PIN", value: "")) }
        fields.append(PreviewField(label: "Type the device name to confirm", value: ""))

        guard let result = await askPreview(
            title: "Wipe “\(device.name)”",
            intro: "This erases ALL data on the device and can't be undone."
                + (isComputer ? " The PIN below will be required to unlock the Mac afterwards; record it first." : ""),
            fields: fields, confirm: "Wipe Device") else {
            return log.add("Wipe cancelled.")
        }
        let typed = result["Type the device name to confirm"] ?? ""
        guard typed.caseInsensitiveCompare(device.name) == .orderedSame else {
            await Dialogs.warning("The name you typed doesn't match “\(device.name)”. Nothing was sent.")
            return log.add("Wipe cancelled: confirmation name didn't match.")
        }
        var pin = ""
        if isComputer {
            pin = result["6-digit PIN"] ?? ""
            guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                await Dialogs.warning("The PIN must be exactly 6 digits.")
                return
            }
            log.add("Wipe PIN for \(device.name): \(pin)  (save this!)")
        }
        let type = device.type
        await send("Wipe \(device.name)", privilege: privilege, work: {
            try await client.eraseDevice(type: type, id: device.id, pin: pin)
        })
    }

    private func deleteRecord(_ device: DeviceRef, client: JamfClient, privilege: String) async {
        // Cancel is the first (default) button: this one should never fire on a reflexive Return.
        let choice = await Dialogs.show(
            "Delete “\(device.name)” from Jamf Pro?\n\n"
            + "Wipe the device first. Once its record is gone, Jamf Pro can no longer send it commands, "
            + "so a device that hasn't been wiped keeps its data and can't be wiped remotely.\n\n"
            + "This can't be undone.",
            title: "Delete device record", style: .critical, buttons: ["Cancel", "Delete Record"])
        guard choice == 1 else { return log.add("Delete cancelled.") }

        let type = device.type
        await send("Delete \(device.name) from Jamf Pro", privilege: privilege, work: {
            try await client.deleteDevice(type: type, id: device.id)
        }, onSuccess: {
            self.mutateList(type) { $0.removeAll { $0.id == device.id } }
            self.setSelection([], for: type)
        })
    }
}

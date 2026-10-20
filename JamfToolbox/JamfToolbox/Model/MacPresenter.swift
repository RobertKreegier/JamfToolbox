import AppKit
import SwiftUI
import JamfToolboxCore

/// The shared model's prompts and windows, shown with AppKit sheets and windows.
@MainActor
final class MacPresenter: AppPresenter {
    weak var model: AppModel?

    var openSettingsHint: String { "Open Settings (⌘,)" }

    func alert(_ message: String, title: String, style: AlertStyle, buttons: [String]) async -> Int {
        let nsStyle: NSAlert.Style
        switch style {
        case .informational: nsStyle = .informational
        case .warning: nsStyle = .warning
        case .critical: nsStyle = .critical
        }
        return await Dialogs.show(message, title: title, style: nsStyle, buttons: buttons)
    }

    func preview(title: String, intro: String, fields: [PreviewField], confirm: String,
                 presets: [PreviewPreset], presetLabel: String, destructive: Bool) async -> [String: String]? {
        await Sheets.present { done in
            PreviewSheet(title: title, intro: intro, confirmLabel: confirm, fields: fields,
                         presets: presets, presetLabel: presetLabel, destructive: destructive, done: done)
        }
    }

    func choosePreset(title: String, intro: String, options: [(name: String, text: String)],
                      confirmLabel: String) async -> Int? {
        await Sheets.present { done in
            PresetChoiceSheet(title: title, intro: intro, options: options, confirmLabel: confirmLabel, done: done)
        }
    }

    func confirmBulk(title: String, intro: String, lines: [String], confirmLabel: String,
                     warning: String) async -> Bool {
        await Sheets.present { done in
            BulkConfirmSheet(title: title, intro: intro, lines: lines, confirmLabel: confirmLabel,
                             warning: warning, done: done)
        }
    }

    func showProgress(title: String, progress: BulkProgress) -> () -> Void {
        let handle = Sheets.show { ProgressSheet(title: title, progress: progress) }
        return { handle.dismiss() }
    }

    func showRecord(title: String, record: JSONValue) {
        InfoWindows.showRecord(title: title, record: record)
    }

    func showMerakiInfo(_ info: MerakiInfo) {
        let note: String
        if let seen = info.networksSeen, seen > 1 {
            note = "Seen on \(seen) networks — showing the most recent. See Full response… for all."
        } else {
            note = "Right-click a field to copy it."
        }
        InfoWindows.showMeraki(deviceName: info.deviceName, mac: info.mac, networkName: info.networkName,
                               client: info.client, note: note,
                               changeLabel: info.networksSeen == nil ? "Change network…" : "Search a network…",
                               onChangeNetwork: info.changeNetwork)
    }

    func pickMerakiOrg(_ orgs: [NamedID], savedID: String) async -> NamedID? {
        await Sheets.present { done in MerakiOrgSheet(orgs: orgs, savedID: savedID, done: done) }
    }

    func pickMerakiNetwork(_ meraki: MerakiClient, savedOrgID: String,
                           savedNetworkID: String) async -> MerakiNetworkChoice? {
        await Sheets.present(resizable: true) { done in
            MerakiNetworkSheet(meraki: meraki, savedOrgID: savedOrgID, savedNetworkID: savedNetworkID, done: done)
        }
    }

    func setupGuide(_ status: SetupStatus) async -> SetupGuideChoice {
        NSApp.activate(ignoringOtherApps: true)
        return await Sheets.present { done in SetupGuideSheet(status: status, done: done) }
    }

    /// Settings live in our own window rather than a SwiftUI `Settings` scene:
    /// newer macOS versions only open that scene from a `SettingsLink`, which
    /// can't be used from model code (first launch, "add credentials first" prompts).
    func openSettings() {
        guard let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.show(model: model)
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

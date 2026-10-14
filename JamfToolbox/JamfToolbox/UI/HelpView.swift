import AppKit
import SwiftUI

@MainActor
enum HelpWindow {
    private static weak var current: NSWindow?

    static func show() {
        if let current, current.isVisible {
            current.makeKeyAndOrderFront(nil)
            return
        }
        let box = WindowBox()
        let window = Windows.show(title: "\(Dialogs.appName) Help", size: CGSize(width: 660, height: 620),
                                  minSize: CGSize(width: 480, height: 320)) {
            HelpView(box: box)
        }
        box.window = window
        current = window
    }
}

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let paragraphs: [String]
}

private let helpSections: [HelpSection] = [
    HelpSection(title: "Getting started", paragraphs: [
        "1. Open Settings (⌘, or the gear button) and enter your Jamf Pro URL and credentials. An API client "
            + "(Settings > System > API roles and clients in Jamf Pro) is recommended over a user account.",
        "2. Grant the API role at least these privileges: Read Computers, Update Computers, Read Mobile Devices, "
            + "Send Mobile Device Commands (Lost Mode, Set Device Name, Update Inventory, Lock Device), Send "
            + "Computer Remote Lock Command, and the MDM command privileges.",
        "3. Use Test Connection to verify, then Save. Settings are kept in "
            + "~/Library/Application Support/JamfToolbox, and credentials in your macOS Keychain.",
        "4. If your server's certificate comes from an internal CA and the connection fails with a certificate "
            + "error, export that CA as a .pem file and choose it as the CA bundle in Settings > Connection. "
            + "Disabling verification is a last resort.",
    ]),
    HelpSection(title: "Menus and shortcuts", paragraphs: [
        "⌘N search to add devices, ⌘R refresh info, ⌘E export, ⌘C copy selected rows, ⌘A select all, ⌘↑ / ⌘↓ move "
            + "selected rows, Delete remove selected rows from the list, ⌘, settings. Every action is also in "
            + "the Device menu and the toolbar's Actions menu.",
    ]),
    HelpSection(title: "Using the app", paragraphs: [
        "The main window has a tab for Computers and a tab for Mobile Devices, each with its own saved "
            + "working list, search field, selection and sort. Switching tabs keeps each tab as you left it. "
            + "Lists persist between launches; the column layout is shared by both tabs.",
        "Add devices: click the search field at the top of the tab (or press ⌘N) and start typing a name, "
            + "serial, username, or asset tag. Matching devices appear in a dropdown as you type; press "
            + "↑ / ↓ and Return, or click one, to add it to the list. The field stays ready so you can add "
            + "several in a row. Devices already in your list are marked “In list”; choosing one just "
            + "selects it. Esc closes the dropdown. Each tab's search field searches its own device type.",
        "Delete or Backspace (or File > Remove from List) takes devices off the list only. It never touches Jamf. Refresh Info re-fetches the listed "
            + "devices' details from Jamf Pro and drops devices that no longer exist there. Details (model, "
            + "Wi-Fi MAC, IP) are also filled in automatically when a device is added. For computers the MAC "
            + "shown is the primary MAC reported to Jamf, and the IP is the last reported LAN IP; both are "
            + "only as fresh as the device's last check-in.",
        "Columns: right-click any column header to show or hide fields, choose Arrange Columns… for a dialog, "
            + "or Reset to Default Columns. You can also drag headers to reorder them and drag their edges to "
            + "resize. Your selection and order are saved. Devices saved before a column existed show blanks "
            + "there until you run Refresh Info once.",
        "Sorting: click a column header to sort by it (click again to reverse). Or select rows and use the "
            + "up/down buttons (⌘↑ / ⌘↓) to move them by hand. A manual move clears the column sort.",
        "Export writes the current list to a CSV or Excel (.xlsx) file; choose the format in the save dialog.",
        "Copying: right-click a cell to copy that field, or use the Copy submenu for the selected row(s), the "
            + "row(s) as CSV, or the whole list as CSV. ⌘C copies the selected rows as tab-separated text. CSV copies include a header row "
            + "and paste cleanly into a spreadsheet or a ticket.",
        "Bulk actions: select several devices (Shift-click, ⌘-click, or ⌘A), then right-click and choose "
            + "Toggle Lost Mode, Lock Device, Rename Device, or Open in Jamf Pro; the menu shows how many are "
            + "selected. Each shows exactly what will happen before anything is sent, runs one device at a "
            + "time with a progress sheet you can cancel, and logs a per-device result plus a summary. Bulk "
            + "rename asks which name format to use; bulk Lost Mode asks once whether to enable or "
            + "disable and applies that to every selected device; bulk locking a Mac uses one PIN for the "
            + "whole batch.",
        "Actions: right-click a device and choose an action from the top of the menu, or use the Device menu. "
            + "Double-clicking a row runs a configurable action (Settings > Connection; the default opens the "
            + "device in Jamf Pro). Actions that apply to mobile devices only (Toggle Lost Mode and Update "
            + "Inventory) are shown disabled for computers, because Jamf Pro has no equivalent remote command "
            + "for a Mac. If previews are enabled in Settings, you can review and edit the final message or "
            + "name before anything is sent.",
        "Advanced: right-click a device and choose Advanced (also in the Device menu and the toolbar's "
            + "Actions menu) for Restart, Shut Down, Send Blank Push, Clear Passcode, Clear Screen Time "
            + "Passcode, Wipe, and Delete. Clear Passcode and Clear Screen Time Passcode are mobile-only, and "
            + "Restart, Shut Down and Clear Screen Time Passcode need a supervised device. These act on one "
            + "device at a time. Wiping asks you to type the device's name (and, for a Mac, set a 6-digit "
            + "PIN). Delete removes the device's record from Jamf Pro; wipe the device first, because once "
            + "the record is gone Jamf can no longer send it commands. If your account lacks the privilege "
            + "for a command, nothing is sent and the message names the privilege to ask for.",
        "Jamf Audits: the third tab runs reports against Jamf Pro and keeps the results. Reports only read; the "
            + "one exception is Config Profiles in Scope, whose Change Scope menu edits a profile's scope after asking. Choose a "
            + "category and a report, fill in its options, and click Run Audit. Static Groups: Group Dependencies, "
            + "Empty Groups, Unused Groups, Stale Group Members, Duplicate Group Names, Compare Group to a List, "
            + "and a device's Group Memberships. Configuration Profiles: Unscoped or Scoped to All, Included and "
            + "Excluded, Deleted or Empty Groups in Scope, Overlapping Payloads, Failed or Pending Installs, a device's "
            + "Profiles vs. Scope, and a device's Config Profiles in Scope (how each profile reaches it, with Exclude and Remove Target actions). Device Health: Stale Check-in, Unsupervised Mobile Devices, OS Below "
            + "Target, FileVault Off, No Assigned User, Duplicate Serial Numbers, Pending MDM Commands. Policies: "
            + "Disabled but Still Scoped, Enabled with No Scope, Recent Failures, Ongoing with No Trigger.",
        "Device reports use devices from your Computers and Mobile Devices lists; you can also right-click a "
            + "device and choose Audit. Results are saved automatically: sort them by date, report, subject or "
            + "count, and delete them individually or with Delete Older Than. Run Again repeats a report with the "
            + "same options. Double-click a finding to open it in Jamf Pro, or export the findings to CSV. Object "
            + "types your account can't read are listed as warnings, meaning a result may be incomplete. Recent "
            + "Failures reads every computer's policy history, so it takes longer than the others.",
        "The Activity log at the bottom can be resized by dragging the divider above it; right-click the log to "
            + "copy or clear it.",
        "Show Info opens the device's full Jamf Pro record as a collapsible tree. Use the filter box to find "
            + "fields, right-click any field to copy its value or name (branches copy as JSON), or press ⌘C on "
            + "a selection. The window stays open, so you can keep it beside the main list.",
        "Network Info looks up the selected device's Wi-Fi MAC in the Meraki Dashboard and shows its "
            + "description, IP, recent SSID, the AP it's connected to, when it was last seen, and its status. "
            + "Add a Dashboard API key in Settings > Meraki first. The search covers your whole organization "
            + "in a single request, so there is no network to pick; the network the device was found on is "
            + "shown in the window. If your key can see several organizations you are asked once and the "
            + "choice is remembered. If a device isn't found (it hasn't been on the Wi-Fi recently) you can "
            + "fall back to searching one network. The MAC address is re-read from Jamf Pro on every lookup "
            + "so a stale row can't send the query to the wrong device. If a device has Private Wi-Fi Address "
            + "enabled for your SSID, Meraki sees a randomized MAC and the lookup won't match the hardware "
            + "MAC Jamf reports.",
        "Toggle Lost Mode checks whether Lost Mode is currently on for the selected device and offers the "
            + "opposite action: it previews your message before enabling, and simply confirms before turning "
            + "it off. Supervised mobile devices only.",
        "Presets: Settings > Templates holds any number of device-name formats, Lost Mode messages (each "
            + "with its own phone and footnote) and lock messages. Any name format can be used for computers or "
            + "mobile devices. Use + and − to add and remove them, and Make Default to "
            + "choose the one used when previews are off. When you rename, enable Lost Mode or lock a device, "
            + "pick a preset at the top of the preview and edit the text if needed; bulk actions ask once for the "
            + "whole batch and fill in each device's {tags}. Locked mobile devices show the message on their "
            + "lock screen.",
        "Rename sends the Set Device Name command through Jamf Pro's modern MDM commands API for mobile "
            + "devices; for computers it updates the record name and sends the SETTINGS MDM command. The new "
            + "name appears in Jamf's inventory after the device's next check-in; use Refresh Info to pull it in.",
        "Locking a computer prompts for a 6-digit PIN that is required to unlock it. Keep that PIN somewhere "
            + "safe; it is also written to the Activity log. Mobile devices lock with their existing passcode "
            + "instead.",
    ]),
    HelpSection(title: "Template tags", paragraphs: [
        "Templates in Settings may contain tags in curly braces. Each tag is replaced with data from the "
            + "selected device's record when a command is sent. Unknown tags are left untouched so typos are "
            + "easy to spot.",
    ]),
]

struct HelpView: View {
    let box: WindowBox

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(Dialogs.appName) \(AppModel.version)")
                        .font(.title2.weight(.semibold))
                    Text("Run common one-off Jamf Pro tasks against computers and mobile devices: Lost Mode, "
                         + "rename, lock, update inventory, and more, using templated messages and names.")
                        .foregroundStyle(.secondary)

                    ForEach(helpSections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            ForEach(section.paragraphs, id: \.self) { paragraph in
                                Text(paragraph).fixedSize(horizontal: false, vertical: true)
                            }
                            if section.title == "Template tags" { tagTable }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { box.close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }

    private var tagTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(Templates.tagDescriptions, id: \.tag) { item in
                GridRow {
                    Text(item.tag).font(.system(.body, design: .monospaced))
                    Text(item.description).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

#if DEBUG
#Preview { HelpView(box: WindowBox()).frame(width: 660, height: 620) }
#endif

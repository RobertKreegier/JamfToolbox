import AppKit
import SwiftUI
import JamfToolboxCore

/// Shown at launch (and when an action needs Jamf Pro) while the app isn't set
/// up: what it needs from Jamf Pro and Meraki, and a way into Settings.
struct SetupGuideSheet: View {
    let status: SetupStatus
    let done: (SetupGuideChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.firstRun ? "Welcome to Jamf Toolbox" : "Finish setting up")
                        .font(.title2.weight(.semibold))
                    Text("Jamf Toolbox works through your organization's Jamf Pro server and, optionally, "
                         + "Cisco Meraki. Add them in Settings to get started.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SetupGuideItem(ready: status.jamfReady, title: "Jamf Pro", tag: "Required",
                           text: status.jamfReady ? SetupGuideText.jamfReady : SetupGuideText.jamfMissing)
            SetupGuideItem(ready: status.merakiReady, title: "Cisco Meraki", tag: "Optional",
                           text: SetupGuideText.meraki(status))

            HStack {
                Spacer()
                Button("Later") { done(.later) }
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings") { done(.openSettings) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct SetupGuideItem: View {
    let ready: Bool
    let title: String
    let tag: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(tag).font(.caption).foregroundStyle(.secondary)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
#Preview("First run") {
    SetupGuideSheet(status: SetupStatus(jamfReady: false, merakiReady: false), done: { _ in })
}
#endif

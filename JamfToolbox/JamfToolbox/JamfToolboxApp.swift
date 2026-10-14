import SwiftUI

@main
struct JamfToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Jamf Toolbox", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 1100, height: 620)
        .commands { ToolboxCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One main window: closing it quits, as the Python app did.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ToolboxCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("Find Devices to Add") { model.openAddDialog() }
                .keyboardShortcut("n")
            Button("Refresh Info") { Task { await model.refreshList() } }
                .keyboardShortcut("r")
                .disabled(!model.showingDevices || model.entries.isEmpty)
            Divider()
            Button("Remove from List") { Task { await model.removeSelected() } }
                .disabled(!model.showingDevices || model.selection.isEmpty)
            Button("Export…") { Task { await model.exportList() } }
                .keyboardShortcut("e")
                .disabled(!model.showingDevices || model.entries.isEmpty)
        }

        // Every action lives here too, so the whole app is reachable from the
        // keyboard. Mobile-only actions stay visible but disabled on computers.
        CommandMenu("Device") {
            ForEach(DeviceAction.allCases) { action in
                Button(DeviceMenuLabel.title(for: action, selectionCount: model.selection.count)) {
                    model.perform(action)
                }
                .disabled(!model.canPerform(action))
                if action == .networkInfo || action == .updateInventory { Divider() }
            }
            Divider()
            Menu("Advanced") {
                ForEach(AdvancedCommand.available(for: model.deviceType)) { command in
                    Button(command.label + (command.needsEllipsis ? "…" : "")) { model.perform(command) }
                        .disabled(!model.canPerform(command))
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Jamf Toolbox Help") { HelpWindow.show() }
                .keyboardShortcut("?")
        }
    }
}

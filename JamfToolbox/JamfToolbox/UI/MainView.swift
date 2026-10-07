import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Lives in the content, not the toolbar: a toolbar item that changes
            // with state left the title bar undraggable until the window was resized.
            Picker("Device type", selection: $model.deviceType) {
                Text("Computers").tag(DeviceType.computer)
                Text("Mobile Devices").tag(DeviceType.mobile)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.vertical, 8)
            .help("Switch between your computer and mobile device lists")
            Divider()
            VSplitView {
                DeviceTableView(entries: model.entries,
                                columns: model.visibleColumns,
                                selection: model.selection,
                                sort: model.sort,
                                reveal: model.reveal,
                                model: model)
                    .frame(minHeight: 160)

                LogPane(model: model)
                    .frame(minHeight: 90, idealHeight: 150)
            }
            Divider()
            StatusBar(log: model.log, total: model.entries.count, selected: model.selection.count)
        }
        .frame(minWidth: 860, minHeight: 460)
        .toolbar { toolbarContent }
        .onAppear { model.start() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.openAddDialog() } label: {
                Label("Add Devices", systemImage: "plus")
            }
            .help("Search Jamf Pro and add devices to the list (⌘N)")

            Button { Task { await model.removeSelected() } } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(model.selection.isEmpty)
            .help("Remove the selected devices from this list. Nothing changes in Jamf Pro.")

            Button { Task { await model.refreshList() } } label: {
                Label("Refresh Info", systemImage: "arrow.clockwise")
            }
            .disabled(model.entries.isEmpty)
            .help("Re-read every device in the list from Jamf Pro (⌘R)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.moveSelected(-1) } label: {
                Label("Move Up", systemImage: "chevron.up")
            }
            .disabled(model.selection.isEmpty)
            .help("Move the selected devices up (⌘↑)")

            Button { model.moveSelected(1) } label: {
                Label("Move Down", systemImage: "chevron.down")
            }
            .disabled(model.selection.isEmpty)
            .help("Move the selected devices down (⌘↓)")

            Button { Task { await model.exportList() } } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.entries.isEmpty)
            .help("Export the list to CSV or Excel (⌘E)")

            Menu {
                ForEach(DeviceAction.allCases) { action in
                    Button { model.perform(action) } label: {
                        Label(DeviceMenuLabel.title(for: action, selectionCount: model.selection.count),
                              systemImage: action.symbolName)
                    }
                    .disabled(!model.canPerform(action))
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .help("Actions for the selected device")

            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}

/// Menu titles for device actions: the selection count shows when an action
/// will run in bulk, and actions that prompt first get an ellipsis.
enum DeviceMenuLabel {
    static func title(for action: DeviceAction, selectionCount: Int) -> String {
        var title = action.label
        if selectionCount > 1 && action.supportsBulk { title += " (\(selectionCount))" }
        if action.needsEllipsis { title += "…" }
        return title
    }
}

private struct LogPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            LogTextView(log: model.log, model: model)
        }
    }
}

private struct StatusBar: View {
    @ObservedObject var log: ActivityLog
    let total: Int
    let selected: Int

    var body: some View {
        HStack(spacing: 8) {
            if log.isBusy { ProgressView().controlSize(.small) }
            Text(log.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(selected > 0 ? "\(selected) of \(total) selected" : "\(total) device\(total == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

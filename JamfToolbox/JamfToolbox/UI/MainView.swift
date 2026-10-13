import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Lives in the content, not the toolbar: a toolbar item that changes
            // with state left the title bar undraggable until the window was resized.
            HStack {
                DeviceSearchField(search: model.search, deviceType: model.deviceType)
                    .frame(width: 320)
                Spacer()
                Picker("Device type", selection: deviceTypeBinding) {
                    Text("Computers").tag(DeviceType.computer)
                    Text("Mobile Devices").tag(DeviceType.mobile)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .help("Switch between your computer and mobile device lists")
                Spacer()
                Color.clear.frame(width: 320, height: 1)   // balances the search field so the switch centers
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            VSplitView {
                DeviceTableView(entries: model.entries,
                                columns: model.visibleColumns,
                                selection: model.selection,
                                sort: model.sort,
                                reveal: model.reveal,
                                model: model)
                    .frame(minHeight: 160, idealHeight: 2000)
                    .layoutPriority(1)

                // Opens at its minimum height; drag the divider to enlarge it.
                LogPane(model: model)
                    .frame(minHeight: 90, idealHeight: 90)
            }
            Divider()
            StatusBar(log: model.log, total: model.entries.count, selected: model.selection.count)
        }
        .frame(minWidth: 860, minHeight: 460)
        .overlay(alignment: .topLeading) { DeviceSearchDropdown(search: model.search) }
        .toolbar { toolbarContent }
        .onAppear { model.start() }
    }

    /// Switching lists changes several published properties (selection, sort,
    /// search). The segmented control can write its binding during a view
    /// update, which SwiftUI flags as "publishing changes from within view
    /// updates", so hop to the next run-loop turn before changing the model.
    private var deviceTypeBinding: Binding<DeviceType> {
        Binding(
            get: { model.deviceType },
            set: { newValue in
                DispatchQueue.main.async { model.deviceType = newValue }
            })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Adding happens in the search field and removing with Delete/Backspace
        // (or File > Remove from List), so only Refresh needs a button here.
        ToolbarItem(placement: .navigation) {
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
                Divider()
                Menu("Advanced") {
                    ForEach(AdvancedCommand.available(for: model.deviceType)) { command in
                        Button { model.perform(command) } label: {
                            Label(command.label + (command.needsEllipsis ? "…" : ""), systemImage: command.symbolName)
                        }
                        .disabled(!model.canPerform(command))
                    }
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

#if DEBUG
#Preview("Computers") {
    MainView(model: PreviewData.model(selected: ["102"]))
        .frame(width: 1100, height: 620)
}

#Preview("Mobile Devices") {
    MainView(model: PreviewData.model(type: .mobile))
        .frame(width: 1100, height: 620)
}
#endif

import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                TabView(selection: $model.tab) {
                    DeviceListTab(model: model, type: .computer)
                        .tabItem { Text("Computers") }
                        .tag(MainTab.computers)
                    DeviceListTab(model: model, type: .mobile)
                        .tabItem { Text("Mobile Devices") }
                        .tag(MainTab.mobile)
                    AuditsTab(center: model.audits)
                        .tabItem { Text("Jamf Audits") }
                        .tag(MainTab.audits)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(minHeight: 220, idealHeight: 2000)
                .layoutPriority(1)

                // Shared by both tabs. Opens at its minimum height; drag the divider to enlarge it.
                LogPane(model: model)
                    .frame(minHeight: 90, idealHeight: 90)
            }
            Divider()
            StatusBar(log: model.log, audits: model.audits, showingDevices: model.showingDevices,
                      deviceSummary: deviceSummary)
        }
        .frame(minWidth: 860, minHeight: 460)
        .toolbar { toolbarContent }
        .onAppear { model.start() }
    }

    private var deviceSummary: String {
        let total = model.entries.count, selected = model.selection.count
        return selected > 0 ? "\(selected) of \(total) selected" : "\(total) device\(total == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Adding happens in the search field and removing with Delete/Backspace
        // (or File > Remove from List), so only Refresh needs a button here.
        ToolbarItem(placement: .navigation) {
            Button { Task { await model.refreshList() } } label: {
                Label("Refresh Info", systemImage: "arrow.clockwise")
            }
            .disabled(!model.showingDevices || model.entries.isEmpty)
            .help("Re-read every device in the list from Jamf Pro (⌘R)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.moveSelected(-1) } label: {
                Label("Move Up", systemImage: "chevron.up")
            }
            .disabled(!model.showingDevices || model.selection.isEmpty)
            .help("Move the selected devices up (⌘↑)")

            Button { model.moveSelected(1) } label: {
                Label("Move Down", systemImage: "chevron.down")
            }
            .disabled(!model.showingDevices || model.selection.isEmpty)
            .help("Move the selected devices down (⌘↓)")

            Button { Task { await model.exportList() } } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.showingDevices || model.entries.isEmpty)
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
            .disabled(!model.showingDevices)
            .help("Actions for the selected device")

            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}

/// One device tab: its own search field, table, selection and sort.
private struct DeviceListTab: View {
    @ObservedObject var model: AppModel
    let type: DeviceType

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DeviceSearchField(search: model.search(for: type), deviceType: type)
                    .frame(width: 320)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            DeviceTableView(entries: model.entries(for: type),
                            columns: model.visibleColumns,
                            selection: model.selection(for: type),
                            sort: model.sort(for: type),
                            reveal: model.reveal(for: type),
                            type: type,
                            model: model)
        }
        .overlay(alignment: .topLeading) { DeviceSearchDropdown(search: model.search(for: type)) }
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
    /// Observed directly so the saved-result count stays current on the Audits tab.
    @ObservedObject var audits: AuditCenter
    let showingDevices: Bool
    let deviceSummary: String

    private var summary: String {
        guard !showingDevices else { return deviceSummary }
        let count = audits.results.count
        return "\(count) saved result\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 8) {
            if log.isBusy { ProgressView().controlSize(.small) }
            Text(log.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(summary)
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

import AppKit
import SwiftUI

/// Lets a free-standing window close itself.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
    func close() { window?.close() }
}

extension AppModel {
    func openAddDialog() {
        Task {
            guard let client = await requireClient() else { return }
            let box = WindowBox()
            let type = deviceType
            box.window = Windows.show(title: "Add \(type.pluralName)", size: CGSize(width: 680, height: 440),
                                      minSize: CGSize(width: 540, height: 320)) {
                AddDevicesView(model: self, client: client, type: type, box: box)
            }
        }
    }
}

/// Search Jamf Pro and add one or more results to the working list.
/// Stays open after adding so several devices can be added in a row.
struct AddDevicesView: View {
    @ObservedObject var model: AppModel
    let client: JamfClient
    let type: DeviceType
    let box: WindowBox

    @State private var query = ""
    @State private var results: [DeviceEntry] = []
    @State private var selection = Set<String>()
    @State private var status = "Type a search and press Return. ⌘-click to select several."
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var existingIDs: Set<String> {
        Set(model.settings.prefs.deviceList(for: type).map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search \(type.pluralName) by name, serial, username, or asset tag:")
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(searching)
            }

            let added = existingIDs
            Table(results, selection: $selection) {
                TableColumn("Name") { Cell(text: $0.value(.name), dimmed: added.contains($0.id)) }
                TableColumn("Serial") { Cell(text: $0.value(.serial), dimmed: added.contains($0.id)) }
                TableColumn("Username") { Cell(text: $0.value(.username), dimmed: added.contains($0.id)) }
                TableColumn("Model") { Cell(text: $0.value(.model), dimmed: added.contains($0.id)) }
            }
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { _ in
                addSelected()   // double-click
            }

            HStack {
                if searching { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Add Selected") { addSelected() }
                    .disabled(selection.isEmpty)
                Button("Done") { box.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .onAppear { searchFocused = true }
    }

    private struct Cell: View {
        let text: String
        let dimmed: Bool
        var body: some View {
            Text(text).foregroundStyle(dimmed ? .secondary : .primary)
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = true
        status = "Searching…"
        Task {
            defer { searching = false }
            do {
                let records = type == .computer
                    ? try await client.searchComputers(term)
                    : try await client.searchMobileDevices(term)
                results = records.map { record in
                    DeviceEntry(id: record["id"]?.text ?? "", fields: [
                        "name": record["name"]?.text ?? "",
                        "serial": record["serial_number"]?.text ?? "",
                        "username": record["username"]?.text ?? "",
                        "wifi_mac": record["wifi_mac_address"]?.text ?? "",
                        "ip": "",
                        "model": record["model"]?.text ?? "",
                    ])
                }.filter { !$0.id.isEmpty }
                selection = []
                let already = results.filter { existingIDs.contains($0.id) }.count
                let note = already > 0 ? " (\(already) already in your list, shown in gray)" : ""
                status = "\(results.count) result(s)\(note)."
            } catch {
                status = "Search failed."
                await Dialogs.error(model.describe(error))
            }
        }
    }

    private func addSelected() {
        guard !selection.isEmpty else {
            status = "Select one or more results to add."
            return
        }
        let existing = existingIDs
        let chosen = results.filter { selection.contains($0.id) }
        let fresh = chosen.filter { !existing.contains($0.id) }
        if !fresh.isEmpty { model.addEntries(fresh, type: type) }
        var parts: [String] = []
        if !fresh.isEmpty { parts.append("Added \(fresh.count) device(s)") }
        let skipped = chosen.count - fresh.count
        if skipped > 0 { parts.append("\(skipped) already in your list") }
        status = parts.isEmpty ? "Nothing to add." : parts.joined(separator: ". ") + "."
    }
}

// MARK: - Arrange columns

/// Choose which columns the device list shows, and in what order.
struct ColumnsSheet: View {
    @State var shown: [ColumnField]
    let done: ([ColumnField]?) -> Void

    @State private var availableSelection: ColumnField.ID?
    @State private var shownSelection: ColumnField.ID?

    private var available: [ColumnField] { ColumnField.allCases.filter { !shown.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrange Columns").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                column("Available", fields: available, selection: $availableSelection)

                VStack(spacing: 8) {
                    Spacer().frame(height: 28)
                    Button("Add →") { add() }
                        .disabled(availableSelection == nil)
                    Button("← Remove") { remove() }
                        .disabled(shownSelection == nil || shown.count <= 1)
                    Divider().frame(width: 60)
                    Button("Move Up") { move(-1) }
                        .disabled(shownSelection == nil)
                    Button("Move Down") { move(1) }
                        .disabled(shownSelection == nil)
                }

                column("Shown (top = left)", fields: shown, selection: $shownSelection)
            }
            HStack {
                Button("Reset to Defaults") {
                    shown = ColumnField.defaults
                    availableSelection = nil
                    shownSelection = nil
                }
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { done(shown) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 380, idealHeight: 420)
    }

    private func column(_ title: String, fields: [ColumnField], selection: Binding<ColumnField.ID?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            List(fields, selection: selection) { Text($0.heading) }
                .frame(minWidth: 170)
        }
    }

    private func add() {
        guard let id = availableSelection, let field = ColumnField(rawValue: id) else { return }
        shown.append(field)
        availableSelection = nil
        shownSelection = field.id
    }

    private func remove() {
        guard let id = shownSelection, shown.count > 1,
              let index = shown.firstIndex(where: { $0.id == id }) else { return }   // keep at least one column
        shown.remove(at: index)
        shownSelection = nil
    }

    private func move(_ direction: Int) {
        guard let id = shownSelection, let index = shown.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard shown.indices.contains(target) else { return }
        shown.swapAt(index, target)
    }
}

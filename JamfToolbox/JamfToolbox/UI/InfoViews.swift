import AppKit
import SwiftUI

/// Opens the non-modal info windows.
@MainActor
enum InfoWindows {
    static func showRecord(title: String, record: JSONValue) {
        let box = WindowBox()
        box.window = Windows.show(title: title, size: CGSize(width: 720, height: 580),
                                  minSize: CGSize(width: 480, height: 320)) {
            RecordTreeView(record: record, box: box)
        }
    }

    static func showMeraki(deviceName: String, mac: String, networkName: String, client: JSONValue,
                           note: String, changeLabel: String, onChangeNetwork: @escaping () -> Void) {
        let box = WindowBox()
        box.window = Windows.show(title: "Meraki info — \(deviceName)", size: CGSize(width: 520, height: 400),
                                  minSize: CGSize(width: 440, height: 360)) {
            MerakiInfoView(deviceName: deviceName, mac: mac, networkName: networkName, client: client,
                           note: note, changeLabel: changeLabel, onChangeNetwork: onChangeNetwork, box: box)
        }
    }
}

// MARK: - Record tree

private struct TreeRow: Identifiable {
    let id: String          // slash-joined path, unique within the record
    let depth: Int
    let key: String
    let value: JSONValue
    var isBranch: Bool { value.isContainer }
}

/// Browse a device's full API record as a collapsible key/value tree,
/// mirroring the structure returned by the Jamf Pro classic API. Any field can
/// be copied, and the whole record can be filtered.
struct RecordTreeView: View {
    let record: JSONValue
    let box: WindowBox

    @State private var filter = ""
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var copyNote: String?

    init(record: JSONValue, box: WindowBox) {
        self.record = record
        self.box = box
        // Open the top-level sections (general, location, hardware, …).
        var open = Set<String>()
        if case .object(let entries) = record {
            for entry in entries where entry.value.isContainer { open.insert(entry.key) }
        }
        _expanded = State(initialValue: open)
    }

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rows currently visible, honoring expansion and the filter.
    private var rows: [TreeRow] {
        var out: [TreeRow] = []
        if case .object(let entries) = record {
            for entry in entries { out += build(key: entry.key, value: entry.value, path: entry.key, depth: 0) }
        }
        return out
    }

    private func matches(_ key: String, _ value: JSONValue) -> Bool {
        let q = query.lowercased()
        return key.lowercased().contains(q) || (!value.isContainer && value.preview.lowercased().contains(q))
    }

    private func build(key: String, value: JSONValue, path: String, depth: Int) -> [TreeRow] {
        let row = TreeRow(id: path, depth: depth, key: key, value: value)
        guard value.isContainer else {
            return query.isEmpty || matches(key, value) ? [row] : []
        }
        let open = !query.isEmpty || expanded.contains(path)
        var children: [TreeRow] = []
        if open || !query.isEmpty {
            switch value {
            case .object(let entries):
                for entry in entries {
                    children += build(key: entry.key, value: entry.value, path: path + "/" + entry.key, depth: depth + 1)
                }
            case .array(let items):
                for (index, item) in items.enumerated() {
                    children += build(key: "[\(index)]", value: item, path: path + "/[\(index)]", depth: depth + 1)
                }
            default: break
            }
        }
        if !query.isEmpty && !matches(key, value) && children.isEmpty { return [] }
        return [row] + (open ? children : [])
    }

    var body: some View {
        let visible = rows
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Expand All") { setAll(open: true) }
                Button("Collapse All") { setAll(open: false) }
            }
            .padding(12)

            HStack(spacing: 0) {
                Text("Field").frame(width: keyColumnWidth, alignment: .leading)
                Text("Value")
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            List(visible, selection: $selection) { row in
                rowView(row)
                    .contextMenu { menu(for: row) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onCopyCommand {
                guard let id = selection, let row = visible.first(where: { $0.id == id }) else { return [] }
                return [NSItemProvider(object: text(for: row.value) as NSString)]
            }

            HStack {
                Text(statusText(count: visible.count)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Copy All as JSON") { copy(record.prettyPrinted(), what: "full record") }
                Button("Close") { box.close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onChange(of: filter) { _ in copyNote = nil }
    }

    private let keyColumnWidth: CGFloat = 300

    private func statusText(count: Int) -> String {
        if let copyNote { return copyNote }
        return query.isEmpty ? "Right-click a field to copy it. ⌘C copies the selected value."
                             : "\(count) field(s) shown. Filter: “\(query)”"
    }

    private func rowView(_ row: TreeRow) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer().frame(width: CGFloat(row.depth) * 16)
                if row.isBranch {
                    Button {
                        toggle(row.id)
                    } label: {
                        Image(systemName: expanded.contains(row.id) || !query.isEmpty ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(row.key).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: keyColumnWidth - 16, alignment: .leading)

            Text(row.value.preview)
                .foregroundStyle(row.isBranch ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(for row: TreeRow) -> some View {
        let value = text(for: row.value)
        if row.isBranch {
            Button("Copy “\(row.key)” as JSON") { copy(value, what: row.key) }
        } else {
            let shown = value.count <= 40 ? value : String(value.prefix(37)) + "…"
            Button(shown.isEmpty ? "Copy value" : "Copy value (\(shown))") { copy(value, what: row.key) }
            Button("Copy field name") { copy(row.key, what: "field name") }
            Button("Copy “field: value”") { copy("\(row.key): \(value)", what: row.key) }
        }
    }

    private func text(for value: JSONValue) -> String {
        value.isContainer ? value.prettyPrinted() : value.preview
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func setAll(open: Bool) {
        guard open else { expanded = []; return }
        var all = Set<String>()
        func walk(_ value: JSONValue, _ path: String) {
            switch value {
            case .object(let entries):
                all.insert(path)
                for entry in entries where entry.value.isContainer { walk(entry.value, path.isEmpty ? entry.key : path + "/" + entry.key) }
            case .array(let items):
                all.insert(path)
                for (index, item) in items.enumerated() where item.isContainer { walk(item, path + "/[\(index)]") }
            default: break
            }
        }
        if case .object(let entries) = record {
            for entry in entries where entry.value.isContainer { walk(entry.value, entry.key) }
        }
        expanded = all
    }

    private func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let shown = text.count <= 60 && !text.contains("\n") ? text : "\(text.count) characters"
        copyNote = "Copied \(what): \(shown)"
    }
}

// MARK: - Meraki client info

struct MerakiInfoView: View {
    let deviceName: String
    let mac: String
    let networkName: String
    let client: JSONValue
    let note: String
    let changeLabel: String
    let onChangeNetwork: () -> Void
    let box: WindowBox

    @State private var status: String

    init(deviceName: String, mac: String, networkName: String, client: JSONValue, note: String,
         changeLabel: String, onChangeNetwork: @escaping () -> Void, box: WindowBox) {
        self.deviceName = deviceName
        self.mac = mac
        self.networkName = networkName
        self.client = client
        self.note = note
        self.changeLabel = changeLabel
        self.onChangeNetwork = onChangeNetwork
        self.box = box
        _status = State(initialValue: note)
    }

    private var fields: [(label: String, value: String)] {
        let connection = client["recentDeviceConnection"]?.text ?? ""
        var apLabel = "Connected AP"
        if !connection.isEmpty && connection.lowercased() != "wireless" { apLabel = "Connected via (\(connection))" }
        var ap = client["recentDeviceName"]?.text ?? ""
        if ap.isEmpty { ap = client["recentDeviceMac"]?.text ?? "" }
        return [
            ("Description", client["description"]?.text ?? ""),
            ("IP address", client["ip"]?.text ?? ""),
            ("Recent SSID", client["ssid"]?.text ?? ""),
            (apLabel, ap),
            ("Last seen", friendlyTimestamp(client["lastSeen"])),
            ("Status", client["status"]?.text ?? ""),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(deviceName)   (\(normalizeMAC(mac)))").font(.title3.weight(.semibold))
                Text("Network: \(networkName)").foregroundStyle(.secondary)
            }

            Form {
                ForEach(fields, id: \.label) { field in
                    LabeledContent(field.label) {
                        Text(field.value.isEmpty ? "—" : field.value)
                            .textSelection(.enabled)
                            .foregroundStyle(field.value.isEmpty ? .secondary : .primary)
                            .contextMenu { menu(label: field.label, value: field.value) }
                    }
                }
            }
            .formStyle(.grouped)

            Text(status).foregroundStyle(.secondary).font(.callout).lineLimit(2)

            HStack {
                Button(changeLabel) { onChangeNetwork() }
                Spacer()
                Button("Full Response…") {
                    InfoWindows.showRecord(title: "Meraki client record — \(deviceName)", record: client)
                }
                Button("Close") { box.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func menu(label: String, value: String) -> some View {
        let shown = value.count <= 40 ? value : String(value.prefix(37)) + "…"
        Button(shown.isEmpty ? "Copy value" : "Copy value (\(shown))") { copy(value, label: label) }
            .disabled(value.isEmpty)
        Button("Copy field name") { copy(label, label: "field name") }
        Button("Copy “field: value”") { copy("\(label): \(value)", label: label) }
    }

    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = value.isEmpty ? "Copied \(label) (empty)." : "Copied \(label): \(value)"
    }
}

// MARK: - Meraki pickers

/// Pick a Meraki organization when the key can see more than one.
struct MerakiOrgSheet: View {
    let orgs: [NamedID]
    let savedID: String
    let done: (NamedID?) -> Void

    @State private var choice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Meraki organization").font(.headline)
            Text("Your API key can see more than one organization. Choose the one your devices live in — "
                 + "it will be remembered.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Organization", selection: $choice) {
                ForEach(orgs) { Text($0.name).tag($0.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Organization") { done(orgs.first { $0.id == choice }) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { choice = orgs.contains { $0.id == savedID } ? savedID : (orgs.first?.id ?? "") }
    }
}

/// Pick a Meraki organization and network for the per-network fallback lookup.
struct MerakiNetworkSheet: View {
    let meraki: MerakiClient
    let savedOrgID: String
    let savedNetworkID: String
    let done: (MerakiNetworkChoice?) -> Void

    @State private var orgs: [NamedID] = []
    @State private var orgID = ""
    @State private var networks: [NamedID] = []
    @State private var filter = ""
    @State private var selection: String?
    @State private var status = "Loading organizations…"

    private var shown: [NamedID] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? networks : networks.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Meraki network").font(.headline)
            Picker("Organization", selection: $orgID) {
                ForEach(orgs) { Text($0.name).tag($0.id) }
            }
            .disabled(orgs.count < 2)
            .onChange(of: orgID) { _ in Task { await loadNetworks() } }

            TextField("Filter networks", text: $filter)
                .textFieldStyle(.roundedBorder)

            List(shown, selection: $selection) { Text($0.name) }
                .frame(minHeight: 180)
                .contextMenu(forSelectionType: String.self) { _ in
                    EmptyView()
                } primaryAction: { _ in choose() }

            Text(status).foregroundStyle(.secondary).lineLimit(2)

            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Network") { choose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 420)
        .task { await loadOrgs() }
    }

    private func loadOrgs() async {
        do {
            orgs = try await meraki.organizations().compactMap(NamedID.init(json:))
            guard !orgs.isEmpty else {
                status = "No organizations visible to this API key."
                return
            }
            orgID = orgs.contains { $0.id == savedOrgID } ? savedOrgID : orgs[0].id
        } catch {
            status = (error as? ServiceError)?.message ?? error.localizedDescription
        }
    }

    private func loadNetworks() async {
        guard let org = orgs.first(where: { $0.id == orgID }) else { return }
        status = "Loading networks in \(org.name)…"
        networks = []
        do {
            let list = try await meraki.networks(orgID: org.id).compactMap(NamedID.init(json:))
            networks = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selection = networks.contains { $0.id == savedNetworkID } ? savedNetworkID : nil
            status = "\(networks.count) network(s)."
        } catch {
            status = (error as? ServiceError)?.message ?? error.localizedDescription
        }
    }

    private func choose() {
        guard let org = orgs.first(where: { $0.id == orgID }),
              let network = networks.first(where: { $0.id == selection }) else {
            status = "Select a network first."
            return
        }
        done(MerakiNetworkChoice(org: org, network: network))
    }
}

#if DEBUG
#Preview("Record tree") {
    RecordTreeView(record: PreviewData.record, box: WindowBox())
        .frame(width: 720, height: 560)
}

#Preview("Meraki info") {
    MerakiInfoView(deviceName: "MBP-ARIVERA", mac: "a4:83:e7:12:34:56", networkName: "High School",
                   client: PreviewData.merakiClient, note: "Right-click a field to copy it.",
                   changeLabel: "Search a network…", onChangeNetwork: {}, box: WindowBox())
        .frame(width: 520, height: 400)
}

#Preview("Meraki org picker") {
    MerakiOrgSheet(orgs: [NamedID(id: "1", name: "District"), NamedID(id: "2", name: "Sandbox")],
                   savedID: "1", done: { _ in })
}
#endif

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import JamfToolboxCore

/// A device the user has picked, resolved from the working list.
struct DeviceRef: Hashable {
    let id: String
    let name: String
    let type: DeviceType
}

/// The main window's tabs.
enum MainTab: Hashable {
    case computers
    case mobile
    case audits

    /// The device list this tab shows, or nil for non-device tabs.
    var deviceType: DeviceType? {
        switch self {
        case .computers: return .computer
        case .mobile: return .mobile
        case .audits: return nil
        }
    }
}

struct SortState: Equatable {
    var field: ColumnField
    var ascending: Bool
}

/// Asks the table to scroll a row into view (after a manual move, say).
struct RevealRequest: Equatable {
    let id: String
    let token = UUID()
}

/// The app's single source of truth: settings, working lists, selection and
/// every user-facing action. Split across files by concern; this file holds
/// state, list management, columns, copying and export.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings: SettingsStore
    let log = ActivityLog()
    /// One search field per device tab.
    let searches: [DeviceType: DeviceSearch] = [
        .computer: DeviceSearch(type: .computer),
        .mobile: DeviceSearch(type: .mobile),
    ]

    @Published var tab: MainTab = .computers {
        didSet {
            guard oldValue != tab else { return }
            if let type = tab.deviceType { lastDeviceType = type }
            // An open dropdown belongs to the tab being left.
            for search in searches.values { search.dismiss() }
        }
    }

    // Each tab keeps its own selection, sort and scroll request, so switching
    // tabs and back leaves everything as it was.
    @Published private var selections: [DeviceType: Set<String>] = [:]
    @Published private var sorts: [DeviceType: SortState] = [:]
    @Published private var reveals: [DeviceType: RevealRequest] = [:]

    private var lastDeviceType: DeviceType = .computer

    /// The device type of the visible tab (or the last device tab shown, when
    /// the Audits tab is up). Menus, the toolbar and every action act on this list.
    var deviceType: DeviceType {
        get { tab.deviceType ?? lastDeviceType }
        set { tab = newValue == .mobile ? .mobile : .computers }
    }

    /// False on the Audits tab, where device commands are disabled.
    var showingDevices: Bool { tab.deviceType != nil }

    let audits: AuditCenter

    func selection(for type: DeviceType) -> Set<String> { selections[type] ?? [] }

    func setSelection(_ ids: Set<String>, for type: DeviceType) {
        if selection(for: type) != ids { selections[type] = ids }
    }

    func sort(for type: DeviceType) -> SortState? { sorts[type] }
    func reveal(for type: DeviceType) -> RevealRequest? { reveals[type] }
    func search(for type: DeviceType) -> DeviceSearch { searches[type]! }

    /// Shorthands for the visible tab.
    var selection: Set<String> {
        get { selection(for: deviceType) }
        set { setSelection(newValue, for: deviceType) }
    }
    var sort: SortState? { sorts[deviceType] }
    var search: DeviceSearch { search(for: deviceType) }

    private(set) var client: JamfClient?
    var apNames: [String: [String: String]] = [:]   // Meraki network id → AP MAC → name
    private var settingsObserver: AnyCancellable?
    private var didStart = false

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    var version: String { Self.version }

    /// Off for previews, which shouldn't pop open a Settings window.
    var opensSettingsWhenUnconfigured = true

    init(settings: SettingsStore? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        audits = AuditCenter(store: AuditStore(directory: settings.directory.appendingPathComponent("Audits", isDirectory: true)))
        // Views observe the model; forward settings changes so they refresh.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        for search in searches.values { search.model = self }
        audits.model = self
        rebuildClient()
    }

    /// Called once when the main window first appears.
    func start() {
        guard !didStart else { return }
        didStart = true
        let hasURL = !settings.prefs.jamfURL.isEmpty
        log.add("Welcome to \(Dialogs.appName) \(version). "
                + (hasURL ? "Type in the search field to find devices and build your list."
                          : "Open Settings (⌘,) to connect to Jamf Pro."))
        if !hasURL && opensSettingsWhenUnconfigured {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                openSettings()
            }
        }
    }

    // MARK: Settings & client

    var tlsPolicy: TLSPolicy {
        TLSPolicy(verify: settings.prefs.sslVerify, caBundlePath: settings.prefs.sslCABundle)
    }

    func rebuildClient() {
        let prefs = settings.prefs
        guard !prefs.jamfURL.isEmpty else { client = nil; return }
        let (a, b) = settings.credentials(for: prefs.authMethod)
        client = JamfClient(baseURL: prefs.jamfURL, authMethod: prefs.authMethod,
                            credentialA: a, credentialB: b, tls: tlsPolicy)
    }

    func settingsSaved() {
        rebuildClient()
        log.add("Settings saved.")
    }

    /// Settings live in our own window rather than a SwiftUI `Settings` scene:
    /// newer macOS versions only open that scene from a `SettingsLink`, which
    /// can't be used from model code (first launch, "add credentials first" prompts).
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.show(model: self)
    }

    func persist() {
        if !settings.save() {
            log.add("Could not save settings: \(settings.lastSaveError ?? "unknown error")")
        }
    }

    // MARK: Helpers shared by the action files

    func describe(_ error: Error) -> String {
        if let service = error as? ServiceError { return service.message }
        if error is CancellationError { return "Cancelled." }
        return "Unexpected error: \(error.localizedDescription)"
    }

    /// Runs `work` with the busy indicator showing, returning its outcome.
    func busyScope<T>(_ message: String, _ work: () async throws -> T) async -> Result<T, Error> {
        log.beginBusy(message)
        defer { log.endBusy() }
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// A short pause so a dismissed sheet has finished leaving before the
    /// next one is shown.
    func sheetSettle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func requireClient() async -> JamfClient? {
        if let client { return client }
        await Dialogs.info("Add your Jamf Pro URL and credentials in Settings first.")
        openSettings()
        return nil
    }

    // MARK: Working lists

    func entries(for type: DeviceType) -> [DeviceEntry] { settings.prefs.deviceList(for: type) }
    var entries: [DeviceEntry] { entries(for: deviceType) }
    var visibleColumns: [ColumnField] { settings.prefs.visibleColumns }

    /// Selected entries, in list order.
    var selectedEntries: [DeviceEntry] { entries.filter { selection.contains($0.id) } }

    func mutateList(_ type: DeviceType, _ body: (inout [DeviceEntry]) -> Void) {
        var list = settings.prefs.deviceList(for: type)
        body(&list)
        settings.prefs.setDeviceList(list, for: type)
        persist()
    }

    func updateListEntry(type: DeviceType, id: String, fields: [String: String]) {
        mutateList(type) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].fields.merge(fields) { $1 }
        }
    }

    /// ⌘N and the + button: jump to the search field.
    func openAddDialog() {
        guard showingDevices else {
            tab = lastDeviceType == .mobile ? .mobile : .computers
            DispatchQueue.main.async { self.search.focus() }   // after the tab's field exists
            return
        }
        search.focus()
    }

    func selectAndReveal(_ id: String, in type: DeviceType) {
        setSelection([id], for: type)
        reveals[type] = RevealRequest(id: id)
    }

    func addEntries(_ new: [DeviceEntry], type: DeviceType) {
        mutateList(type) { list in
            for var entry in new where !list.contains(where: { $0.id == entry.id }) {
                for field in ColumnField.allCases where entry.fields[field.rawValue] == nil {
                    entry.fields[field.rawValue] = ""
                }
                list.append(entry)
            }
        }
        log.add("Added to list: " + new.map(\.displayName).joined(separator: ", "))
        // Fill in model / MAC / IP right away.
        Task { await fetchEntryDetails(type: type, ids: new.map(\.id)) }
    }

    /// Fetch full records for the given ids and fill in every list field.
    func fetchEntryDetails(type: DeviceType, ids: [String]) async {
        guard let client else { return }
        var updated: [DeviceEntry] = []
        var missing = 0
        for id in ids {
            do {
                let record = try await client.record(for: type, id: id)
                updated.append(Templates.entry(from: record, type: type, deviceID: id))
            } catch let error as ServiceError where error.isNotFound {
                missing += 1
            } catch {
                log.add("Could not fetch device details: \(describe(error))")
                return
            }
        }
        for entry in updated { updateListEntry(type: type, id: entry.id, fields: entry.fields) }
        if missing > 0 { log.add("\(missing) device(s) not found while fetching details.") }
    }

    func removeSelected() async {
        let chosen = selectedEntries
        guard !chosen.isEmpty else {
            await Dialogs.info("Select one or more devices to remove from the list.")
            return
        }
        let ids = Set(chosen.map(\.id))
        mutateList(deviceType) { $0.removeAll { ids.contains($0.id) } }
        selection = []
        log.add("Removed from list: " + chosen.map(\.displayName).joined(separator: ", "))
    }

    /// Re-fetch every field for every device in the current list.
    func refreshList() async {
        guard let client = await requireClient() else { return }
        let type = deviceType
        let snapshot = settings.prefs.deviceList(for: type)
        guard !snapshot.isEmpty else {
            log.add("Nothing to refresh — the list is empty.")
            return
        }
        log.beginBusy("Refreshing \(snapshot.count) device(s)…")
        var updated: [String: DeviceEntry] = [:]
        var missing: [DeviceEntry] = []
        var failure: String?
        for (index, entry) in snapshot.enumerated() {
            log.status = "Refreshing \(index + 1) of \(snapshot.count)…"
            do {
                let record = try await client.record(for: type, id: entry.id)
                updated[entry.id] = Templates.entry(from: record, type: type, deviceID: entry.id)
            } catch let error as ServiceError where error.isNotFound {
                missing.append(entry)
            } catch {
                failure = describe(error)
                break
            }
        }
        log.endBusy()
        if let failure {
            log.add("Refresh failed: \(failure)")
            await Dialogs.error(failure)
            return
        }
        // Merge into the *current* list so devices added during the refresh survive.
        let missingIDs = Set(missing.map(\.id))
        mutateList(type) { list in
            list = list.compactMap { entry in
                missingIDs.contains(entry.id) ? nil : (updated[entry.id] ?? entry)
            }
        }
        var message = "Refreshed \(updated.count) device(s)."
        if !missing.isEmpty {
            message += " Dropped \(missing.count) no longer in Jamf Pro: "
                + missing.map { $0.value(.name).isEmpty ? $0.id : $0.value(.name) }.joined(separator: ", ")
        }
        log.add(message)
    }

    /// Move the selected row(s) up (-1) or down (+1) in the saved order.
    func moveSelected(_ direction: Int) {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        var list = entries
        let indices = list.indices.filter { chosen.contains(list[$0].id) }
        guard let first = indices.first, let last = indices.last else { return }
        if direction < 0 && first == 0 { return }
        if direction > 0 && last == list.count - 1 { return }
        for index in (direction < 0 ? indices : indices.reversed()) {
            list.swapAt(index, index + direction)
        }
        settings.prefs.setDeviceList(list, for: deviceType)
        persist()
        sorts[deviceType] = nil   // a manual order overrides any column sort
        if let target = list.first(where: { chosen.contains($0.id) }) { reveals[deviceType] = RevealRequest(id: target.id) }
    }

    /// Sort a list by a column (the visible one unless `type` is given).
    /// The new order is saved, like manual moves.
    func sortBy(_ field: ColumnField, ascending: Bool, type: DeviceType? = nil) {
        let type = type ?? deviceType
        var list = entries(for: type)
        guard !list.isEmpty else { return }
        sorts[type] = SortState(field: field, ascending: ascending)

        func key(_ entry: DeviceEntry) -> (rank: Int, octets: [Int], text: String) {
            let value = entry.value(field)
            if value.isEmpty { return (2, [], "") }
            if field == .ip {
                let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
                if parts.count == 4, !parts.contains(where: { $0 == nil }) { return (0, parts.compactMap { $0 }, value) }
                return (1, [], value)
            }
            return (0, [], value)
        }
        func less(_ a: (rank: Int, octets: [Int], text: String), _ b: (rank: Int, octets: [Int], text: String)) -> Bool {
            if a.rank != b.rank { return a.rank < b.rank }
            if a.rank == 0 && !a.octets.isEmpty { return a.octets.lexicographicallyPrecedes(b.octets) }
            return a.text.localizedStandardCompare(b.text) == .orderedAscending
        }
        list.sort { lhs, rhs in
            let a = key(lhs), b = key(rhs)
            if a.rank == 2 || b.rank == 2 { return a.rank < b.rank }   // blanks stay last either way
            return ascending ? less(a, b) : less(b, a)
        }
        settings.prefs.setDeviceList(list, for: type)
        persist()
    }

    // MARK: Columns

    func setColumns(_ columns: [ColumnField]) {
        let valid = columns.isEmpty ? ColumnField.defaults : columns
        guard valid.map(\.rawValue) != settings.prefs.listColumns else { return }
        settings.prefs.listColumns = valid.map(\.rawValue)
        sorts = [:]   // columns are shared by both tabs
        persist()
    }

    func resetColumns() {
        setColumns(ColumnField.defaults)
        log.add("Columns reset to defaults.")
    }

    func toggleColumn(_ field: ColumnField) {
        var columns = visibleColumns
        if let index = columns.firstIndex(of: field) {
            guard columns.count > 1 else {
                log.status = "At least one column must stay visible."
                return
            }
            columns.remove(at: index)
        } else {
            columns.append(field)
        }
        setColumns(columns)
    }

    func showArrangeColumns() {
        Task {
            let result: [ColumnField]? = await Sheets.present(resizable: true) { done in
                ColumnsSheet(shown: visibleColumns, done: done)
            }
            if let result { setColumns(result) }
        }
    }

    // MARK: Copying

    func copyText(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Count lines via `components`: "\r\n" (as in CSV) is a single Character in
        // Swift, so `contains("\n")` / `split(separator: "\n")` would miss it.
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        log.add(lines.count > 1 ? "Copied \(what) (\(lines.count) lines)."
                                : "Copied \(what): \(text)")
    }

    /// Selected row(s) as tab-separated text (⌘C).
    func copyRows() {
        let chosen = selectedEntries
        guard !chosen.isEmpty else { return }
        let columns = visibleColumns
        let text = chosen.map { entry in columns.map { entry.value($0) }.joined(separator: "\t") }
            .joined(separator: "\n")
        copyText(text, what: chosen.count == 1 ? "row" : "rows")
    }

    func copyRowsAsCSV() {
        let chosen = selectedEntries
        guard !chosen.isEmpty else { return }
        copyText(ListExport.csv(entries: chosen, columns: visibleColumns),
                 what: chosen.count == 1 ? "row as CSV" : "\(chosen.count) rows as CSV")
    }

    func copyListAsCSV() {
        let all = entries
        guard !all.isEmpty else {
            log.status = "The list is empty — nothing to copy."
            return
        }
        copyText(ListExport.csv(entries: all, columns: visibleColumns), what: "list as CSV (\(all.count) rows)")
    }

    func copyLog() {
        guard !log.lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text, forType: .string)
        log.status = "Copied log (\(log.lines.count) lines)."
    }

    // MARK: Export

    func exportList() async {
        let all = entries
        guard !all.isEmpty else {
            await Dialogs.info("The list is empty — nothing to export.")
            return
        }
        let type = deviceType
        let columns = visibleColumns
        let panel = NSSavePanel()
        panel.title = "Export list"
        panel.canCreateDirectories = true
        let baseName = "Jamf \(type.exportName) \(Self.dayStamp())"
        let accessory = ExportFormatAccessory(panel: panel, baseName: baseName)
        panel.accessoryView = accessory.view

        let response: NSApplication.ModalResponse
        if let window = Dialogs.anchor {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }

        do {
            if url.pathExtension.lowercased() == "xlsx" {
                try ListExport.xlsxData(entries: all, columns: columns).write(to: url, options: .atomic)
            } else {
                try ListExport.csvFileData(entries: all, columns: columns).write(to: url, options: .atomic)
            }
        } catch {
            await Dialogs.error("Could not export the list:\n\(error.localizedDescription)")
            return
        }
        log.add("Exported \(all.count) \(type.exportName.lowercased()) to \(url.lastPathComponent).")
        if await Dialogs.confirm("Export complete. Reveal the file in Finder?", yes: "Reveal", no: "Done") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

/// A "Format" pop-up for the save panel, switching between CSV and Excel.
@MainActor
final class ExportFormatAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
    private let popup = NSPopUpButton(frame: NSRect(x: 80, y: 4, width: 200, height: 26), pullsDown: false)
    private weak var panel: NSSavePanel?
    private let baseName: String
    private let formats: [(title: String, ext: String, type: UTType)] = [
        ("CSV file", "csv", .commaSeparatedText),
        ("Excel workbook", "xlsx", UTType(filenameExtension: "xlsx") ?? .data),
    ]

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        super.init()
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 9, width: 56, height: 17)
        label.alignment = .right
        view.addSubview(label)
        popup.addItems(withTitles: formats.map(\.title))
        popup.target = self
        popup.action = #selector(formatChanged)
        view.addSubview(popup)
        apply()
    }

    @objc private func formatChanged() { apply() }

    private func apply() {
        guard let panel else { return }
        let format = formats[max(0, popup.indexOfSelectedItem)]
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(baseName).\(format.ext)"
    }
}

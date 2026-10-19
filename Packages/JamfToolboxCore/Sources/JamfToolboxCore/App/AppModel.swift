import Combine
import Foundation

/// A device the user has picked, resolved from the working list.
public struct DeviceRef: Hashable {
    public let id: String
    public let name: String
    public let type: DeviceType

    public init(id: String, name: String, type: DeviceType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// The main window's tabs (the iOS app's views).
public enum MainTab: Hashable {
    case computers
    case mobile
    case audits

    /// The device list this tab shows, or nil for non-device tabs.
    public var deviceType: DeviceType? {
        switch self {
        case .computers: return .computer
        case .mobile: return .mobile
        case .audits: return nil
        }
    }
}

public struct SortState: Equatable {
    public var field: ColumnField
    public var ascending: Bool

    public init(field: ColumnField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

/// Asks the table to scroll a row into view (after a manual move, say).
public struct RevealRequest: Equatable {
    public let id: String
    public let token = UUID()

    public init(id: String) { self.id = id }
}

/// The app's single source of truth: settings, working lists, selection and
/// every user-facing action. Split across files by concern; this file holds
/// state, list management, columns and copying. Prompts and windows go through
/// `ui`, which each app implements.
@MainActor
public final class AppModel: ObservableObject {
    public let settings: SettingsStore
    public let log = ActivityLog()
    public let ui: AppPresenter
    /// One search field per device tab.
    public let searches: [DeviceType: DeviceSearch] = [
        .computer: DeviceSearch(type: .computer),
        .mobile: DeviceSearch(type: .mobile),
    ]

    @Published public var tab: MainTab = .computers {
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
    public var deviceType: DeviceType {
        get { tab.deviceType ?? lastDeviceType }
        set { tab = newValue == .mobile ? .mobile : .computers }
    }

    /// False on the Audits tab, where device commands are disabled.
    public var showingDevices: Bool { tab.deviceType != nil }

    public let audits: AuditCenter

    public func selection(for type: DeviceType) -> Set<String> { selections[type] ?? [] }

    public func setSelection(_ ids: Set<String>, for type: DeviceType) {
        if selection(for: type) != ids { selections[type] = ids }
    }

    public func sort(for type: DeviceType) -> SortState? { sorts[type] }
    public func reveal(for type: DeviceType) -> RevealRequest? { reveals[type] }
    public func search(for type: DeviceType) -> DeviceSearch { searches[type]! }

    /// Shorthands for the visible tab.
    public var selection: Set<String> {
        get { selection(for: deviceType) }
        set { setSelection(newValue, for: deviceType) }
    }
    public var sort: SortState? { sorts[deviceType] }
    public var search: DeviceSearch { search(for: deviceType) }

    public private(set) var client: JamfClient?
    /// A Meraki key is set, so the network features (Wi-Fi access point,
    /// Network Info) are shown. Without one they stay hidden.
    @Published public private(set) var networkLookupsEnabled = false
    var apNames: [String: [String: String]] = [:]   // Meraki network id → AP MAC → name
    private var settingsObserver: AnyCancellable?
    private var didStart = false

    public static var version: String { AppInfo.version }
    public var version: String { Self.version }

    /// Off for previews, which shouldn't pop up the setup guide.
    public var opensSettingsWhenUnconfigured = true

    public init(settings: SettingsStore? = nil, presenter: AppPresenter) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        ui = presenter
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
    public func start() {
        guard !didStart else { return }
        didStart = true
        let hasURL = !settings.prefs.jamfURL.isEmpty
        log.add("Welcome to \(AppInfo.name) \(version). "
                + (hasURL ? "Type in the search field to find devices and build your list."
                          : "\(ui.openSettingsHint) to connect to Jamf Pro."))
        if opensSettingsWhenUnconfigured && setupStatus.needsGuide {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await showSetupGuide()
            }
        }
    }

    // MARK: Settings & client

    public var tlsPolicy: TLSPolicy {
        TLSPolicy(verify: settings.prefs.sslVerify, caBundlePath: settings.prefs.sslCABundle)
    }

    public func rebuildClient() {
        networkLookupsEnabled = !settings.secret("meraki_api_key").isEmpty
        let prefs = settings.prefs
        guard !prefs.jamfURL.isEmpty else { client = nil; return }
        let (a, b) = settings.credentials(for: prefs.authMethod)
        let client = JamfClient(baseURL: prefs.jamfURL, authMethod: prefs.authMethod,
                                credentialA: a, credentialB: b, tls: tlsPolicy)
        self.client = client
        warmUp()
    }

    /// Signs in to Jamf Pro in the background (if the token is missing or
    /// expired), so the next request starts right away.
    public func warmUp() {
        guard let client else { return }
        Task { await client.warmUp() }
    }

    public func settingsSaved() {
        rebuildClient()
        log.add("Settings saved.")
    }

    public func openSettings() { ui.openSettings() }

    public func persist() {
        if !settings.save() {
            log.add("Could not save settings: \(settings.lastSaveError ?? "unknown error")")
        }
    }

    // MARK: Helpers shared by the action files

    public func describe(_ error: Error) -> String {
        if let service = error as? ServiceError { return service.message }
        if error is CancellationError { return "Cancelled." }
        return "Unexpected error: \(error.localizedDescription)"
    }

    /// Runs `work` with the busy indicator showing, returning its outcome.
    public func busyScope<T>(_ message: String, _ work: () async throws -> T) async -> Result<T, Error> {
        log.beginBusy(message)
        defer { log.endBusy() }
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// A short pause so a dismissed sheet has finished leaving before the
    /// next one is shown.
    public func sheetSettle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    public func requireClient() async -> JamfClient? {
        if let client, setupStatus.jamfReady { return client }
        await showSetupGuide()
        return nil
    }

    // MARK: Working lists

    public func entries(for type: DeviceType) -> [DeviceEntry] { settings.prefs.deviceList(for: type) }
    public var entries: [DeviceEntry] { entries(for: deviceType) }
    public var visibleColumns: [ColumnField] { settings.prefs.visibleColumns }

    /// Selected entries, in list order.
    public var selectedEntries: [DeviceEntry] { entries.filter { selection.contains($0.id) } }

    public func mutateList(_ type: DeviceType, _ body: (inout [DeviceEntry]) -> Void) {
        var list = settings.prefs.deviceList(for: type)
        body(&list)
        settings.prefs.setDeviceList(list, for: type)
        persist()
    }

    public func updateListEntry(type: DeviceType, id: String, fields: [String: String]) {
        mutateList(type) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].fields.merge(fields) { $1 }
        }
    }

    /// ⌘N and the + button: jump to the search field.
    public func openAddDialog() {
        guard showingDevices else {
            tab = lastDeviceType == .mobile ? .mobile : .computers
            DispatchQueue.main.async { self.search.focus() }   // after the tab's field exists
            return
        }
        search.focus()
    }

    public func selectAndReveal(_ id: String, in type: DeviceType) {
        setSelection([id], for: type)
        reveals[type] = RevealRequest(id: id)
    }

    public func addEntries(_ new: [DeviceEntry], type: DeviceType) {
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
    public func fetchEntryDetails(type: DeviceType, ids: [String]) async {
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

    public func removeSelected() async {
        let chosen = selectedEntries
        guard !chosen.isEmpty else {
            await ui.info("Select one or more devices to remove from the list.")
            return
        }
        remove(Set(chosen.map(\.id)), from: deviceType)
    }

    /// Take devices off a working list (nothing changes in Jamf Pro).
    public func remove(_ ids: Set<String>, from type: DeviceType) {
        let chosen = entries(for: type).filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        mutateList(type) { $0.removeAll { ids.contains($0.id) } }
        setSelection(selection(for: type).subtracting(ids), for: type)
        log.add("Removed from list: " + chosen.map(\.displayName).joined(separator: ", "))
    }

    /// Re-fetch every field for every device in the current list.
    public func refreshList() async {
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
            await ui.error(failure)
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
    public func moveSelected(_ direction: Int) {
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
    public func sortBy(_ field: ColumnField, ascending: Bool, type: DeviceType? = nil) {
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

    public func setColumns(_ columns: [ColumnField]) {
        let valid = columns.isEmpty ? ColumnField.defaults : columns
        guard valid.map(\.rawValue) != settings.prefs.listColumns else { return }
        settings.prefs.listColumns = valid.map(\.rawValue)
        sorts = [:]   // columns are shared by both tabs
        persist()
    }

    public func resetColumns() {
        setColumns(ColumnField.defaults)
        log.add("Columns reset to defaults.")
    }

    public func toggleColumn(_ field: ColumnField) {
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

    // MARK: Copying

    public func copyText(_ text: String, what: String) {
        ui.copyToClipboard(text)
        // Count lines via `components`: "\r\n" (as in CSV) is a single Character in
        // Swift, so `contains("\n")` / `split(separator: "\n")` would miss it.
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        log.add(lines.count > 1 ? "Copied \(what) (\(lines.count) lines)."
                                : "Copied \(what): \(text)")
    }

    /// Selected row(s) as tab-separated text (⌘C).
    public func copyRows() {
        let chosen = selectedEntries
        guard !chosen.isEmpty else { return }
        let columns = visibleColumns
        let text = chosen.map { entry in columns.map { entry.value($0) }.joined(separator: "\t") }
            .joined(separator: "\n")
        copyText(text, what: chosen.count == 1 ? "row" : "rows")
    }

    public func copyRowsAsCSV() {
        let chosen = selectedEntries
        guard !chosen.isEmpty else { return }
        copyText(ListExport.csv(entries: chosen, columns: visibleColumns),
                 what: chosen.count == 1 ? "row as CSV" : "\(chosen.count) rows as CSV")
    }

    public func copyListAsCSV() {
        let all = entries
        guard !all.isEmpty else {
            log.status = "The list is empty — nothing to copy."
            return
        }
        copyText(ListExport.csv(entries: all, columns: visibleColumns), what: "list as CSV (\(all.count) rows)")
    }

    public func copyLog() {
        guard !log.lines.isEmpty else { return }
        ui.copyToClipboard(log.text)
        log.status = "Copied log (\(log.lines.count) lines)."
    }

    // MARK: Export

    /// The file name an exported list is offered under, without extension.
    public func exportBaseName(_ type: DeviceType) -> String {
        "Jamf \(type.exportName) \(Self.dayStamp())"
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

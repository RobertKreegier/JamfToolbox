import Foundation

/// Type-ahead search over Jamf Pro for the main window's search field.
/// Results appear in a dropdown; choosing one adds it to the working list.
///
/// Separate from `AppModel` so typing redraws only the search field and its
/// dropdown, not the device table.
@MainActor
public final class DeviceSearch: ObservableObject {
    @Published public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published public private(set) var results: [DeviceEntry] = []
    @Published public var highlighted = 0
    @Published public private(set) var isSearching = false
    @Published public private(set) var message: String?
    @Published public private(set) var isOpen = false
    /// Bumped to ask the field to take keyboard focus.
    @Published public private(set) var focusToken = 0

    weak var model: AppModel?
    /// The list this field searches and adds to.
    public let type: DeviceType

    /// Whether the field takes focus again after a device is chosen, so several
    /// can be added in a row. The iPhone app turns this off to show the device.
    public var keepsFocusAfterChoosing = true

    public init(type: DeviceType) { self.type = type }

    private static let minimumCharacters = 2
    private static let maximumResults = 12
    private var task: Task<Void, Never>?

    public func focus() { focusToken += 1 }

    /// Closes the dropdown and clears the field.
    public func reset() {
        task?.cancel()
        query = ""
        results = []
        message = nil
        isSearching = false
        isOpen = false
    }

    /// Closes the dropdown but keeps what was typed.
    public func dismiss() { if isOpen { isOpen = false } }

    public func isInList(_ entry: DeviceEntry) -> Bool {
        model?.entries(for: type).contains { $0.id == entry.id } ?? false
    }

    public func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), results.count - 1)
    }

    // MARK: Searching

    private func scheduleSearch() {
        task?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= Self.minimumCharacters else {
            results = []
            message = nil
            isSearching = false
            isOpen = false
            return
        }
        isOpen = true
        isSearching = true
        task = Task { [weak self] in
            // Wait for a pause in typing so each keystroke doesn't hit the server.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.search(term)
        }
    }

    private func search(_ term: String) async {
        guard let model else { return }
        guard let client = model.client else {
            results = []
            isSearching = false
            message = "Add your Jamf Pro URL and credentials in Settings first."
            return
        }
        do {
            let records = type == .computer
                ? try await client.searchComputers(term)
                : try await client.searchMobileDevices(term)
            guard !Task.isCancelled else { return }   // a newer search superseded this one
            let entries = records.prefix(Self.maximumResults).compactMap { record -> DeviceEntry? in
                let id = record["id"]?.text ?? ""
                guard !id.isEmpty else { return nil }
                return DeviceEntry(id: id, fields: [
                    "name": record["name"]?.text ?? "",
                    "serial": record["serial_number"]?.text ?? "",
                    "username": record["username"]?.text ?? "",
                    "wifi_mac": record["wifi_mac_address"]?.text ?? "",
                    "ip": "",
                    "model": record["model"]?.text ?? "",
                ])
            }
            results = Array(entries)
            highlighted = results.firstIndex { !isInList($0) } ?? 0
            message = results.isEmpty ? "No matches for “\(term)”." : nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            message = model.describe(error)
        }
        isSearching = false
    }

    // MARK: Choosing

    public func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    /// Add the device to the list, or just select it if it's already there.
    public func choose(_ entry: DeviceEntry) {
        guard let model else { return }
        if !isInList(entry) { model.addEntries([entry], type: type) }
        model.selectAndReveal(entry.id, in: type)
        reset()
        if keepsFocusAfterChoosing { focus() }   // stay in the field so several devices can be added in a row
    }

    #if DEBUG
    /// Shows canned results without searching (previews only).
    public func showPreviewResults(_ entries: [DeviceEntry], query: String) {
        self.query = query
        task?.cancel()
        results = entries
        highlighted = 0
        message = nil
        isSearching = false
        isOpen = true
    }
    #endif
}

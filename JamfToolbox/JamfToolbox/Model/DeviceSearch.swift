import Foundation

/// Type-ahead search over Jamf Pro for the main window's search field.
/// Results appear in a dropdown; choosing one adds it to the working list.
///
/// Separate from `AppModel` so typing redraws only the search field and its
/// dropdown, not the device table.
@MainActor
final class DeviceSearch: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var results: [DeviceEntry] = []
    @Published var highlighted = 0
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    @Published private(set) var isOpen = false
    /// Bumped to ask the field to take keyboard focus.
    @Published private(set) var focusToken = 0

    weak var model: AppModel?

    private static let minimumCharacters = 2
    private static let maximumResults = 12
    private var task: Task<Void, Never>?

    func focus() { focusToken += 1 }

    /// Closes the dropdown and clears the field.
    func reset() {
        task?.cancel()
        query = ""
        results = []
        message = nil
        isSearching = false
        isOpen = false
    }

    /// Closes the dropdown but keeps what was typed.
    func dismiss() { isOpen = false }

    func isInList(_ entry: DeviceEntry) -> Bool {
        model?.entries.contains { $0.id == entry.id } ?? false
    }

    func moveHighlight(_ delta: Int) {
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
        let type = model.deviceType
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

    func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    /// Add the device to the list, or just select it if it's already there.
    func choose(_ entry: DeviceEntry) {
        guard let model else { return }
        if !isInList(entry) { model.addEntries([entry], type: model.deviceType) }
        model.selectAndReveal(entry.id)
        reset()
        focus()   // stay in the field so several devices can be added in a row
    }
}

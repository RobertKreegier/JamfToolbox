import Foundation

public enum AppInfo {
    public static let name = "Jamf Toolbox"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

public enum AlertStyle {
    case informational
    case warning
    case critical
}

/// Everything the shared model needs from the app's UI: alerts, sheets, info
/// views and a few system services. Each app implements it with its own
/// controls (AppKit sheets on the Mac, SwiftUI sheets and dialogs on iOS), so
/// the model's multi-step actions can simply `await` each prompt in turn.
@MainActor
public protocol AppPresenter: AnyObject {
    /// Shows an alert and returns the index of the pressed button. Buttons are
    /// listed default-first.
    func alert(_ message: String, title: String, style: AlertStyle, buttons: [String]) async -> Int

    /// Review and edit values before sending; returns trimmed values keyed by
    /// field label, or nil when cancelled.
    func preview(title: String, intro: String, fields: [PreviewField], confirm: String,
                 presets: [PreviewPreset], presetLabel: String) async -> [String: String]?

    /// Pick one of several saved presets; nil when cancelled.
    func choosePreset(title: String, intro: String, options: [(name: String, text: String)],
                      confirmLabel: String) async -> Int?

    /// A list of what a bulk action will do, to confirm or cancel.
    func confirmBulk(title: String, intro: String, lines: [String], confirmLabel: String,
                     warning: String) async -> Bool

    /// Shows progress for a bulk operation; call the returned closure to dismiss it.
    func showProgress(title: String, progress: BulkProgress) -> () -> Void

    /// A device's full Jamf Pro record.
    func showRecord(title: String, record: JSONValue)

    /// Where Meraki last saw a device.
    func showMerakiInfo(_ info: MerakiInfo)

    func pickMerakiOrg(_ orgs: [NamedID], savedID: String) async -> NamedID?

    func pickMerakiNetwork(_ meraki: MerakiClient, savedOrgID: String,
                           savedNetworkID: String) async -> MerakiNetworkChoice?

    func openSettings()
    func openURL(_ url: URL)
    func copyToClipboard(_ text: String)

    /// How the welcome message tells the user to reach Settings.
    var openSettingsHint: String { get }
}

public extension AppPresenter {
    var openSettingsHint: String { "Open Settings" }

    @discardableResult
    func show(_ message: String, title: String = AppInfo.name, style: AlertStyle = .informational,
              buttons: [String] = ["OK"]) async -> Int {
        await alert(message, title: title, style: style, buttons: buttons)
    }

    func info(_ message: String) async { await show(message) }
    func warning(_ message: String) async { await show(message, style: .warning) }
    func error(_ message: String) async { await show(message, style: .critical) }

    /// Yes/No question; true for the first button.
    func confirm(_ message: String, yes: String = "Yes", no: String = "No") async -> Bool {
        await show(message, buttons: [yes, no]) == 0
    }

    /// Three-way choice. Returns 0 or 1 for the first two buttons, nil for Cancel.
    func choose(_ message: String, first: String, second: String) async -> Int? {
        let index = await show(message, buttons: [first, second, "Cancel"])
        return index <= 1 ? index : nil
    }
}

// MARK: - Values passed to the presenter

public struct PreviewField: Identifiable {
    public let id = UUID()
    public let label: String
    public var value: String
    public var multiline = false

    public init(label: String, value: String, multiline: Bool = false) {
        self.label = label
        self.value = value
        self.multiline = multiline
    }
}

/// A named set of field values the user can switch to (a saved message preset).
public struct PreviewPreset {
    public let name: String
    /// Field label → value, already rendered for the device.
    public let values: [String: String]

    public init(name: String, values: [String: String]) {
        self.name = name
        self.values = values
    }
}

/// Progress for a bulk operation. The work runs in an async loop; the UI only
/// displays it and lets the user ask it to stop between devices.
@MainActor
public final class BulkProgress: ObservableObject {
    public let total: Int
    @Published public private(set) var index = 0
    @Published public private(set) var text = "Starting…"
    @Published public private(set) var cancelled = false

    public init(total: Int) { self.total = total }

    public func step(_ index: Int, _ text: String) {
        self.index = index
        self.text = text
    }

    public func cancel() {
        cancelled = true
        text = "Finishing the current device, then stopping…"
    }
}

public struct NamedID: Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public init?(json: JSONValue) {
        let id = json["id"]?.text ?? ""
        guard !id.isEmpty else { return nil }
        let name = json["name"]?.text ?? ""
        self.init(id: id, name: name.isEmpty ? id : name)
    }
}

public struct MerakiNetworkChoice {
    public let org: NamedID
    public let network: NamedID

    public init(org: NamedID, network: NamedID) {
        self.org = org
        self.network = network
    }
}

/// A Meraki client lookup to show the user.
public struct MerakiInfo {
    public let deviceName: String
    public let mac: String
    public let networkName: String
    /// Meraki's client record.
    public let client: JSONValue
    /// How many networks the client was seen on (org-wide search), or nil
    /// when one network was searched directly.
    public let networksSeen: Int?
    /// Search a different network for the same device.
    public let changeNetwork: () -> Void

    public init(deviceName: String, mac: String, networkName: String, client: JSONValue,
                networksSeen: Int?, changeNetwork: @escaping () -> Void) {
        self.deviceName = deviceName
        self.mac = mac
        self.networkName = networkName
        self.client = client
        self.networksSeen = networksSeen
        self.changeNetwork = changeNetwork
    }
}

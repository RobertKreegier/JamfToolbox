import Foundation

// Bulk wipe and bulk delete through the shared app model, against mock_jamf.py,
// with a scripted presenter standing in for the dialogs. Mock behaviour:
//   erase:  101, 104 succeed; 102 not found; 103 permission denied
//   delete: 103 permission denied; others succeed
var fails = 0
func ck(_ c: Bool, _ m: String) { print(c ? "  ok   \(m)" : "  FAIL \(m)"); if !c { fails += 1 } }

@MainActor final class ScriptedPresenter: AppPresenter {
    var destructiveAnswers: [[String: String]?] = []
    var destructiveCalls: [(title: String, lines: [String], options: [String], confirm: String, typed: String)] = []
    var results: [(title: String, summary: String, results: [BulkResult])] = []
    var alerts: [String] = []

    func alert(_ message: String, title: String, style: AlertStyle, buttons: [String]) async -> Int {
        alerts.append(message); return 0
    }
    func preview(title: String, intro: String, fields: [PreviewField], confirm: String, presets: [PreviewPreset],
                 presetLabel: String, destructive: Bool) async -> [String: String]? { nil }
    func choosePreset(title: String, intro: String, options: [(name: String, text: String)],
                      confirmLabel: String) async -> Int? { nil }
    func confirmBulk(title: String, intro: String, lines: [String], confirmLabel: String,
                     warning: String) async -> Bool { false }
    func confirmDestructiveBulk(title: String, intro: String, lines: [String], options: [PreviewField],
                                confirmLabel: String, warning: String,
                                typedConfirmation: String) async -> [String: String]? {
        destructiveCalls.append((title, lines, options.map(\.label), confirmLabel, typedConfirmation))
        return destructiveAnswers.isEmpty ? nil : destructiveAnswers.removeFirst()
    }
    func showBulkResults(title: String, summary: String, results: [BulkResult]) async {
        self.results.append((title, summary, results))
    }
    func showProgress(title: String, progress: BulkProgress) -> () -> Void { {} }
    func showRecord(title: String, record: JSONValue) {}
    func showMerakiInfo(_ info: MerakiInfo) {}
    func pickMerakiOrg(_ orgs: [NamedID], savedID: String) async -> NamedID? { nil }
    func pickMerakiNetwork(_ meraki: MerakiClient, savedOrgID: String, savedNetworkID: String) async -> MerakiNetworkChoice? { nil }
    func setupGuide(_ status: SetupStatus) async -> SetupGuideChoice { .later }
    func openSettings() {}
    func openURL(_ url: URL) {}
    func copyToClipboard(_ text: String) {}
}

@main struct BulkChecks { @MainActor static func main() async {
    let certDir = CommandLine.arguments[1]
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bulkchecks-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let devices = (101...104).map { ["id": "\($0)", "name": "iPad-\($0)", "serial": "SER\($0)"] }
    let settingsJSON: [String: Any] = ["jamf_url": "https://localhost:18446", "auth_method": "basic",
                                       "ssl_verify": true, "ssl_ca_bundle": certDir + "/cert.pem",
                                       "device_list_mobile": devices, "device_list_computer": []]
    try! JSONSerialization.data(withJSONObject: settingsJSON).write(to: dir.appendingPathComponent("settings.json"))
    let settings = SettingsStore(directory: dir, inMemorySecrets: ["username": "u", "password": "p"])
    let ui = ScriptedPresenter()
    let model = AppModel(settings: settings, presenter: ui)
    model.tab = .mobile
    let all: Set<String> = ["101", "102", "103", "104"]

    // Availability: Wipe and Delete with several mobile devices; others stay single-device.
    model.setSelection(all, for: .mobile)
    ck(model.canPerform(.wipe) && model.canPerform(.delete) && !model.canPerform(.restart),
       "several mobile devices: Wipe and Delete available, Restart not")
    ck(AdvancedCommand.wipe.supportsBulk(for: .mobile) && !AdvancedCommand.wipe.supportsBulk(for: .computer)
       && AdvancedCommand.delete.supportsBulk(for: .computer), "bulk wipe is mobile-only; bulk delete for both")
    ck(AdvancedCommand.wipe.menuTitle(count: 4) == "Wipe 4 Devices" && AdvancedCommand.wipe.menuTitle(count: 1) == "Wipe Device",
       "menu titles show the count")

    // Other checks share the mock server, so count only this check's requests.
    let earlier = (try? await model.client!.get("/__erases"))?.arrayValue?.count ?? 0

    // Cancelled: nothing sent.
    ui.destructiveAnswers = [nil]
    await model.bulkWipe()
    let call = ui.destructiveCalls.last
    ck(call?.typed == "4" && call?.confirm == "Wipe 4 Devices" && call?.lines.first == "iPad-101  ·  SER101"
       && call?.options == ["Return to Service after the erase"], "wipe confirm: typed count 4, review list, Return to Service option")
    var erases = Array(((try? await model.client!.get("/__erases"))?.arrayValue ?? []).dropFirst(earlier))
    ck(erases.isEmpty && ui.results.isEmpty, "cancelled wipe sends nothing")

    // Confirmed with Return to Service: stops after permission denied.
    ui.destructiveAnswers = [["Return to Service after the erase": "true"]]
    await model.bulkWipe()
    erases = Array(((try? await model.client!.get("/__erases"))?.arrayValue ?? []).dropFirst(earlier))
    let wipe = ui.results.last
    let outcomes = wipe?.results.map { "\($0.device):\($0.outcome)" } ?? []
    ck(outcomes == ["iPad-101:succeeded", "iPad-102:failed", "iPad-103:failed", "iPad-104:notSent"],
       "wipe results in order, 104 not sent after permission denied: \(outcomes)")
    ck(erases.count == 1 && erases.first?["path"]?.text == "/api/v2/mobile-devices/101/erase",
       "only 101 actually wiped (\(erases.count) recorded)")
    if case .bool(true)? = erases.first?["body"]?["returnToService"] { ck(true, "Return to Service sent for the batch") }
    else { ck(false, "Return to Service sent for the batch") }
    ck(wipe?.summary == "1 succeeded, 2 failed, 1 not sent.", "wipe summary: \(wipe?.summary ?? "")")
    ck(wipe?.results[2].detail.hasPrefix("Permission denied") == true
       && wipe?.results[3].detail.contains("permission denied") == true, "permission denied explained, 104 says why it wasn't sent")
    ck(model.entries(for: .mobile).count == 4, "wipe leaves the list alone")

    // Bulk delete: 101, 102 deleted; 103 denied; 104 not sent. Deleted ones leave the list.
    model.setSelection(all, for: .mobile)
    ui.destructiveAnswers = [[:]]
    await model.bulkDelete()
    let del = ui.results.last
    let delOutcomes = del?.results.map { "\($0.device):\($0.outcome)" } ?? []
    ck(ui.destructiveCalls.last?.typed == "4" && ui.destructiveCalls.last?.options.isEmpty == true,
       "delete confirm: typed count, no options")
    ck(delOutcomes == ["iPad-101:succeeded", "iPad-102:succeeded", "iPad-103:failed", "iPad-104:notSent"],
       "delete results: \(delOutcomes)")
    let deletes = (try? await model.client!.get("/__deletes"))?.arrayValue?.map(\.text) ?? []
    ck(!deletes.contains { $0.hasSuffix("/104") }, "104 never deleted: \(deletes)")
    ck(model.entries(for: .mobile).map(\.id) == ["103", "104"], "deleted records leave the list: \(model.entries(for: .mobile).map(\.id))")

    // Computers: nothing selected there, so Wipe is unavailable.
    model.tab = .computers
    ck(!model.canPerform(.wipe), "no devices selected on Computers: Wipe unavailable")

    print(fails == 0 ? "\nALL PASSED" : "\n\(fails) FAILURE(S)"); exit(fails == 0 ? 0 : 1)
} }

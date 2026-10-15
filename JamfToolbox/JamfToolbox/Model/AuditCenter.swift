import AppKit
import SwiftUI

/// State for the Jamf Audits tab: the chosen report and its inputs, the
/// running audit, and saved results.
@MainActor
final class AuditCenter: ObservableObject {
    @Published private(set) var results: [AuditResult] = []
    @Published var selection: Set<UUID> = []

    @Published var reportID = AuditReports.groupDependenciesID {
        didSet {
            guard oldValue != reportID else { return }
            // Keep the device kind valid for reports that only cover one side.
            if !report.kinds.contains(parameters.kind) { parameters.kind = report.kinds[0] }
            Task { await loadGroupsIfNeeded() }
        }
    }
    @Published var parameters = AuditParameters() {
        didSet {
            guard oldValue.kind != parameters.kind else { return }
            parameters.groupID = nil
            parameters.deviceID = nil
            Task { await loadGroupsIfNeeded() }
        }
    }
    @Published private(set) var groups: [GroupKind: [GroupSummary]] = [:]
    @Published private(set) var loadingGroups = false
    @Published private(set) var groupsError: String?
    @Published private(set) var progress: AuditProgress?
    /// True while profile scopes are being changed from a result.
    @Published var changingScope = false

    let store: AuditStore
    weak var model: AppModel?
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }
    var report: AuditReport { AuditReports.report(reportID) ?? AuditReports.all[0] }
    var category: AuditCategory {
        get { report.category }
        set { if newValue != category, let first = AuditReports.reports(in: newValue).first { reportID = first.id } }
    }

    init(store: AuditStore) {
        self.store = store
        results = store.loadAll()
    }

    /// The result shown in the detail pane (exactly one selected).
    var selectedResult: AuditResult? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return results.first { $0.id == id }
    }

    var currentGroups: [GroupSummary] { groups[parameters.kind] ?? [] }

    /// Devices offered by device reports: the working list of the chosen kind.
    var deviceOptions: [DeviceEntry] { model?.entries(for: parameters.kind.deviceType) ?? [] }

    /// Whether the chosen report has everything it needs.
    var canRun: Bool {
        let r = report, p = parameters
        if r.needs(.group) && (p.groupID ?? "").isEmpty { return false }
        if r.needs(.device) && (p.deviceID ?? "").isEmpty { return false }
        if r.needs(.osVersion) && p.osVersion.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if r.needs(.pastedList) && AuditReports.pastedValues(p.pastedList).isEmpty { return false }
        return true
    }

    // MARK: Groups

    func loadGroupsIfNeeded() async {
        guard report.needs(.group), groups[parameters.kind] == nil else { return }
        await loadGroups()
    }

    func loadGroups() async {
        let kind = parameters.kind
        guard let client = model?.client else {
            groupsError = "Connect to Jamf Pro in Settings first."
            return
        }
        loadingGroups = true
        groupsError = nil
        defer { loadingGroups = false }
        do {
            let listing = try await client.get("/JSSResource/\(kind.resource)")
            groups[kind] = AuditObjects.entries(in: listing)
                .map { GroupSummary(id: $0.id, name: $0.name, isSmart: AuditObjects.isTrue($0.json["is_smart"])) }
                .filter { !$0.isSmart }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            groupsError = model?.failureMessage(error, doing: "read \(kind.label.lowercased()) groups") ?? error.localizedDescription
        }
    }

    // MARK: Running

    func runSelected() {
        var p = parameters
        if report.needs(.group) { p.groupName = currentGroups.first { $0.id == p.groupID }?.name }
        if report.needs(.device) {
            p.deviceName = deviceOptions.first { $0.id == p.deviceID }.map { $0.value(.name).isEmpty ? $0.id : $0.value(.name) }
        }
        run(report, p)
    }

    /// Re-run a saved result's report with the same inputs, against the current
    /// server. `replacing` deletes the old result once the new one is saved.
    func rerun(_ result: AuditResult, replacing: Bool = false) {
        guard let report = AuditReports.report(result.reportID) else { return }
        var p = result.parameters ?? AuditParameters()
        if result.parameters == nil, let subject = result.subject {   // saved by the first version
            p.kind = subject.kind
            p.groupID = subject.id
            p.groupName = subject.name
        }
        reportID = report.id
        parameters = p
        run(report, p, replaces: replacing ? result.id : nil)
    }

    /// From a device's right-click menu: run a device report for it.
    func runDeviceReport(_ id: String, kind: GroupKind, device: DeviceEntry) {
        guard let report = AuditReports.report(id) else { return }
        reportID = id
        var p = parameters
        p.kind = kind
        p.deviceID = device.id
        p.deviceName = device.value(.name).isEmpty ? device.id : device.value(.name)
        parameters = p
        model?.tab = .audits
        run(report, p)
    }

    private func run(_ report: AuditReport, _ parameters: AuditParameters, replaces old: UUID? = nil) {
        guard runTask == nil, let model else { return }
        guard let client = model.client else {
            Task { _ = await model.requireClient() }
            return
        }
        selection = []   // show the progress in the New Audit pane
        progress = AuditProgress(done: 0, total: 0, message: "Starting…")
        let about = parameters.groupName ?? parameters.deviceName
        model.log.add("Audit started: \(report.title)" + (about.map { " for “\($0)”" } ?? "") + ".")
        runTask = Task {
            defer {
                progress = nil
                runTask = nil
            }
            do {
                let result = try await AuditReports.run(report, parameters: parameters, client: client) { update in
                    self.progress = update
                }
                try store.save(result)
                if let old {
                    store.delete([old])
                    results.removeAll { $0.id == old }
                }
                results.insert(result, at: 0)
                selection = [result.id]
                model.log.add("Audit finished: \(report.title): \(result.findings.count) finding(s)"
                              + (result.warnings.isEmpty ? "." : " (\(result.warnings.count) warning(s); results may be incomplete)."))
            } catch is CancellationError {
                model.log.add("Audit cancelled.")
            } catch {
                let message = model.failureMessage(error, doing: "run \(report.title)")
                model.log.add("Audit failed: \(message.components(separatedBy: "\n").first ?? message)")
                await Dialogs.error(message)
            }
        }
    }

    func cancel() { runTask?.cancel() }

    // MARK: Saved results

    func delete(_ ids: Set<UUID>) {
        store.delete(ids)
        results.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        model?.log.add("Deleted \(ids.count) saved audit result(s).")
    }

    /// Results run before the start of `day`.
    func olderThan(_ day: Date) -> [AuditResult] {
        let cutoff = Calendar.current.startOfDay(for: day)
        return results.filter { $0.runAt < cutoff }
    }

    func deleteOlder(than day: Date) {
        let old = Set(olderThan(day).map(\.id))
        guard !old.isEmpty else { return }
        delete(old)
    }

    func exportCSV(_ result: AuditResult) async {
        let panel = NSSavePanel()
        panel.title = "Export audit result"
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = result.runAt.formatted(.iso8601.year().month().day())
        let about = result.subject.map { " - \($0.name)" } ?? ""
        panel.nameFieldStringValue = "\(result.report)\(about) - \(day).csv".replacingOccurrences(of: "/", with: "-")
        let response: NSApplication.ModalResponse
        if let window = Dialogs.anchor { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        var lines: [String]
        if result.findings.contains(where: { $0.installed != nil }) {   // a device's profiles
            lines = [ListExport.csvLine(["Name", result.detailHeading, "Installed", "Type", "Jamf ID"])]
            lines += result.findings.map { ListExport.csvLine([$0.objectName, $0.detail, $0.installedText, $0.objectType, $0.objectID]) }
        } else {
            lines = [ListExport.csvLine(["Type", "Name", result.detailHeading, "Jamf ID"])]
            lines += result.findings.map { ListExport.csvLine([$0.objectType, $0.objectName, $0.detail, $0.objectID]) }
        }
        do {
            try (Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)).write(to: url, options: .atomic)
            model?.log.add("Exported audit result to \(url.lastPathComponent).")
        } catch {
            await Dialogs.error("Could not export the result:\n\(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Seeds saved results (previews only).
    func addPreviewResults(_ samples: [AuditResult]) {
        for sample in samples { try? store.save(sample) }
        results = store.loadAll()
    }
    #endif
}

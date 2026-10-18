import Foundation

/// State for the Jamf Audits tab: the chosen report and its inputs, the
/// running audit, and saved results.
@MainActor
public final class AuditCenter: ObservableObject {
    @Published public private(set) var results: [AuditResult] = []
    @Published public var selection: Set<UUID> = []

    @Published public var reportID = AuditReports.groupDependenciesID {
        didSet {
            guard oldValue != reportID else { return }
            // Keep the device kind valid for reports that only cover one side.
            if !report.kinds.contains(parameters.kind) { parameters.kind = report.kinds[0] }
            Task { await loadGroupsIfNeeded() }
        }
    }
    @Published public var parameters = AuditParameters() {
        didSet {
            guard oldValue.kind != parameters.kind else { return }
            parameters.groupID = nil
            parameters.deviceID = nil
            Task { await loadGroupsIfNeeded() }
        }
    }
    @Published public private(set) var groups: [GroupKind: [GroupSummary]] = [:]
    @Published public private(set) var loadingGroups = false
    @Published public private(set) var groupsError: String?
    @Published public private(set) var progress: AuditProgress?
    /// True while profile scopes are being changed from a result.
    @Published public var changingScope = false

    public let store: AuditStore
    public weak var model: AppModel?
    private var runTask: Task<Void, Never>?

    public var isRunning: Bool { runTask != nil }
    public var report: AuditReport { AuditReports.report(reportID) ?? AuditReports.all[0] }
    public var category: AuditCategory {
        get { report.category }
        set { if newValue != category, let first = AuditReports.reports(in: newValue).first { reportID = first.id } }
    }

    public init(store: AuditStore) {
        self.store = store
        results = store.loadAll()
    }

    /// The result shown in the detail pane (exactly one selected).
    public var selectedResult: AuditResult? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return results.first { $0.id == id }
    }

    public var currentGroups: [GroupSummary] { groups[parameters.kind] ?? [] }

    /// Devices offered by device reports: the working list of the chosen kind.
    public var deviceOptions: [DeviceEntry] { model?.entries(for: parameters.kind.deviceType) ?? [] }

    /// Whether the chosen report has everything it needs.
    public var canRun: Bool {
        let r = report, p = parameters
        if r.needs(.group) && (p.groupID ?? "").isEmpty { return false }
        if r.needs(.device) && (p.deviceID ?? "").isEmpty { return false }
        if r.needs(.osVersion) && p.osVersion.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if r.needs(.pastedList) && AuditReports.pastedValues(p.pastedList).isEmpty { return false }
        return true
    }

    // MARK: Groups

    public func loadGroupsIfNeeded() async {
        guard report.needs(.group), groups[parameters.kind] == nil else { return }
        await loadGroups()
    }

    public func loadGroups() async {
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

    public func runSelected() {
        var p = parameters
        if report.needs(.group) { p.groupName = currentGroups.first { $0.id == p.groupID }?.name }
        if report.needs(.device) {
            p.deviceName = deviceOptions.first { $0.id == p.deviceID }.map { $0.value(.name).isEmpty ? $0.id : $0.value(.name) }
        }
        run(report, p)
    }

    /// Re-run a saved result's report with the same inputs, against the current
    /// server. `replacing` deletes the old result once the new one is saved.
    public func rerun(_ result: AuditResult, replacing: Bool = false) {
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
    public func runDeviceReport(_ id: String, kind: GroupKind, device: DeviceEntry) {
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

    func run(_ report: AuditReport, _ parameters: AuditParameters, replaces old: UUID? = nil) {
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
                await model.ui.error(message)
            }
        }
    }

    public func cancel() { runTask?.cancel() }

    // MARK: Saved results

    public func delete(_ ids: Set<UUID>) {
        store.delete(ids)
        results.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        model?.log.add("Deleted \(ids.count) saved audit result(s).")
    }

    /// Results run before the start of `day`.
    public func olderThan(_ day: Date) -> [AuditResult] {
        let cutoff = Calendar.current.startOfDay(for: day)
        return results.filter { $0.runAt < cutoff }
    }

    public func deleteOlder(than day: Date) {
        let old = Set(olderThan(day).map(\.id))
        guard !old.isEmpty else { return }
        delete(old)
    }

    /// The name an exported result is offered under.
    public func exportFileName(for result: AuditResult) -> String {
        let day = result.runAt.formatted(.iso8601.year().month().day())
        let about = result.subject.map { " - \($0.name)" } ?? ""
        return "\(result.report)\(about) - \(day).csv".replacingOccurrences(of: "/", with: "-")
    }

    /// A result as a CSV file (UTF-8 with a byte-order mark, for Excel).
    public func csvData(for result: AuditResult) -> Data {
        var lines: [String]
        if result.findings.contains(where: { $0.device != nil }) {   // profile and device pairs
            lines = [ListExport.csvLine(["Profile", "Device", result.detailHeading, "Excluded", "Profile ID", "Device ID"])]
            lines += result.findings.map {
                ListExport.csvLine([$0.objectName, $0.deviceName, $0.detail, $0.excludedText, $0.objectID, $0.device?.id ?? ""])
            }
        } else if result.findings.contains(where: { $0.installed != nil }) {   // a device's profiles
            lines = [ListExport.csvLine(["Name", result.detailHeading, "Installed", "Type", "Jamf ID"])]
            lines += result.findings.map { ListExport.csvLine([$0.objectName, $0.detail, $0.installedText, $0.objectType, $0.objectID]) }
        } else {
            lines = [ListExport.csvLine(["Type", "Name", result.detailHeading, "Jamf ID"])]
            lines += result.findings.map { ListExport.csvLine([$0.objectType, $0.objectName, $0.detail, $0.objectID]) }
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    #if DEBUG
    /// Seeds saved results (previews only).
    public func addPreviewResults(_ samples: [AuditResult]) {
        for sample in samples { try? store.save(sample) }
        results = store.loadAll()
    }
    #endif
}

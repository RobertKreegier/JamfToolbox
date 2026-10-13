import AppKit
import SwiftUI

/// State for the Jamf Audits tab: the group picker, the running audit, and saved results.
@MainActor
final class AuditCenter: ObservableObject {
    @Published private(set) var results: [AuditResult] = []
    @Published var selection: Set<UUID> = []

    @Published var groupKind: GroupKind = .computer {
        didSet {
            guard oldValue != groupKind else { return }
            selectedGroupID = nil
            Task { await loadGroups() }
        }
    }
    @Published var selectedGroupID: String?
    @Published private(set) var groups: [GroupKind: [GroupSummary]] = [:]
    @Published private(set) var loadingGroups = false
    @Published private(set) var groupsError: String?
    @Published private(set) var progress: AuditProgress?

    let store: AuditStore
    weak var model: AppModel?
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }

    init(store: AuditStore) {
        self.store = store
        results = store.loadAll()
    }

    /// The result shown in the detail pane (exactly one selected).
    var selectedResult: AuditResult? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return results.first { $0.id == id }
    }

    var currentGroups: [GroupSummary] { groups[groupKind] ?? [] }

    // MARK: Groups

    func loadGroupsIfNeeded() async {
        if groups[groupKind] == nil { await loadGroups() }
    }

    func loadGroups() async {
        let kind = groupKind
        guard let client = model?.client else {
            groupsError = "Connect to Jamf Pro in Settings first."
            return
        }
        loadingGroups = true
        groupsError = nil
        defer { loadingGroups = false }
        do {
            groups[kind] = try await StaticGroupDependencyAudit.staticGroups(kind, client: client)
        } catch {
            groupsError = model?.failureMessage(error, doing: "read \(kind.label.lowercased()) groups") ?? error.localizedDescription
        }
    }

    // MARK: Running

    func runSelected() {
        guard let group = currentGroups.first(where: { $0.id == selectedGroupID }) else { return }
        run(AuditSubject(kind: groupKind, id: group.id, name: group.name))
    }

    /// Re-run a saved result's audit against the current server.
    func rerun(_ result: AuditResult) {
        groupKind = result.subject.kind
        selectedGroupID = result.subject.id
        run(AuditSubject(kind: result.subject.kind, id: result.subject.id, name: result.subject.name))
    }

    private func run(_ subject: AuditSubject) {
        guard runTask == nil, let model else { return }
        guard let client = model.client else {
            Task { _ = await model.requireClient() }
            return
        }
        selection = []   // show the progress in the New Audit pane
        progress = AuditProgress(done: 0, total: 0, message: "Starting…")
        model.log.add("Audit started: what depends on \(subject.kind.label.lowercased()) group “\(subject.name)”.")
        runTask = Task {
            defer {
                progress = nil
                runTask = nil
            }
            do {
                let result = try await StaticGroupDependencyAudit.run(subject: subject, client: client) { update in
                    self.progress = update
                }
                try store.save(result)
                results.insert(result, at: 0)
                selection = [result.id]
                let objects = Set(result.findings.map { "\($0.objectType)|\($0.objectID)" }).count
                model.log.add("Audit finished: “\(subject.name)” is used by \(objects) object(s)"
                              + (result.warnings.isEmpty ? "." : " (\(result.warnings.count) warning(s); results may be incomplete)."))
            } catch is CancellationError {
                model.log.add("Audit cancelled.")
            } catch {
                let message = model.describe(error)
                model.log.add("Audit failed: \(message)")
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
        panel.nameFieldStringValue = "Group dependencies - \(result.subject.name) - \(day).csv"
        let response: NSApplication.ModalResponse
        if let window = Dialogs.anchor { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        var lines = [ListExport.csvLine(["Type", "Name", "Relationship", "Jamf ID"])]
        lines += result.findings.map { ListExport.csvLine([$0.objectType, $0.objectName, $0.relationship, $0.objectID]) }
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

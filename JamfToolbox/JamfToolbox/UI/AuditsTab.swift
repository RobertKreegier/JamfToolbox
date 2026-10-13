import AppKit
import SwiftUI

/// The Jamf Audits tab: saved results on the left; on the right, either the
/// selected result or the form for running a new audit.
struct AuditsTab: View {
    @ObservedObject var center: AuditCenter

    var body: some View {
        HSplitView {
            SavedResultsList(center: center)
                .frame(minWidth: 330, idealWidth: 400, maxWidth: 560)
            Group {
                if let result = center.selectedResult {
                    AuditResultView(center: center, result: result)
                } else {
                    NewAuditView(center: center)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Saved results

private struct SavedResultsList: View {
    @ObservedObject var center: AuditCenter
    @State private var sortOrder = [KeyPathComparator(\AuditResult.runAt, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Results").font(.headline)
                Spacer()
                Button { center.selection = [] } label: { Label("New Audit", systemImage: "plus") }
                    .help("Run a new audit")
            }
            .padding(10)

            Table(center.results.sorted(using: sortOrder), selection: $center.selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.runAt) { result in
                    Text(result.runAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
                .width(min: 120, ideal: 140)
                TableColumn("Group", value: \.subject.name)
                TableColumn("Type", value: \.subject.kind.label)
                    .width(min: 60, ideal: 90)
                TableColumn("Found", value: \.findings.count) { result in
                    Text("\(objectCount(result))").monospacedDigit()
                }
                .width(min: 40, ideal: 50)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button(ids.count > 1 ? "Delete \(ids.count) Results…" : "Delete Result…") { confirmDelete(ids) }
                    .disabled(ids.isEmpty)
            }

            Divider()
            HStack {
                Button("Delete…") { confirmDelete(center.selection) }
                    .disabled(center.selection.isEmpty)
                Spacer()
                Button("Delete Older Than…") { deleteOlder() }
                    .disabled(center.results.isEmpty)
            }
            .padding(8)
        }
    }

    private func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task {
            if await Dialogs.confirm("Delete \(ids.count) saved audit result(s)? This can't be undone.",
                                     yes: "Delete", no: "Cancel") {
                center.delete(ids)
            }
        }
    }

    private func deleteOlder() {
        Task {
            let day: Date? = await Sheets.present { done in
                DeleteOlderSheet(count: { center.olderThan($0).count }, done: done)
            }
            if let day { center.deleteOlder(than: day) }
        }
    }
}

/// Objects (not relationships) that depend on the group.
private func objectCount(_ result: AuditResult) -> Int {
    Set(result.findings.map { "\($0.objectType)|\($0.objectID)" }).count
}

private struct DeleteOlderSheet: View {
    let count: (Date) -> Int
    let done: (Date?) -> Void
    @State private var day = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

    var body: some View {
        let matching = count(day)
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete older results").font(.headline)
            DatePicker("Delete results run before", selection: $day, in: ...Date(), displayedComponents: .date)
            Text(matching == 0 ? "No saved results are that old."
                               : "\(matching) saved result(s) will be deleted. This can't be undone.")
                .foregroundStyle(matching == 0 ? .secondary : .primary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Delete") { done(day) }
                    .disabled(matching == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - New audit

private struct NewAuditView: View {
    @ObservedObject var center: AuditCenter

    var body: some View {
        Form {
            Section("Report") {
                LabeledContent("Report", value: StaticGroupDependencyAudit.reportName)
                Text("Finds everything in Jamf Pro that depends on a static group: what it's scoped to, "
                     + "excluded from, or limited by, and any smart group or advanced search whose criteria "
                     + "name it. Use it before renaming or deleting a group. Read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Group") {
                Picker("Group type", selection: $center.groupKind) {
                    ForEach(GroupKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(center.isRunning)

                HStack {
                    Picker("Static group", selection: $center.selectedGroupID) {
                        Text(center.loadingGroups ? "Loading…" : "Choose a group").tag(String?.none)
                        ForEach(center.currentGroups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .disabled(center.isRunning || center.currentGroups.isEmpty)
                    Button { Task { await center.loadGroups() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload groups from Jamf Pro")
                        .disabled(center.loadingGroups || center.isRunning)
                }
                if let error = center.groupsError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !center.loadingGroups, center.groups[center.groupKind] != nil, center.currentGroups.isEmpty {
                    Text("No static \(center.groupKind.label.lowercased()) groups found.").foregroundStyle(.secondary)
                }
            }

            Section {
                if let progress = center.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        if progress.total > 0 {
                            ProgressView(value: Double(progress.done), total: Double(progress.total))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(progress.message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Spacer()
                            Button("Cancel") { center.cancel() }
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Run Audit") { center.runSelected() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(center.selectedGroupID == nil)
                    }
                }
            }

            Section("What's checked") {
                let types = StaticGroupDependencyAudit.objectTypes.filter { $0.kinds.contains(center.groupKind) }
                Text(types.map(\.plural).joined(separator: ", ").prefix(1).uppercased()
                     + types.map(\.plural).joined(separator: ", ").dropFirst() + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await center.loadGroupsIfNeeded() }
    }
}

// MARK: - Result detail

private struct AuditResultView: View {
    @ObservedObject var center: AuditCenter
    let result: AuditResult

    @State private var sortOrder = [KeyPathComparator(\AuditFinding.objectType)]
    @State private var findingSelection = Set<AuditFinding.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summary
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if !result.findings.isEmpty {
                Table(result.findings.sorted(using: sortOrder), selection: $findingSelection, sortOrder: $sortOrder) {
                    TableColumn("Type", value: \.objectType)
                        .width(min: 120, ideal: 220)
                    TableColumn("Name", value: \.objectName)
                    TableColumn("Relationship", value: \.relationship)
                        .width(min: 90, ideal: 150)
                    TableColumn("ID", value: \.objectID)
                        .width(min: 40, ideal: 50)
                }
                .contextMenu(forSelectionType: AuditFinding.ID.self) { ids in
                    Button("Open in Jamf Pro") { open(ids) }
                    Button("Copy Name") { copyNames(ids) }
                } primaryAction: { ids in open(ids) }
            } else {
                Spacer()
            }
            footer
        }
        .padding(14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.subject.name).font(.title2.weight(.semibold))
            Text([result.subject.kind.label + " static group",
                  result.subject.memberCount.map { "\($0) member(s)" },
                  result.report].compactMap { $0 }.joined(separator: "  ·  "))
                .foregroundStyle(.secondary)
            Text("Run \(result.runAt.formatted(date: .abbreviated, time: .shortened)) on \(result.server)  ·  "
                 + "\(result.objectsScanned) objects checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if result.findings.isEmpty {
            Label(result.warnings.isEmpty
                  ? "Nothing in Jamf Pro refers to this group."
                  : "No references found in the objects that could be checked.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            let counts = Dictionary(grouping: result.findings, by: \.objectType)
                .mapValues { Set($0.map(\.objectID)).count }
            let total = objectCount(result)
            Text("Used by \(total) object\(total == 1 ? "" : "s"): "
                 + StaticGroupDependencyAudit.describeCounts(counts))
                .font(.headline)
        }
    }

    private var footer: some View {
        HStack {
            Button("Run Again") { center.rerun(result) }
                .disabled(center.isRunning)
                .help("Run this audit again against the current server")
            Button("Export CSV…") { Task { await center.exportCSV(result) } }
                .disabled(result.findings.isEmpty)
            Spacer()
            Button("Delete Result", role: .destructive) {
                Task {
                    if await Dialogs.confirm("Delete this saved result? This can't be undone.", yes: "Delete", no: "Cancel") {
                        center.delete([result.id])
                    }
                }
            }
        }
    }

    private func findings(_ ids: Set<AuditFinding.ID>) -> [AuditFinding] {
        result.findings.filter { ids.contains($0.id) }
    }

    private func open(_ ids: Set<AuditFinding.ID>) {
        for finding in findings(ids) {
            guard let page = finding.webPage,
                  let url = URL(string: "\(result.server)/\(page)?id=\(finding.objectID)&o=r") else { continue }
            NSWorkspace.shared.open(url)
        }
    }

    private func copyNames(_ ids: Set<AuditFinding.ID>) {
        let names = Array(Set(findings(ids).map(\.objectName))).sorted()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
}

#if DEBUG
#Preview("Result selected") {
    let model = PreviewData.model()
    model.audits.addPreviewResults(PreviewData.auditResults)
    model.audits.selection = [model.audits.results[0].id]
    return AuditsTab(center: model.audits).frame(width: 1100, height: 520)
}

#Preview("New audit") {
    let model = PreviewData.model()
    model.audits.addPreviewResults(PreviewData.auditResults)
    return AuditsTab(center: model.audits).frame(width: 1100, height: 520)
}
#endif

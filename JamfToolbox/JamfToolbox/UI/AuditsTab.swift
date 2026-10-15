import AppKit
import SwiftUI

/// The Jamf Audits tab: saved results on the left; on the right, either the
/// selected result or the form for running a new audit.
struct AuditsTab: View {
    @ObservedObject var center: AuditCenter
    /// The saved-results width once the divider has been dragged; nil means
    /// "a third of the tab", the starting layout.
    @State private var listWidth: CGFloat?
    @State private var dragStart: CGFloat?

    private static let minList: CGFloat = 260
    private static let minDetail: CGFloat = 460

    var body: some View {
        // A plain stack with a drag handle rather than HSplitView, which
        // ignores the starting width and opens half and half.
        GeometryReader { geometry in
            let total = geometry.size.width
            let maxList = max(Self.minList, total - Self.minDetail - 7)
            let width = min(max(listWidth ?? total / 3, Self.minList), maxList)
            HStack(spacing: 0) {
                SavedResultsList(center: center)
                    .frame(width: width)
                ColumnResizeHandle()
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? width
                            dragStart = start
                            listWidth = min(max(start + drag.translation.width, Self.minList), maxList)
                        }
                        .onEnded { _ in dragStart = nil })
                Group {
                    if let result = center.selectedResult {
                        AuditResultView(center: center, result: result)
                    } else {
                        NewAuditView(center: center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The divider between saved results and the result: a hairline with a wider
/// grab area and the left/right resize cursor.
private struct ColumnResizeHandle: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize")
    }
}

// MARK: - Saved results

private struct SavedResultsList: View {
    @ObservedObject var center: AuditCenter

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy"
        return f
    }()

    /// Narrowest widths that show the whole date / the heading with its sort
    /// arrow, measured in the table's font so they hold at any text size.
    private static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    static let dateWidth = max(textWidth("00/00/0000"), textWidth("Date") + 16) + 8
    static let foundWidth = textWidth("Found") + 22
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
                    Text(Self.dateFormat.string(from: result.runAt)).monospacedDigit()
                }
                .width(min: Self.dateWidth, ideal: Self.dateWidth, max: Self.dateWidth + 24)
                TableColumn("Report", value: \.report)
                    .width(min: 80, ideal: 150)
                TableColumn("Scope", value: \.subjectLabel)
                    .width(min: 80, ideal: 150)
                TableColumn("Found", value: \.findings.count) { result in
                    Text("\(result.findings.count)").monospacedDigit()
                }
                .width(min: Self.foundWidth, ideal: Self.foundWidth, max: Self.foundWidth + 24)
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
        let report = center.report
        Form {
            Section("Report") {
                Picker("Category", selection: deferred($center.category)) {
                    ForEach(AuditCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Report", selection: deferred($center.reportID)) {
                    ForEach(AuditReports.reports(in: center.category)) { Text($0.title).tag($0.id) }
                }
                LabeledContent("Summary") {
                    Text(report.summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(center.isRunning)

            if !report.inputs.isEmpty || report.kinds.count == 1 {
                Section("Options") { inputs(report) }
                    .disabled(center.isRunning)
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
                        Text("Audits only read from Jamf Pro. Changes offered on a result always ask first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Run Audit") { center.runSelected() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!center.canRun)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: center.reportID) { await center.loadGroupsIfNeeded() }
    }

    @ViewBuilder
    private func inputs(_ report: AuditReport) -> some View {
        if report.needs(.kind) && report.kinds.count > 1 {
            Picker("Devices", selection: deferred($center.parameters.kind)) {
                ForEach(report.kinds) { Text($0.label + "s").tag($0) }
            }
            .pickerStyle(.segmented)
        } else if report.kinds.count == 1 {
            LabeledContent("Devices", value: report.kinds[0].label + "s")
        }

        if report.needs(.group) { groupPicker }
        if report.needs(.device) { devicePicker }

        if report.needs(.days) {
            LabeledContent(report.category == .policies ? "Within the last" : "Not seen for") {
                NumberField(value: $center.parameters.days, range: 1...3650, unit: "days")
            }
        }
        if report.needs(.threshold) {
            LabeledContent("At least") {
                NumberField(value: $center.parameters.threshold, range: 1...1000, unit: "pending commands")
            }
        }
        if report.needs(.osVersion) {
            TextField("Target version", text: $center.parameters.osVersion,
                      prompt: Text(center.parameters.kind == .computer ? "e.g. 15.4" : "e.g. 18.0"))
        }
        if report.needs(.pastedList) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste serial numbers, names, UDIDs or MAC addresses, one per line (or a CSV: the first column is used).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $center.parameters.pastedList)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                let count = AuditReports.pastedValues(center.parameters.pastedList).count
                Text("\(count) value\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var groupPicker: some View {
        HStack {
            Picker("Static group", selection: $center.parameters.groupID) {
                Text(center.loadingGroups ? "Loading…" : "Choose a group").tag(String?.none)
                ForEach(center.currentGroups) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(center.currentGroups.isEmpty)
            Button { Task { await center.loadGroups() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload groups from Jamf Pro")
                .disabled(center.loadingGroups)
        }
        if let error = center.groupsError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if !center.loadingGroups, center.groups[center.parameters.kind] != nil, center.currentGroups.isEmpty {
            Text("No static \(center.parameters.kind.label.lowercased()) groups found.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var devicePicker: some View {
        let devices = center.deviceOptions
        Picker("Device", selection: $center.parameters.deviceID) {
            Text("Choose a device").tag(String?.none)
            ForEach(devices) { entry in
                let name = entry.value(.name).isEmpty ? entry.id : entry.value(.name)
                let serial = entry.value(.serial)
                Text(serial.isEmpty ? name : "\(name) (\(serial))").tag(Optional(entry.id))
            }
        }
        .disabled(devices.isEmpty)
        Text(devices.isEmpty
             ? "Add the device to your \(center.parameters.kind.label) list first. You can also right-click a device in its list and choose Audit."
             : "Devices come from your \(center.parameters.kind.label) list. You can also right-click a device there and choose Audit.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Pickers here change several published values at once; applying the change
/// on the next run-loop turn avoids "Publishing changes from within view
/// updates" when the control writes during a view update.
private func deferred<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(get: { binding.wrappedValue },
            set: { newValue in DispatchQueue.main.async { binding.wrappedValue = newValue } })
}

/// A small number entry with a stepper.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: range).labelsHidden()
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Result detail

private struct AuditResultView: View {
    @ObservedObject var center: AuditCenter
    let result: AuditResult

    /// Empty until a header is clicked, so findings keep the report's own order
    /// (e.g. targeted before excluded before installed-only).
    @State private var sortOrder: [KeyPathComparator<AuditFinding>] = []
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
                findingsTable
                    .contextMenu(forSelectionType: AuditFinding.ID.self) { ids in
                        contextMenu(ids)
                    } primaryAction: { ids in open(ids) }
                Text(offersScopeChanges
                     ? "Right-click profiles to exclude this device, remove a direct target, copy, export or open "
                        + "them in Jamf Pro. Double-click a row to view it in Jamf Pro."
                     : "Double-click a row to view it in Jamf Pro. Right-click for more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
            footer
        }
        .padding(14)
    }

    /// A device's profiles get Name, Targeting, Installed and Type; other
    /// reports get Type, Name, their detail and the Jamf ID.
    @ViewBuilder
    private var findingsTable: some View {
        let rows = result.findings.sorted(using: sortOrder)
        if result.findings.contains(where: { $0.installed != nil }) {
            Table(rows, selection: $findingSelection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.objectName)
                    .width(min: 80, ideal: 170)
                TableColumn(result.detailHeading, value: \.detail) { finding in
                    Text(finding.detail).help(finding.detail)   // full text on hover when truncated
                }
                .width(min: 120, ideal: 320)
                TableColumn("Installed", value: \.installedText)
                    .width(min: 55, ideal: 60, max: 90)
                TableColumn("Type", value: \.objectType) { finding in
                    Text(finding.objectType).help(finding.objectType)
                }
                .width(min: 80, ideal: 130)
            }
        } else {
            Table(rows, selection: $findingSelection, sortOrder: $sortOrder) {
                TableColumn("Type", value: \.objectType)
                    .width(min: 90, ideal: 140)
                TableColumn("Name", value: \.objectName)
                    .width(min: 80, ideal: 140)
                TableColumn(result.detailHeading, value: \.detail) { finding in
                    Text(finding.detail).help(finding.detail)
                }
                .width(min: 120, ideal: 360)
                TableColumn("ID", value: \.objectID)
                    .width(min: 40, ideal: 50)
            }
        }
    }

    /// Scope changes (for a device's profiles), Copy, Export CSV, Open in Jamf Pro.
    @ViewBuilder
    private func contextMenu(_ ids: Set<AuditFinding.ID>) -> some View {
        if offersScopeChanges {
            let selected = findings(ids)
            // One item for exclusions: Remove Exclusion when every selected profile
            // already excludes the device (directly or by its user), else Exclude.
            let scoped = selected.filter { $0.directScope != nil }
            let allExcluded = !scoped.isEmpty && scoped.allSatisfy { $0.directScope!.allows(.removeExclusion) }
            scopeChangeButton(allExcluded ? .removeExclusion : .exclude, selected)
            scopeChangeButton(.removeTarget, selected)
            Divider()
        }
        Menu("Copy") {
            Button("Copy Name") { copy(ids, \.objectName) }
            Button("Copy \(result.detailHeading)") { copy(ids, \.detail) }
        }
        Button("Export CSV…") { Task { await center.exportCSV(result) } }
        Divider()
        Button("Open in Jamf Pro") { open(ids) }
            .disabled(!canOpen(ids))
    }

    private func scopeChangeButton(_ change: ScopeChange, _ selected: [AuditFinding]) -> some View {
        let count = center.candidates(change, in: selected).count
        return Button(change.title + (count > 1 ? " (\(count) Profiles)…" : "…")) {
            Task { await center.applyScopeChange(change, to: selected, in: result) }
        }
        .disabled(count == 0 || center.isRunning || center.changingScope)
    }

    /// The audit's name, then labeled lines so each piece of information is easy to pick out.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.subject?.name ?? result.report).font(.title2.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                if result.subject != nil { row("Report", result.report) }
                // A reminder of what the report checks.
                if let summary = AuditReports.report(result.reportID)?.summary { row("Summary", summary) }
                if !result.subtitle.isEmpty { row("Scope", result.subtitle) }
                row("Checked", "\(result.objectsScanned) object\(result.objectsScanned == 1 ? "" : "s")")
                if !result.findings.isEmpty { row("Found", foundText, bold: true) }
                row("Server", result.server)
                row("Run", result.runAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(label + ":")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var foundText: String {
        let counts = Dictionary(grouping: result.findings, by: \.objectType).mapValues(\.count)
        let total = result.findings.count
        let noun = result.reportID == AuditReports.groupDependenciesID ? "reference" : "finding"
        return "\(total) \(noun)\(total == 1 ? "" : "s"): " + AuditObjects.describeCounts(counts)
    }

    /// Shown only when nothing was found (otherwise the Found line says what was).
    @ViewBuilder
    private var summary: some View {
        if result.findings.isEmpty {
            Label(result.warnings.isEmpty
                  ? (result.reportID == AuditReports.groupDependenciesID ? "Nothing in Jamf Pro refers to this group." : "No issues found.")
                  : "Nothing found in what could be checked.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var footer: some View {
        HStack {
            Button { center.rerun(result, replacing: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(center.isRunning || center.changingScope || AuditReports.report(result.reportID) == nil)
                .help("Run this report again and replace this result with the fresh one")
            Button { center.rerun(result) } label: { Label("Repeat", systemImage: "plus") }
                .disabled(center.isRunning || center.changingScope || AuditReports.report(result.reportID) == nil)
                .help("Run this report again with the same options as a new saved result, keeping this one")
            Spacer()
            Button("Export CSV…") { Task { await center.exportCSV(result) } }
                .disabled(result.findings.isEmpty)
        }
    }

    /// Results whose rows carry how the device is directly scoped (a device's
    /// Config Profiles in Scope).
    private var offersScopeChanges: Bool { result.findings.contains { $0.directScope != nil } }

    private func findings(_ ids: Set<AuditFinding.ID>) -> [AuditFinding] {
        result.findings.filter { ids.contains($0.id) }
    }

    private func url(_ finding: AuditFinding) -> URL? {
        guard !finding.objectID.isEmpty,
              let page = AuditObjects.webPage(forObjectType: finding.objectType) ?? finding.webPage else { return nil }
        return URL(string: "\(result.server)/\(page)?id=\(finding.objectID)&o=r")
    }

    private func canOpen(_ ids: Set<AuditFinding.ID>) -> Bool { findings(ids).contains { url($0) != nil } }

    private func open(_ ids: Set<AuditFinding.ID>) {
        for finding in findings(ids) { if let url = url(finding) { NSWorkspace.shared.open(url) } }
    }

    private func copy(_ ids: Set<AuditFinding.ID>, _ field: KeyPath<AuditFinding, String>) {
        let values = findings(ids).map { $0[keyPath: field] }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
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

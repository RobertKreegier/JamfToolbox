import SwiftUI
import JamfToolboxCore

// MARK: - Preview / edit before sending

/// Shows the rendered template (message, name, PIN…) for review and editing
/// before anything is sent. Returns the trimmed values keyed by field label,
/// or nil when cancelled. When presets are given, a picker at the top swaps
/// their values into the fields (which stay editable).
struct PreviewSheet: View {
    let title: String
    let intro: String
    let confirmLabel: String
    @State var fields: [PreviewField]
    var presets: [PreviewPreset] = []
    var presetLabel = "Preset"
    @State var selectedPreset = 0
    let done: ([String: String]?) -> Void

    private func apply(_ index: Int) {
        guard presets.indices.contains(index) else { return }
        for i in fields.indices {
            if let value = presets[index].values[fields[i].label] { fields[i].value = value }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                if presets.count > 1 {
                    GridRow {
                        Text(presetLabel).gridColumnAlignment(.trailing)
                        Picker(presetLabel, selection: $selectedPreset) {
                            ForEach(presets.indices, id: \.self) { index in
                                Text(presets[index].name + (index == 0 ? " (default)" : "")).tag(index)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedPreset) { apply($0) }
                    }
                }
                ForEach($fields) { $field in
                    GridRow {
                        Text(field.label)
                            .gridColumnAlignment(.trailing)
                            .padding(.top, field.multiline ? 4 : 0)
                        if field.multiline {
                            TextEditor(text: $field.value)
                                .font(.body)
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                        } else {
                            TextField("", text: $field.value)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    var result: [String: String] = [:]
                    for field in fields {
                        result[field.label] = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    done(result)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Choose one of several presets

/// Pick one saved preset before a bulk action. Returns its index, or nil when cancelled.
struct PresetChoiceSheet: View {
    let title: String
    let intro: String
    /// Name and template text of each preset; the first is the default.
    let options: [(name: String, text: String)]
    let confirmLabel: String
    let done: (Int?) -> Void
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Preset", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].name + (index == 0 ? " (default)" : "")).tag(index)
                }
            }
            Text(options.indices.contains(selection) ? options[selection].text : "")
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { done(selection) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Bulk confirm

/// Shows exactly what a bulk action will do, one line per device, and
/// requires explicit confirmation before anything is sent.
struct BulkConfirmSheet: View {
    let title: String
    let intro: String
    let lines: [String]
    let confirmLabel: String
    var warning = ""
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(intro).fixedSize(horizontal: false, vertical: true)
            if !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(260, max(80, CGFloat(lines.count) * 17 + 24)))
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))

            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { done(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Progress

/// Progress for a bulk operation. The work runs in an async loop; this sheet
/// only displays it and lets the user ask it to stop between devices.
struct ProgressSheet: View {
    let title: String
    @ObservedObject var progress: BulkProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(progress.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
            HStack {
                Spacer()
                Button("Cancel") { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.cancelled)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

#if DEBUG
#Preview("Rename") {
    PreviewSheet(title: "Rename device",
                 intro: "Rename “MBP-0042” using your configured format. Edit the result below if needed.",
                 confirmLabel: "Rename",
                 fields: [PreviewField(label: "New name", value: "Alex Rivera - C02XL0AAJGH5")],
                 done: { _ in })
}

#Preview("Lock (Mac)") {
    PreviewSheet(title: "Lock device",
                 intro: "Lock “MBP-ARIVERA”. The PIN below will be required to unlock it — record it before continuing.",
                 confirmLabel: "Lock",
                 fields: [PreviewField(label: "6-digit PIN", value: ""),
                          PreviewField(label: "Lock message", value: Preferences().defaultLock.message, multiline: true)],
                 presets: [PreviewPreset(name: "Default", values: ["Lock message": Preferences().defaultLock.message]),
                           PreviewPreset(name: "Stolen", values: ["Lock message": "Reported stolen. Call 555-0100."])],
                 done: { _ in })
}

#Preview("Bulk confirm") {
    BulkConfirmSheet(title: "Enable Lost Mode",
                     intro: "Lost Mode will be enabled on 2 device(s), locking each one and showing this message on its screen.",
                     lines: ["iPad-G5-014  →  iPad-G5-014 - (Lost Mode: Please return to tech desk)",
                             "iPad-G5-015  →  iPad-G5-015 - (Lost Mode: Please return to tech desk)"],
                     confirmLabel: "Enable on 2 Device(s)",
                     warning: "Each device becomes unusable until Lost Mode is turned off.",
                     done: { _ in })
}

#Preview("Progress") {
    let progress = BulkProgress(total: 12)
    progress.step(4, "iPad-G5-014 (5 of 12)…")
    return ProgressSheet(title: "Rename devices", progress: progress)
}
#endif

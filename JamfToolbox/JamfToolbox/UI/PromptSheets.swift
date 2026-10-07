import SwiftUI

// MARK: - Preview / edit before sending

struct PreviewField: Identifiable {
    let id = UUID()
    let label: String
    var value: String
    var multiline = false
}

/// Shows the rendered template (message, name, PIN…) for review and editing
/// before anything is sent. Returns the trimmed values keyed by field label,
/// or nil when cancelled.
struct PreviewSheet: View {
    let title: String
    let intro: String
    let confirmLabel: String
    @State var fields: [PreviewField]
    let done: ([String: String]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
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

@MainActor
final class BulkProgress: ObservableObject {
    let total: Int
    @Published private(set) var index = 0
    @Published private(set) var text = "Starting…"
    @Published private(set) var cancelled = false

    init(total: Int) { self.total = total }

    func step(_ index: Int, _ text: String) {
        self.index = index
        self.text = text
    }

    func cancel() {
        cancelled = true
        text = "Finishing the current device, then stopping…"
    }
}

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

import AppKit
import SwiftUI

/// Lets a free-standing window close itself.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
    func close() { window?.close() }
}

// MARK: - Arrange columns

/// Choose which columns the device list shows, and in what order.
struct ColumnsSheet: View {
    @State var shown: [ColumnField]
    let done: ([ColumnField]?) -> Void

    @State private var availableSelection: ColumnField.ID?
    @State private var shownSelection: ColumnField.ID?

    private var available: [ColumnField] { ColumnField.allCases.filter { !shown.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrange Columns").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                column("Available", fields: available, selection: $availableSelection)

                VStack(spacing: 8) {
                    Spacer().frame(height: 28)
                    Button("Add →") { add() }
                        .disabled(availableSelection == nil)
                    Button("← Remove") { remove() }
                        .disabled(shownSelection == nil || shown.count <= 1)
                    Divider().frame(width: 60)
                    Button("Move Up") { move(-1) }
                        .disabled(shownSelection == nil)
                    Button("Move Down") { move(1) }
                        .disabled(shownSelection == nil)
                }

                column("Shown (top = left)", fields: shown, selection: $shownSelection)
            }
            HStack {
                Button("Reset to Defaults") {
                    shown = ColumnField.defaults
                    availableSelection = nil
                    shownSelection = nil
                }
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { done(shown) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 380, idealHeight: 420)
    }

    private func column(_ title: String, fields: [ColumnField], selection: Binding<ColumnField.ID?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            List(fields, selection: selection) { Text($0.heading) }
                .frame(minWidth: 170)
        }
    }

    private func add() {
        guard let id = availableSelection, let field = ColumnField(rawValue: id) else { return }
        shown.append(field)
        availableSelection = nil
        shownSelection = field.id
    }

    private func remove() {
        guard let id = shownSelection, shown.count > 1,
              let index = shown.firstIndex(where: { $0.id == id }) else { return }   // keep at least one column
        shown.remove(at: index)
        shownSelection = nil
    }

    private func move(_ direction: Int) {
        guard let id = shownSelection, let index = shown.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard shown.indices.contains(target) else { return }
        shown.swapAt(index, target)
    }
}

#if DEBUG
#Preview { ColumnsSheet(shown: ColumnField.defaults, done: { _ in }) }
#endif

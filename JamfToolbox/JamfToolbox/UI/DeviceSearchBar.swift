import AppKit
import SwiftUI
import JamfToolboxCore

/// The search field. Typing searches Jamf Pro; Return adds the highlighted
/// result, ↑/↓ move the highlight, Esc closes the dropdown.
struct DeviceSearchField: View {
    @ObservedObject var search: DeviceSearch
    let deviceType: DeviceType

    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(deviceType.pluralName) to add…", text: $search.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { search.chooseHighlighted() }
            if search.isSearching {
                ProgressView().controlSize(.small)
            } else if !search.query.isEmpty {
                Button { search.reset(); focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.35)))
        .onChange(of: search.focusToken) { _ in focused = true }
        .onChange(of: search.isOpen) { open in open ? installKeys() : removeKeys() }
        .onDisappear { removeKeys() }
    }

    /// Arrow keys and Esc while the dropdown is open. A local monitor because
    /// the text field would otherwise swallow them.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [search] event in
            guard search.isOpen else { return event }
            switch event.keyCode {
            case 125: search.moveHighlight(1); return nil    // ↓
            case 126: search.moveHighlight(-1); return nil   // ↑
            case 53: search.dismiss(); return nil            // Esc
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The results dropdown, laid over the main window just under the search
/// field. A click anywhere else dismisses it.
struct DeviceSearchDropdown: View {
    @ObservedObject var search: DeviceSearch

    var body: some View {
        if search.isOpen {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { search.dismiss() }

                panel
                    .padding(.leading, 12)
                    .padding(.top, 44)
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = search.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if search.results.isEmpty {
                Text("Searching…")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(search.results.enumerated()), id: \.element.id) { index, entry in
                            row(entry, index: index)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func row(_ entry: DeviceEntry, index: Int) -> some View {
        let inList = search.isInList(entry)
        let detail = [entry.value(.serial), entry.value(.username), entry.value(.model)]
            .filter { !$0.isEmpty }.joined(separator: "  ·  ")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.value(.name).isEmpty ? "(unnamed)" : entry.value(.name))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if inList {
                Text("In list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(inList ? 0.6 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(index == search.highlighted ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { search.highlighted = index } }
        .onTapGesture { search.choose(entry) }
    }
}

#if DEBUG
#Preview("Search dropdown") {
    let model = PreviewData.model()
    model.search.showPreviewResults([PreviewData.computers[0],
                                     DeviceEntry(id: "150", fields: ["name": "MBP-ARIVERA-OLD", "serial": "C02AA1AAMD6R",
                                                                     "username": "arivera", "model": "MacBook Pro (13-inch, 2020)"])],
                                    query: "arivera")
    return ZStack(alignment: .topLeading) {
        VStack(alignment: .leading) {
            DeviceSearchField(search: model.search, deviceType: .computer)
                .frame(width: 320)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Spacer()
        }
        DeviceSearchDropdown(search: model.search)
    }
    .frame(width: 600, height: 300)
}
#endif

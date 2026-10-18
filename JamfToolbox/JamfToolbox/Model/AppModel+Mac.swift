import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JamfToolboxCore

/// The parts of the shared model that only make sense on the Mac: the app's
/// single instance, save panels and the column arranger.
extension AppModel {
    static let shared: AppModel = makeMac()

    /// A model whose prompts appear as AppKit sheets.
    static func makeMac(settings: SettingsStore? = nil) -> AppModel {
        let presenter = MacPresenter()
        let model = AppModel(settings: settings, presenter: presenter)
        presenter.model = model
        return model
    }

    func showArrangeColumns() {
        Task {
            let result: [ColumnField]? = await Sheets.present(resizable: true) { done in
                ColumnsSheet(shown: visibleColumns, done: done)
            }
            if let result { setColumns(result) }
        }
    }

    func exportList() async {
        let all = entries
        guard !all.isEmpty else {
            await Dialogs.info("The list is empty — nothing to export.")
            return
        }
        let type = deviceType
        let columns = visibleColumns
        let panel = NSSavePanel()
        panel.title = "Export list"
        panel.canCreateDirectories = true
        let accessory = ExportFormatAccessory(panel: panel, baseName: exportBaseName(type))
        panel.accessoryView = accessory.view

        let response: NSApplication.ModalResponse
        if let window = Dialogs.anchor {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }

        do {
            if url.pathExtension.lowercased() == "xlsx" {
                try ListExport.xlsxData(entries: all, columns: columns).write(to: url, options: .atomic)
            } else {
                try ListExport.csvFileData(entries: all, columns: columns).write(to: url, options: .atomic)
            }
        } catch {
            await Dialogs.error("Could not export the list:\n\(error.localizedDescription)")
            return
        }
        log.add("Exported \(all.count) \(type.exportName.lowercased()) to \(url.lastPathComponent).")
        if await Dialogs.confirm("Export complete. Reveal the file in Finder?", yes: "Reveal", no: "Done") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension AuditCenter {
    func exportCSV(_ result: AuditResult) async {
        let panel = NSSavePanel()
        panel.title = "Export audit result"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = exportFileName(for: result)
        let response: NSApplication.ModalResponse
        if let window = Dialogs.anchor { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        do {
            try csvData(for: result).write(to: url, options: .atomic)
            model?.log.add("Exported audit result to \(url.lastPathComponent).")
        } catch {
            await Dialogs.error("Could not export the result:\n\(error.localizedDescription)")
        }
    }
}

/// A "Format" pop-up for the save panel, switching between CSV and Excel.
@MainActor
final class ExportFormatAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
    private let popup = NSPopUpButton(frame: NSRect(x: 80, y: 4, width: 200, height: 26), pullsDown: false)
    private weak var panel: NSSavePanel?
    private let baseName: String
    private let formats: [(title: String, ext: String, type: UTType)] = [
        ("CSV file", "csv", .commaSeparatedText),
        ("Excel workbook", "xlsx", UTType(filenameExtension: "xlsx") ?? .data),
    ]

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        super.init()
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 9, width: 56, height: 17)
        label.alignment = .right
        view.addSubview(label)
        popup.addItems(withTitles: formats.map(\.title))
        popup.target = self
        popup.action = #selector(formatChanged)
        view.addSubview(popup)
        apply()
    }

    @objc private func formatChanged() { apply() }

    private func apply() {
        guard let panel else { return }
        let format = formats[max(0, popup.indexOfSelectedItem)]
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(baseName).\(format.ext)"
    }
}

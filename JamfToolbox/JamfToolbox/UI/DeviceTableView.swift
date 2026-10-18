import AppKit
import SwiftUI
import JamfToolboxCore

/// The device list.
///
/// SwiftUI's `Table` can't change its column set at runtime before macOS 14.4,
/// and this list lets the user show, hide and reorder any of 20 columns, so it
/// is an `NSTableView`. Everything else in the app is SwiftUI.
struct DeviceTableView: NSViewRepresentable {
    let entries: [DeviceEntry]
    let columns: [ColumnField]
    let selection: Set<String>
    let sort: SortState?
    let reveal: RevealRequest?
    /// Which list this table shows. Each tab has its own table instance.
    let type: DeviceType
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model, type: type) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = DeviceNSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autosaveTableColumns = false
        table.headerView = DeviceHeaderView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        coordinator.table = table
        coordinator.installHandlers()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(entries: entries, columns: columns, selection: selection,
                                   sort: sort, reveal: reveal)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        let type: DeviceType
        weak var table: DeviceNSTableView?
        private var entries: [DeviceEntry] = []
        private var columns: [ColumnField] = []
        private var widths: [ColumnField: CGFloat] = [:]
        private var lastReveal: UUID?
        /// True while we push model state into the table, so the delegate
        /// callbacks that causes aren't mistaken for user actions.
        private var isUpdating = false

        init(model: AppModel, type: DeviceType) {
            self.model = model
            self.type = type
        }

        func installHandlers() {
            guard let table else { return }
            table.onDelete = { [weak self] in Task { await self?.model.removeSelected() } }
            table.onMove = { [weak self] direction in self?.model.moveSelected(direction) }
            table.onCopy = { [weak self] in self?.model.copyRows() }
            table.rowMenu = { [weak self] row, column in self?.makeRowMenu(row: row, column: column) }
            table.headerMenu = { [weak self] in self?.makeColumnMenu() }
            (table.headerView as? DeviceHeaderView)?.menuProvider = { [weak self] in self?.makeColumnMenu() }
        }

        // MARK: Model → table

        func update(entries newEntries: [DeviceEntry], columns newColumns: [ColumnField],
                    selection: Set<String>, sort: SortState?, reveal: RevealRequest?) {
            guard let table else { return }
            isUpdating = true
            defer { isUpdating = false }

            var needsReload = false
            if newColumns != columns {
                rebuildColumns(newColumns, in: table)
                needsReload = true
            }
            if newEntries != entries {
                entries = newEntries
                needsReload = true
            }
            if needsReload { table.reloadData() }

            let wanted = IndexSet(entries.indices.filter { selection.contains(entries[$0].id) })
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }

            let current = table.sortDescriptors.first
            if let sort {
                if current?.key != sort.field.rawValue || current?.ascending != sort.ascending {
                    table.sortDescriptors = [NSSortDescriptor(key: sort.field.rawValue, ascending: sort.ascending)]
                }
            } else if current != nil {
                table.sortDescriptors = []
            }

            if let reveal, reveal.token != lastReveal {
                lastReveal = reveal.token
                if let row = entries.firstIndex(where: { $0.id == reveal.id }) { table.scrollRowToVisible(row) }
            }
        }

        private func rebuildColumns(_ new: [ColumnField], in table: NSTableView) {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for field in new {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
                column.title = field.heading
                column.width = widths[field] ?? field.defaultWidth
                column.minWidth = 40
                column.resizingMask = .userResizingMask
                column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
                table.addTableColumn(column)
            }
            columns = new
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < entries.count,
                  let field = ColumnField(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("deviceCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? makeCell(identifier)
            cell.textField?.stringValue = entries[row].value(field)
            return cell
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Table → model

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].id : nil })
            // Written to this table's own list, never "whichever tab is showing".
            model.setSelection(ids, for: type)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let field = ColumnField(rawValue: key) else { return }
            model.sortBy(field, ascending: descriptor.ascending, type: type)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let order = table.tableColumns.compactMap { ColumnField(rawValue: $0.identifier.rawValue) }
            guard order != columns else { return }
            columns = order   // already in this order on screen; don't rebuild
            model.setColumns(order)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let field = ColumnField(rawValue: column.identifier.rawValue) else { return }
            widths[field] = column.width
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            model.performDoubleClickAction()
        }

        // MARK: Menus

        private func makeRowMenu(row: Int, column: Int) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let count = model.selection(for: type).count

            // Actions first, in a fixed order for both device types. Mobile-only
            // actions stay visible but disabled on computers so every action
            // keeps its position.
            for action in DeviceAction.allCases {
                let title = (count > 1 && action.supportsBulk) ? "\(action.label) (\(count))" : action.label
                let item = BlockMenuItem(title) { [model] in model.perform(action) }
                item.isEnabled = model.canPerform(action)
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let columns = self.columns
            if row >= 0, row < entries.count {
                let field = column >= 0 && column < columns.count ? columns[column] : (columns.first ?? .name)
                let cell = entries[row].value(field)
                let shown = cell.count <= 40 ? cell : String(cell.prefix(37)) + "…"
                let copyCell = BlockMenuItem(shown.isEmpty ? "Copy \(field.heading)" : "Copy \(field.heading) (\(shown))") { [model] in
                    model.copyText(cell, what: field.heading)
                }
                copyCell.isEnabled = !cell.isEmpty
                menu.addItem(copyCell)
            }
            let copy = NSMenu()
            copy.addItem(BlockMenuItem(count > 1 ? "Rows" : "Row") { [model] in model.copyRows() })
            copy.addItem(BlockMenuItem(count > 1 ? "Rows as CSV" : "Row as CSV") { [model] in model.copyRowsAsCSV() })
            copy.addItem(BlockMenuItem("List as CSV") { [model] in model.copyListAsCSV() })
            let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
            copyItem.submenu = copy
            menu.addItem(copyItem)
            menu.addItem(.separator())

            // Higher-impact commands live one level down.
            let advanced = NSMenu()
            advanced.autoenablesItems = false
            for command in AdvancedCommand.available(for: type) {
                let item = BlockMenuItem(command.label + (command.needsEllipsis ? "…" : "")) { [model] in
                    model.perform(command)
                }
                item.isEnabled = model.canPerform(command)
                advanced.addItem(item)
            }
            // Device-centric audits, run straight from the list.
            let audit = NSMenu()
            audit.autoenablesItems = false
            let single = row >= 0 && row < entries.count && count == 1
            for (reportID, title) in AuditReports.deviceMenu {
                let item = BlockMenuItem(title) { [model, type, entries] in
                    guard row < entries.count else { return }
                    model.audits.runDeviceReport(reportID, kind: GroupKind(type), device: entries[row])
                }
                item.isEnabled = single
                audit.addItem(item)
            }
            let auditItem = NSMenuItem(title: "Audit", action: nil, keyEquivalent: "")
            auditItem.submenu = audit
            menu.addItem(auditItem)

            let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
            advancedItem.submenu = advanced
            menu.addItem(advancedItem)
            return menu
        }

        /// Right-click on the column headers (or empty space): toggle fields on
        /// and off, arrange them, or reset.
        private func makeColumnMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let visible = Set(model.visibleColumns)
            for field in ColumnField.allCases {
                let item = BlockMenuItem(field.heading) { [model] in model.toggleColumn(field) }
                item.state = visible.contains(field) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(BlockMenuItem("Arrange Columns…") { [model] in model.showArrangeColumns() })
            menu.addItem(BlockMenuItem("Reset to Default Columns") { [model] in model.resetColumns() })
            return menu
        }
    }
}

/// An `NSMenuItem` that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void

    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { block() }
}

final class DeviceHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
}

final class DeviceNSTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    var rowMenu: ((_ row: Int, _ column: Int) -> NSMenu?)?
    var headerMenu: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        switch event.keyCode {
        case 51, 117:                // delete, forward delete
            onDelete?()
        case 126 where command:      // ⌘↑
            onMove?(-1)
        case 125 where command:      // ⌘↓
            onMove?(1)
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row < 0 { return headerMenu?() }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return rowMenu?(row, column(at: point))
    }
}

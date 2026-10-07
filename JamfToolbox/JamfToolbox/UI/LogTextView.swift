import AppKit
import SwiftUI

/// The activity log: selectable monospaced text that follows new output.
/// An `NSTextView` lets the user select across lines, which a stack of
/// SwiftUI `Text` rows can't.
struct LogTextView: NSViewRepresentable {
    @ObservedObject var log: ActivityLog
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let text = LogNSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Activity log")
        text.copyLog = { [weak model] in model?.copyLog() }
        text.clearLog = { [weak model] in model?.log.clear() }
        text.hasContent = { [weak model] in !(model?.log.lines.isEmpty ?? true) }
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(lines: log.lines, generation: log.generation)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var shown = 0
        private var generation = 0
        private let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        func sync(lines: [String], generation newGeneration: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            if newGeneration != generation || lines.count < shown {
                storage.setAttributedString(NSAttributedString())
                shown = 0
                generation = newGeneration
            }
            guard lines.count > shown else { return }
            let addition = lines[shown...].map { $0 + "\n" }.joined()
            storage.append(NSAttributedString(string: addition, attributes: attributes))
            shown = lines.count
            textView.scrollToEndOfDocument(nil)
        }
    }
}

private final class LogNSTextView: NSTextView {
    var copyLog: (() -> Void)?
    var clearLog: (() -> Void)?
    var hasContent: (() -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.isEnabled = selectedRange().length > 0
        menu.addItem(copy)
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let enabled = hasContent?() ?? false
        let copyAll = BlockMenuItem("Copy Log") { [weak self] in self?.copyLog?() }
        copyAll.isEnabled = enabled
        menu.addItem(copyAll)
        let clear = BlockMenuItem("Clear Log") { [weak self] in self?.clearLog?() }
        clear.isEnabled = enabled
        menu.addItem(clear)
        return menu
    }
}

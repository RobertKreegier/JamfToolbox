import AppKit
import SwiftUI

/// Native alerts, awaited. They attach as sheets to the front window so a
/// multi-step action can simply `await` each prompt in turn.
@MainActor
enum Dialogs {
    nonisolated static let appName = "Jamf Toolbox"

    /// The window prompts should attach to: the key window (including another
    /// sheet, so prompts stack correctly), else the main window.
    static var anchor: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    /// Shows an alert and returns the index of the pressed button.
    /// Buttons are listed default-first, as `NSAlert` expects.
    @discardableResult
    static func show(_ message: String, title: String = appName, style: NSAlert.Style = .informational,
                     buttons: [String] = ["OK"]) async -> Int {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        let response: NSApplication.ModalResponse
        if let window = anchor {
            response = await alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func info(_ message: String) async { await show(message) }
    static func warning(_ message: String) async { await show(message, style: .warning) }
    static func error(_ message: String) async { await show(message, style: .critical) }

    /// Yes/No question; true for the first button.
    static func confirm(_ message: String, yes: String = "Yes", no: String = "No") async -> Bool {
        await show(message, buttons: [yes, no]) == 0
    }

    /// Three-way choice. Returns 0 or 1 for the first two buttons, nil for Cancel.
    static func choose(_ message: String, first: String, second: String) async -> Int? {
        let index = await show(message, buttons: [first, second, "Cancel"])
        return index <= 1 ? index : nil
    }
}

/// A sheet attached to the front window, hosting SwiftUI content.
@MainActor
final class SheetHandle {
    fileprivate var window: NSWindow?

    fileprivate init() {}

    func dismiss() {
        guard let window else { return }
        self.window = nil   // also breaks the window → view → closure cycle
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

@MainActor
enum Sheets {
    /// Present `content` as a sheet and wait for it to call `done` with a result.
    /// `done` is idempotent: only the first call counts.
    static func present<Result, Content: View>(
        resizable: Bool = false,
        @ViewBuilder content: (_ done: @escaping (Result) -> Void) -> Content
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let handle = SheetHandle()
            var finished = false
            let done: (Result) -> Void = { result in
                guard !finished else { return }
                finished = true
                handle.dismiss()
                continuation.resume(returning: result)
            }
            attach(content(done), to: handle, resizable: resizable)
        }
    }

    /// Present `content` as a sheet the caller dismisses itself (e.g. a progress sheet).
    static func show<Content: View>(@ViewBuilder content: () -> Content) -> SheetHandle {
        let handle = SheetHandle()
        attach(content(), to: handle, resizable: false)
        return handle
    }

    private static func attach<Content: View>(_ view: Content, to handle: SheetHandle, resizable: Bool) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = resizable ? [.titled, .resizable] : [.titled]
        handle.window = window
        if let parent = Dialogs.anchor {
            parent.beginSheet(window, completionHandler: nil)
        } else {
            // No window to attach to: fall back to a plain floating window.
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Free-standing (non-modal) windows for things like device info, which the
/// user keeps open beside the main list.
@MainActor
enum Windows {
    private static var open: [NSWindow] = []

    @discardableResult
    static func show<Content: View>(title: String, size: CGSize, minSize: CGSize? = nil, resizable: Bool = true,
                                    @ViewBuilder content: () -> Content) -> NSWindow {
        let host = NSHostingController(rootView: content())
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        if let minSize { window.contentMinSize = minSize }
        window.center()
        // Stagger so several windows opened in a row don't hide each other.
        let offset = CGFloat(open.count % 6) * 26
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + offset,
                                            y: window.frame.maxY - offset))
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { note in
            guard let closing = note.object as? NSWindow else { return }
            Task { @MainActor in open.removeAll { $0 === closing } }
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

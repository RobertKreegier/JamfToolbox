import Foundation

/// The activity log and status line. Kept separate from `AppModel` so a new
/// log line redraws only the log and status bar, not the device table.
@MainActor
public final class ActivityLog: ObservableObject {
    @Published public private(set) var lines: [String] = []
    /// Bumped on clear so the text view knows to start over rather than append.
    @Published public private(set) var generation = 0
    @Published public var status = "Ready"
    @Published public private(set) var busyCount = 0

    public var isBusy: Bool { busyCount > 0 }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public func add(_ message: String) {
        lines.append("[\(Self.stamp.string(from: Date()))] \(message)")
    }

    public func clear() {
        lines.removeAll()
        generation += 1
        status = "Activity log cleared."
    }

    public var text: String { lines.joined(separator: "\n") }

    public func beginBusy(_ message: String) {
        busyCount += 1
        status = message
    }

    public func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 { status = "Ready" }
    }
}

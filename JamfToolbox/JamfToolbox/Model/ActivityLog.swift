import Foundation

/// The activity log and status line. Kept separate from `AppModel` so a new
/// log line redraws only the log and status bar, not the device table.
@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var lines: [String] = []
    /// Bumped on clear so the text view knows to start over rather than append.
    @Published private(set) var generation = 0
    @Published var status = "Ready"
    @Published private(set) var busyCount = 0

    var isBusy: Bool { busyCount > 0 }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ message: String) {
        lines.append("[\(Self.stamp.string(from: Date()))] \(message)")
    }

    func clear() {
        lines.removeAll()
        generation += 1
        status = "Activity log cleared."
    }

    var text: String { lines.joined(separator: "\n") }

    func beginBusy(_ message: String) {
        busyCount += 1
        status = message
    }

    func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 { status = "Ready" }
    }
}

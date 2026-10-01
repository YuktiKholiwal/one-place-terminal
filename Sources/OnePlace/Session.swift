import Foundation

/// One terminal session == one TTY (a tab or pane in any terminal app).
struct Session: Identifiable, Equatable, Sendable {
    var id: String { tty }

    let tty: String           // "ttys009"
    let shellPID: Int32       // the session-leader shell
    var shellName: String     // "zsh"

    var foregroundPID: Int32? // nil == sitting at a prompt
    var command: String?      // "claude", "npm run dev"
    var cwd: String?          // "/Users/recursive/chess"
    var port: Int?            // a listening port owned by this session

    // Absolute start times, not elapsed durations. An elapsed value drifts every
    // second, so two otherwise-identical scans never compare equal and the UI
    // re-renders once a second forever. Age is derived at display time instead.
    var startDate: Date
    var commandStartDate: Date?

    /// Set from Claude Code hook state; false until hooks are installed.
    var needsAttention: Bool = false

    var age: TimeInterval { Date().timeIntervalSince(startDate) }
    var commandAge: TimeInterval? { commandStartDate.map { Date().timeIntervalSince($0) } }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// A session with an open listening port is doing real work, however old.
    var isServing: Bool { port != nil }

    /// Stored, not computed. A computed state would be evaluated against the
    /// current clock on both sides of an equality check, so a session crossing
    /// the stale threshold would never register as a change and the list would
    /// not regroup. The scanner sets this once per scan.
    var state: State = .idle

    /// Derives the state for the moment `now`.
    func derivedState(now: Date = Date()) -> State {
        if needsAttention { return .waiting }
        if isServing { return .running }
        let shellAge = now.timeIntervalSince(startDate)
        if let start = commandStartDate {
            return now.timeIntervalSince(start) > Session.staleAfter ? .stale : .running
        }
        return shellAge > Session.staleAfter ? .stale : .idle
    }

    static let staleAfter: TimeInterval = 8 * 3600

    enum State: Int, CaseIterable, Sendable {
        case waiting, running, idle, stale

        var title: String {
            switch self {
            case .waiting: "Waiting on you"
            case .running: "Running"
            case .idle:    "Idle"
            case .stale:   "Stale"
            }
        }
        /// Sort order in the popover — most urgent first.
        var rank: Int { rawValue }
    }
}

// MARK: - Duration formatting

extension TimeInterval {
    /// Compact age: 3d, 19h, 11m, 6s
    var compactAge: String {
        let s = Int(self)
        if s >= 86400 { return "\(s / 86400)d" }
        if s >= 3600  { return "\(s / 3600)h" }
        if s >= 60    { return "\(s / 60)m" }
        return "\(s)s"
    }
}

/// Parses the `ps` ELAPSED column: "MM:SS", "HH:MM:SS", or "D-HH:MM:SS".
func parseElapsed(_ raw: String) -> TimeInterval {
    var days = 0
    var rest = raw
    if let dash = raw.firstIndex(of: "-") {
        days = Int(raw[raw.startIndex..<dash]) ?? 0
        rest = String(raw[raw.index(after: dash)...])
    }
    let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
    var seconds = 0
    switch parts.count {
    case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
    case 2: seconds = parts[0] * 60 + parts[1]
    case 1: seconds = parts[0]
    default: break
    }
    return TimeInterval(days * 86400 + seconds)
}

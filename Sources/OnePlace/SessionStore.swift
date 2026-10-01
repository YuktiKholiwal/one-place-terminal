import Foundation
import Observation
import Darwin

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [Session] = []
    private(set) var lastScanMicros: Int = 0
    private(set) var isLoaded = false

    /// Row the user has armed for kill — a second click confirms.
    var pendingKill: String?
    /// Rows currently being terminated, so they can be shown as dimmed.
    private(set) var killing: Set<String> = []

    private var timer: Timer?
    private let scanner = SessionScanner()

    /// Which agent each live session is running, keyed by tty.
    private(set) var agents: [String: ResolvedAgent] = [:]

    /// The snapshot as it was when the app launched — the pre-crash picture.
    /// Held in memory so later writes cannot take the recovery data away.
    private(set) var recovery: Snapshot?
    /// Entries the user has already restored this run, so they stop being offered.
    private var restored: Set<String> = []

    init() {
        recovery = Snapshot.load()
    }

    /// Renders a fixed set of sessions — used to preview the UI offscreen.
    init(preview sessions: [Session], scanMicros: Int = 820,
         recovery: Snapshot? = nil, agents: [String: ResolvedAgent] = [:]) {
        self.sessions = sessions
        self.lastScanMicros = scanMicros
        self.isLoaded = true
        self.recovery = recovery
        self.agents = agents
    }

    /// Cadence while the popover is on screen — fast enough to feel live.
    static let activeInterval: TimeInterval = 1.0
    /// Cadence while it is closed. Nothing is visible but the badge, and
    /// sessions do not change state second to second, so most of the polling
    /// cost is simply avoided.
    static let idleInterval: TimeInterval = 5.0

    private var interval: TimeInterval = SessionStore.idleInterval

    func start(interval: TimeInterval? = nil) {
        self.interval = interval ?? Self.idleInterval
        schedule()
        refresh()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Called as the popover opens and closes.
    func setActive(_ active: Bool) {
        let wanted = active ? Self.activeInterval : Self.idleInterval
        guard wanted != interval else { return }
        interval = wanted
        schedule()
        if active { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { [scanner] in
            let began = DispatchTime.now().uptimeNanoseconds
            let found = await scanner.scan()
            let micros = (DispatchTime.now().uptimeNanoseconds - began) / 1_000
            // While the popover is open, publish every scan so the displayed
            // ages keep ticking. While it is closed, publish only on a real
            // change, so the menu bar item is not re-rendered for nothing.
            let changed = found != self.sessions
            // Record the arrangement whenever it actually changes, so a crash
            // never costs more than the last change.
            if changed {
                let resolved = SessionIdentity.resolve(
                    sessions: found,
                    hookSessionIDs: HookState.load().compactMapValues(\.sessionID))
                self.agents = resolved
                Snapshot.build(from: found, agents: resolved).write()
            }
            if changed || self.interval == Self.activeInterval {
                self.sessions = found
                self.lastScanMicros = Int(micros)
            }
            if !self.isLoaded { self.isLoaded = true; self.lastScanMicros = Int(micros) }
            // Drop a pending confirm if that session vanished.
            if let p = self.pendingKill, !found.contains(where: { $0.id == p }) {
                self.pendingKill = nil
            }
        }
    }

    // MARK: - Counts

    func count(_ state: Session.State) -> Int {
        sessions.lazy.filter { $0.state == state }.count
    }

    var attentionCount: Int { count(.waiting) }

    var grouped: [(state: Session.State, items: [Session])] {
        Session.State.allCases.compactMap { state in
            let items = sessions.filter { $0.state == state }
            return items.isEmpty ? nil : (state, items)
        }
    }

    // MARK: - Recovery

    /// Identity that survives a restart. Ttys are reassigned when terminals are
    /// recreated, so a session is recognised by its conversation id where there
    /// is one, and by folder plus command otherwise.
    private func key(cwd: String?, command: String?, sessionID: String?) -> String {
        if let sessionID, !sessionID.isEmpty { return "sid:" + sessionID }
        return "loc:\(cwd ?? "")|\(command ?? "")"
    }

    /// Recorded sessions that are not running now — what a crash cost you.
    var restorable: [Snapshot.Entry] {
        guard let recovery else { return [] }
        let live = Set(sessions.map {
            key(cwd: $0.cwd, command: $0.command, sessionID: agents[$0.tty]?.sessionID)
        })
        return recovery.sessions.filter { entry in
            guard entry.restore != nil else { return false }
            let k = key(cwd: entry.cwd, command: entry.command, sessionID: entry.sessionID)
            return !live.contains(k) && !restored.contains(k)
        }
    }

    var recoveryDate: Date? { recovery?.savedAt }

    /// Recreates terminals for the given entries via the VS Code extension.
    @discardableResult
    func restore(_ entries: [Snapshot.Entry]) -> Bool {
        guard !entries.isEmpty else { return false }
        let ok = FocusClient.restore(entries)
        if ok {
            for e in entries {
                restored.insert(key(cwd: e.cwd, command: e.command, sessionID: e.sessionID))
            }
        }
        return ok
    }

    func dismissRecovery() {
        recovery = nil
    }

    // MARK: - Actions

    /// Ends the whole session — its running command and its shell — which
    /// closes the terminal tab.
    func kill(_ session: Session) {
        pendingKill = nil
        killing.insert(session.id)
        ProcessControl.endSession(shellPID: session.shellPID, tty: session.tty) { [weak self] in
            Task { @MainActor in
                self?.killing.remove(session.id)
                self?.refresh()
            }
        }
    }

    /// Click-to-focus: asks the VS Code extension to reveal this terminal.
    /// Falls back to opening the folder when the extension is not installed.
    func focus(_ session: Session) {
        if FocusClient.focus(shellPID: session.shellPID) { return }
        reveal(session)
    }

    /// Opens the session's working directory.
    func reveal(_ session: Session) {
        guard let cwd = session.cwd else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [cwd]
        try? p.run()
    }
}

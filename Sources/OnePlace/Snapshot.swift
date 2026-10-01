import Foundation

/// A durable record of what was open, so a crash costs you the arrangement of
/// your sessions rather than the work of rebuilding it.
///
/// The conversations themselves are never at risk — Claude Code appends each one
/// to `~/.claude/projects/.../<session-id>.jsonl` as it goes. What is easy to
/// lose is *which* sessions were open, in which folders, under which ids. That
/// is what this records.
struct Snapshot: Codable {
    var savedAt: Date
    var sessions: [Entry]

    struct Entry: Codable {
        var tty: String
        var project: String
        var cwd: String
        var command: String?
        /// Which agent this is, when it is one: "Claude Code", "fx", …
        var agent: String?
        var sessionID: String?
        var title: String?
        /// The command that puts this session back. Empty for an idle shell:
        /// the working directory is the whole story there.
        var restore: String?
        var port: Int?
        var state: String
    }

    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/OnePlaceTerminal")
    static var current: URL { directory.appending(path: "snapshot.json") }
    static var historyDirectory: URL { directory.appending(path: "history") }

    /// Snapshots kept behind the current one. A crash can happen just after you
    /// close things, so the most recent state is not always the one you want.
    static let historyLimit = 24

    static func build(from sessions: [Session], agents: [String: ResolvedAgent]) -> Snapshot {
        Snapshot(savedAt: Date(), sessions: sessions.map { s in
            let agent = agents[s.tty]
            let restore: String?
            if let r = agent?.resume { restore = r }
            else if let c = s.command, c != "zsh" { restore = c }
            else { restore = nil }
            return Entry(tty: s.tty, project: s.project, cwd: s.cwd ?? "",
                         command: s.command, agent: agent?.agent,
                         sessionID: agent?.sessionID, title: agent?.title,
                         restore: restore, port: s.port,
                         state: String(describing: s.state))
        })
    }

    /// Reads the snapshot left by a previous run.
    static func load(from url: URL? = nil) -> Snapshot? {
        guard let data = try? Data(contentsOf: url ?? current) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// Writes atomically, so a crash mid-write cannot corrupt the snapshot.
    ///
    /// Refuses to replace a populated snapshot with an empty one. After a crash
    /// the app restarts with nothing running, and writing that straight out
    /// would erase the very record needed to recover.
    func write() {
        if sessions.isEmpty, let existing = Snapshot.load(), !existing.sessions.isEmpty {
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.historyDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }

        try? data.write(to: Self.current, options: .atomic)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = stamp.string(from: savedAt).replacingOccurrences(of: ":", with: "")
        try? data.write(to: Self.historyDirectory.appending(path: "\(name).json"), options: .atomic)
        pruneHistory()
    }

    private func pruneHistory() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.historyDirectory.path) else { return }
        let sorted = names.filter { $0.hasSuffix(".json") }.sorted()
        guard sorted.count > Self.historyLimit else { return }
        for name in sorted.prefix(sorted.count - Self.historyLimit) {
            try? fm.removeItem(at: Self.historyDirectory.appending(path: name))
        }
    }
}

import Foundation

/// One resumable conversation belonging to some agent.
struct AgentSession {
    let id: String
    let created: Date
    let modified: Date
    var title: String?
}

/// How to find and resume one agent's conversations.
///
/// Each agent stores sessions differently, so the lookup is per-adapter, but
/// the matching is shared: a running process is paired with the session whose
/// creation time is closest to when the process started.
protocol AgentAdapter: Sendable {
    /// The process name as it appears in the terminal.
    var process: String { get }
    var displayName: String { get }
    /// Conversations recorded for this working directory.
    func sessions(forCwd cwd: String) -> [AgentSession]
    func resumeCommand(id: String) -> String
    /// How far a session's creation time may sit from the process start.
    var tolerance: TimeInterval { get }
}

extension AgentAdapter {
    var tolerance: TimeInterval { 240 }
}

// MARK: - Claude Code

/// Transcripts live at ~/.claude/projects/<cwd with / replaced by ->/<uuid>.jsonl
/// and are created when the session begins, so the file's birth time identifies
/// the session. Verified against 7 live sessions: all matched, no collisions.
struct ClaudeAdapter: AgentAdapter {
    let process = "claude"
    let displayName = "Claude Code"

    func sessions(forCwd cwd: String) -> [AgentSession] {
        let root = home.appending(path: ".claude/projects")
        let dashed = cwd.replacingOccurrences(of: "/", with: "-")
        for candidate in [dashed, dashed.replacingOccurrences(of: ".", with: "-")] {
            let dir = root.appending(path: candidate)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            let found = names.filter { $0.hasSuffix(".jsonl") }.compactMap { name -> AgentSession? in
                guard let t = fileTimes(dir.appending(path: name).path) else { return nil }
                return AgentSession(id: String(name.dropLast(6)), created: t.birth, modified: t.modified)
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    func resumeCommand(id: String) -> String { "claude --resume \(id)" }
}

// MARK: - fx

/// fx keeps an index at ~/.fx/sessions/index.json carrying workspace_root and
/// created_at_ms for every session, so no filesystem timestamps are needed.
struct FXAdapter: AgentAdapter {
    let process = "fx"
    let displayName = "fx"

    func sessions(forCwd cwd: String) -> [AgentSession] {
        let index = home.appending(path: ".fx/sessions/index.json")
        guard let data = try? Data(contentsOf: index),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["sessions"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let workspace = (row["workspace_root"] ?? row["origin_workspace_root"]) as? String,
                  workspace == cwd
            else { return nil }
            let created = millis(row["created_at_ms"])
            let updated = millis(row["updated_at_ms"]) ?? created
            guard let created else { return nil }
            var title = row["title"] as? String
            if title == "Untitled session" { title = nil }
            return AgentSession(id: id, created: created, modified: updated ?? created, title: title)
        }
    }

    func resumeCommand(id: String) -> String { "fx session resume \(id)" }

    /// created_at_ms appears as either a string or a number depending on version.
    private func millis(_ value: Any?) -> Date? {
        let ms: Double?
        switch value {
        case let s as String: ms = Double(s)
        case let n as NSNumber: ms = n.doubleValue
        default: ms = nil
        }
        return ms.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

// MARK: - Codex

/// Rollouts live at ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl,
/// filed by date rather than by project — so unlike the other agents, the
/// working directory has to be read out of each file. It is in the first
/// record as `payload.cwd`.
///
/// Not verified end to end: the codex install on this machine is missing its
/// vendored binary, so the resume syntax could not be confirmed against the CLI.
struct CodexAdapter: AgentAdapter {
    let process = "codex"
    let displayName = "Codex"

    /// path -> (modified, cwd). Rollout headers never change, so this only ever
    /// grows as new sessions appear.
    private static let cache = CWDCache()

    func sessions(forCwd cwd: String) -> [AgentSession] {
        let root = home.appending(path: ".codex/sessions")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [AgentSession] = []
        for case let rel as String in walker where rel.hasSuffix(".jsonl") {
            let name = (rel as NSString).lastPathComponent
            // rollout-2025-11-19T23-44-35-<uuid>.jsonl
            guard name.hasPrefix("rollout-") else { continue }
            let path = root.appending(path: rel).path
            guard let t = fileTimes(path),
                  Self.cache.cwd(of: path) == cwd
            else { continue }
            let stem = String(name.dropFirst(8).dropLast(6))
            let parts = stem.split(separator: "-")
            guard parts.count >= 5 else { continue }
            out.append(AgentSession(id: parts.suffix(5).joined(separator: "-"),
                                    created: t.birth, modified: t.modified))
        }
        return out
    }

    func resumeCommand(id: String) -> String { "codex resume \(id)" }
}

/// Remembers the working directory recorded in each rollout header, so the
/// files are only read once.
final class CWDCache: @unchecked Sendable {
    private var store: [String: String?] = [:]
    private let lock = NSLock()

    func cwd(of path: String) -> String? {
        lock.lock()
        if let hit = store[path] { lock.unlock(); return hit }
        lock.unlock()

        let value = Self.readCWD(path)
        lock.lock(); store[path] = value; lock.unlock()
        return value
    }

    /// Reads only the first record: rollout files run to many megabytes, but
    /// that record is not small either — newer codex versions inline the full
    /// base instructions, pushing it past 16 KB — so read until the line
    /// actually ends rather than guessing a size.
    private static func readCWD(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 64 * 1024
        let cap = 4 * 1024 * 1024
        while buffer.count < cap {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return cwd(inLine: buffer[buffer.startIndex..<newline])
            }
        }
        return buffer.isEmpty ? nil : cwd(inLine: buffer)
    }

    private static func cwd(inLine line: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        if let payload = root["payload"] as? [String: Any], let c = payload["cwd"] as? String {
            return c
        }
        return root["cwd"] as? String
    }
}

// MARK: - Gemini

/// Gemini resumes by position (`--resume <index>`), not by id, and the index is
/// relative to the current project. That makes a recorded index go stale as soon
/// as new sessions are added, so `latest` is the honest default.
struct GeminiAdapter: AgentAdapter {
    let process = "gemini"
    let displayName = "Gemini CLI"

    func sessions(forCwd cwd: String) -> [AgentSession] { [] }
    func resumeCommand(id: String) -> String { "gemini --resume latest" }
}

// MARK: - Registry

enum AgentRegistry {
    /// Order matters only for display; lookup is by process name.
    static let all: [any AgentAdapter] = [
        ClaudeAdapter(), FXAdapter(), CodexAdapter(), GeminiAdapter(),
    ]

    static func adapter(forCommand command: String?) -> (any AgentAdapter)? {
        guard let command else { return nil }
        // A command may carry arguments ("claude --model ...").
        let head = command.split(separator: " ").first.map(String.init) ?? command
        return all.first { $0.process == head }
    }

    static func isAgent(_ command: String?) -> Bool { adapter(forCommand: command) != nil }
}

// MARK: - Shared helpers

private let home = FileManager.default.homeDirectoryForCurrentUser

private func fileTimes(_ path: String) -> (birth: Date, modified: Date)? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return (Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec)),
            Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)))
}

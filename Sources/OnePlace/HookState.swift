import Foundation

/// State reported by Claude Code hooks, one small file per session.
///
/// The process table cannot tell a Claude that is thinking from one that is
/// waiting for your reply — both are just a running `claude`. The hooks supply
/// that distinction; without them every Claude session reads as "running".
struct HookState {
    enum Activity: String {
        case notification   = "Notification"     // asking for permission or input
        case stop           = "Stop"             // finished its turn: your move
        case userPrompt     = "UserPromptSubmit" // you replied: working again
        case sessionStart   = "SessionStart"
        case sessionEnd     = "SessionEnd"

        var needsAttention: Bool { self == .notification || self == .stop }
    }

    let activity: Activity
    let pid: Int32
    let cwd: String
    let timestamp: Date
    /// The Claude session id, reported exactly by the hook.
    let sessionID: String?

    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/OnePlaceTerminal/state")

    /// Hook files older than this are ignored: a crashed session can leave one behind.
    static let maxAge: TimeInterval = 24 * 3600

    static func load() -> [Int32: HookState] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [:] }

        var result: [Int32: HookState] = [:]
        let now = Date()
        for name in names {
            guard let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8)
            else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 4,
                  let activity = Activity(rawValue: lines[0]),
                  let pid = Int32(lines[1]),
                  let epoch = TimeInterval(lines[3])
            else { continue }
            let stamp = Date(timeIntervalSince1970: epoch)
            guard now.timeIntervalSince(stamp) < maxAge else { continue }
            let sid = lines.count >= 5 && !lines[4].isEmpty ? lines[4] : nil
            result[pid] = HookState(activity: activity, pid: pid, cwd: lines[2],
                                    timestamp: stamp, sessionID: sid)
        }
        return result
    }

    /// Removes files whose process is gone, so the directory does not grow forever.
    static func prune(livePIDs: Set<Int32>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names {
            guard let pid = Int32(name), !livePIDs.contains(pid) else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

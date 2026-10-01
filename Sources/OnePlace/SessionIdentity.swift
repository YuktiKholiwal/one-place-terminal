import Foundation

/// What a terminal session turned out to be running, and how to bring it back.
struct ResolvedAgent: Equatable, Sendable {
    var agent: String          // "Claude Code", "fx", …
    var process: String        // "claude", "fx", …
    var sessionID: String?
    var resume: String?
    var title: String?
}

/// Pairs each running agent process with the conversation it is running.
///
/// No agent exposes its session id through the process itself, but they all
/// record a conversation when one starts. So a process is matched to the
/// session whose creation time sits closest to when the process started —
/// measured against live Claude sessions, the gap ran from 3 to 100 seconds,
/// which separates even several sessions in one folder.
///
/// Matching is greedy from the oldest process, so two processes can never claim
/// the same conversation. When Claude Code hooks are installed they report the
/// id exactly, and that always wins over inference.
enum SessionIdentity {

    static func resolve(sessions: [Session], hookSessionIDs: [Int32: String]) -> [String: ResolvedAgent] {
        var result: [String: ResolvedAgent] = [:]
        var claimed: Set<String> = []

        // Exact ids first, so inference cannot take a conversation from them.
        for session in sessions {
            guard let pid = session.foregroundPID,
                  let sid = hookSessionIDs[pid],
                  let adapter = AgentRegistry.adapter(forCommand: session.command)
            else { continue }
            result[session.tty] = ResolvedAgent(
                agent: adapter.displayName, process: adapter.process,
                sessionID: sid, resume: adapter.resumeCommand(id: sid), title: nil)
            claimed.insert(sid)
        }

        // Oldest process first: it should get the oldest unclaimed conversation.
        let remaining = sessions
            .filter { result[$0.tty] == nil && AgentRegistry.isAgent($0.command) }
            .sorted { ($0.commandStartDate ?? $0.startDate) < ($1.commandStartDate ?? $1.startDate) }

        for session in remaining {
            guard let adapter = AgentRegistry.adapter(forCommand: session.command) else { continue }
            guard let cwd = session.cwd else { continue }
            let started = session.commandStartDate ?? session.startDate

            let available = adapter.sessions(forCwd: cwd).filter { !claimed.contains($0.id) }
            guard !available.isEmpty else {
                // Known agent, no conversation found — still worth recording, so
                // restore can at least reopen the folder and start the agent.
                result[session.tty] = ResolvedAgent(
                    agent: adapter.displayName, process: adapter.process,
                    sessionID: nil, resume: adapter.process, title: nil)
                continue
            }

            let byCreation = available
                .map { (abs($0.created.timeIntervalSince(started)), $0) }
                .filter { $0.0 <= adapter.tolerance }
                .sorted { $0.0 < $1.0 }

            // A resumed conversation keeps its original creation time, so fall
            // back to whichever has been written to most recently.
            let pick = byCreation.first?.1
                ?? available.sorted { $0.modified > $1.modified }.first

            if let pick {
                claimed.insert(pick.id)
                result[session.tty] = ResolvedAgent(
                    agent: adapter.displayName, process: adapter.process,
                    sessionID: pick.id, resume: adapter.resumeCommand(id: pick.id),
                    title: pick.title)
            }
        }
        return result
    }
}

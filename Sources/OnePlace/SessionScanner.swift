import Darwin
import Foundation

/// Discovers terminal sessions by reading the kernel process table directly.
///
/// Spawns nothing. `ps` + `lsof` via Foundation's `Process` cost ~320ms per scan
/// (75ms of that is spawn overhead *per subprocess*); going straight to
/// `sysctl` + `libproc` — which is what those tools do internally — costs ~1.3ms.
/// `kp_proc.p_stat` for a process that has exited but not yet been reaped.
let SZOMB: Int8 = 5

actor SessionScanner {

    /// dev_t -> "ttys004". Cached: rebuilt only when an unknown device appears,
    /// which happens when a new tab is opened.
    private var ttyMap: [dev_t: String] = [:]

    func scan() -> [Session] {
        let procs = kernelProcesses()
        guard !procs.isEmpty else { return [] }

        if ttyMap.isEmpty { ttyMap = buildTTYMap() }

        // Anything attached to a ttys* device is part of a terminal session.
        var onTTY: [(proc: kinfo_proc, tty: String)] = []
        var sawUnknownDevice = false
        for p in procs {
            let dev = p.kp_eproc.e_tdev
            // Skip zombies: a killed shell lingers in the table until its parent
            // reaps it, and would otherwise show as a live session.
            guard dev != 0, dev != dev_t.max, p.kp_proc.p_stat != SZOMB else { continue }
            if let name = ttyMap[dev] {
                if name.hasPrefix("ttys") { onTTY.append((p, name)) }
            } else {
                sawUnknownDevice = true
            }
        }
        if sawUnknownDevice {
            ttyMap = buildTTYMap()
            for p in procs {
                let dev = p.kp_eproc.e_tdev
                guard dev != 0, dev != dev_t.max, let name = ttyMap[dev],
                      name.hasPrefix("ttys"),
                      !onTTY.contains(where: { $0.proc.kp_proc.p_pid == p.kp_proc.p_pid })
                else { continue }
                onTTY.append((p, name))
            }
        }
        guard !onTTY.isEmpty else { return [] }

        // The session leader owns the TTY — one leader per tab or pane. It is
        // the process on this TTY whose parent is *not*: the parent is the
        // terminal application, which has no controlling terminal of its own.
        let pidsOnTTY = Set(onTTY.map { $0.proc.kp_proc.p_pid })
        var sessions: [String: Session] = [:]
        for (p, tty) in onTTY where !pidsOnTTY.contains(p.kp_eproc.e_ppid) {
            sessions[tty] = Session(
                tty: tty,
                shellPID: p.kp_proc.p_pid,
                shellName: basename(commandLine(p.kp_proc.p_pid) ?? "sh"),
                cwd: cwdOf(p.kp_proc.p_pid),
                startDate: startDate(p)
            )
        }
        guard !sessions.isEmpty else { return [] }

        // The foreground command is the direct child of the shell whose process
        // group is the terminal's foreground group (what `ps` marks with "+").
        // Taking the direct child rather than the deepest descendant yields what
        // was actually typed — "npm run dev", not "next-server (v16.3.4)".
        for (p, tty) in onTTY {
            guard var s = sessions[tty],
                  p.kp_eproc.e_ppid == s.shellPID,
                  p.kp_eproc.e_pgid == p.kp_eproc.e_tpgid,
                  let full = commandLine(p.kp_proc.p_pid)
            else { continue }
            s.foregroundPID = p.kp_proc.p_pid
            s.command = prettyCommand(full)
            s.commandStartDate = startDate(p)
            sessions[tty] = s
        }

        // Attribute listening ports by walking each session's descendants.
        let parentOf = Dictionary(
            onTTY.map { ($0.proc.kp_proc.p_pid, $0.proc.kp_eproc.e_ppid) },
            uniquingKeysWith: { a, _ in a }
        )
        let shellToTTY = Dictionary(uniqueKeysWithValues: sessions.values.map { ($0.shellPID, $0.tty) })
        for (p, _) in onTTY {
            let pid = p.kp_proc.p_pid
            guard let port = listeningPort(pid) else { continue }
            var cur = pid
            for _ in 0..<12 {
                if let tty = shellToTTY[cur] {
                    if var s = sessions[tty], s.port == nil { s.port = port; sessions[tty] = s }
                    break
                }
                guard let up = parentOf[cur], up > 1 else { break }
                cur = up
            }
        }

        // Overlay Claude Code hook state. The recorded pid is the `claude`
        // process itself, so it usually matches a session's foreground pid
        // directly; the parent walk covers the case where a hook ran one level
        // deeper. Matching on pid rather than cwd is what keeps six sessions in
        // the same folder distinguishable.
        let hooks = HookState.load()
        if !hooks.isEmpty {
            let fgToTTY = Dictionary(
                sessions.values.compactMap { s in s.foregroundPID.map { ($0, s.tty) } },
                uniquingKeysWith: { a, _ in a }
            )
            for (pid, hook) in hooks {
                var cur = pid
                for _ in 0..<12 {
                    if let tty = fgToTTY[cur] ?? shellToTTY[cur] {
                        if var s = sessions[tty] {
                            s.needsAttention = hook.activity.needsAttention
                            sessions[tty] = s
                        }
                        break
                    }
                    guard let up = parentOf[cur], up > 1 else { break }
                    cur = up
                }
            }
            HookState.prune(livePIDs: Set(onTTY.map { $0.proc.kp_proc.p_pid }))
        }

        let now = Date()
        return sessions.values
            .map { var s = $0; s.state = s.derivedState(now: now); return s }
            .sorted { ($0.state.rank, $0.project, $0.tty) < ($1.state.rank, $1.project, $1.tty) }
    }

    // MARK: - Kernel queries

    /// One pass over /dev beats calling `devname()` per process — that costs
    /// ~0.5ms a call, which came to 366ms across 650 processes.
    private func buildTTYMap() -> [dev_t: String] {
        var map: [dev_t: String] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return map }
        for n in names where n.hasPrefix("ttys") {
            var st = stat()
            if stat("/dev/" + n, &st) == 0 { map[st.st_rdev] = n }
        }
        return map
    }

    private func startDate(_ p: kinfo_proc) -> Date {
        let tv = p.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private func cwdOf(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, sz)
        }
        guard r == sz else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Full argv. `kp_proc.p_comm` is capped at 16 bytes and unreliable — for a
    /// Claude session it reads "2.1.261", the version string.
    private func commandLine(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buf, MemoryLayout<Int32>.size)
        guard argc > 0 else { return nil }
        var idx = MemoryLayout<Int32>.size

        func nextCString() -> String? {
            guard idx < size else { return nil }
            let start = idx
            while idx < size && buf[idx] != 0 { idx += 1 }
            defer { idx += 1 }
            guard idx > start else { return "" }
            return buf[start..<idx].withUnsafeBufferPointer {
                $0.baseAddress.flatMap { String(cString: $0) }
            }
        }

        _ = nextCString()                                 // exec path
        while idx < size && buf[idx] == 0 { idx += 1 }    // padding before argv[0]

        var args: [String] = []
        for _ in 0..<argc {
            guard let a = nextCString() else { break }
            args.append(a)
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    // MARK: - Listening sockets

    private let PROX_FDTYPE_SOCKET: Int32 = 2
    private let SOCKINFO_TCP: Int32 = 2
    private let TSI_S_LISTEN: Int32 = 1

    private func listeningPort(_ pid: Int32) -> Int? {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return nil }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard got > 0 else { return nil }

        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz,
                  si.psi.soi_kind == SOCKINFO_TCP,
                  si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded:
                si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { return port }
        }
        return nil
    }

    // MARK: - Display

    private func basename(_ command: String) -> String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    /// "/bin/zsh -il" -> "zsh";  "npm run dev" kept whole;  long paths collapsed.
    private func prettyCommand(_ raw: String) -> String {
        // npm pads its process title with trailing spaces; trim before measuring.
        let full = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = full.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return full }
        let base = (String(first) as NSString).lastPathComponent
        if ["zsh", "bash", "fish", "sh"].contains(base) { return base }
        if parts.count > 1 {
            let args = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if args.count <= 24 && !args.hasPrefix("/") && !args.hasPrefix("-") {
                return "\(base) \(args)"
            }
        }
        return base
    }
}

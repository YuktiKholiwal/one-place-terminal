import Darwin
import Foundation

/// Reads the kernel process table. Shared by the scanner and by session control.
func kernelProcesses() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    // Pad: processes can appear between the sizing call and the read.
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = buf.count * stride
    guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
    return Array(buf.prefix(size / stride))
}

enum ProcessControl {

    /// Ends a terminal session.
    ///
    /// Two things make the obvious `kill(shellPID, SIGTERM)` a no-op:
    ///
    /// 1. **Interactive shells ignore SIGTERM and SIGHUP.** That is deliberate —
    ///    it is why Ctrl-C does not kill your shell — and it is why the first
    ///    version of this button appeared to do nothing at all. Only SIGKILL
    ///    ends an interactive zsh.
    /// 2. **Signalling the shell alone orphans its children.** A stale session
    ///    is stale precisely because something like `claude` is still running in
    ///    it; killing only the shell would leave that process alive with no
    ///    terminal attached.
    ///
    /// So the children are asked to exit first (they honour SIGTERM), then the
    /// shell is killed outright.
    static func endSession(shellPID: Int32, tty: String, completion: @escaping @Sendable () -> Void) {
        let children = membersOfTTY(tty).filter { $0 != shellPID }
        for pid in children { _ = Darwin.kill(pid, SIGTERM) }

        // Give them a moment to exit cleanly, then stop being polite.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
            for pid in membersOfTTY(tty) where pid != shellPID {
                _ = Darwin.kill(pid, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completion() }
        }
    }

    /// Live pids attached to a TTY, read fresh rather than taken from the last
    /// scan, which can be up to the idle poll interval old.
    private static func membersOfTTY(_ tty: String) -> [Int32] {
        var wanted: dev_t?
        var st = stat()
        if stat("/dev/" + tty, &st) == 0 { wanted = st.st_rdev }
        guard let dev = wanted else { return [] }
        return kernelProcesses()
            .filter { $0.kp_eproc.e_tdev == dev }
            .map { $0.kp_proc.p_pid }
    }
}

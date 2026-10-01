import Darwin
import Foundation
import AppKit

/// Asks the VS Code companion extension to reveal a terminal by its shell pid.
///
/// Every VS Code window binds its own socket, so we try each in turn until one
/// reports that it owns that terminal.
enum FocusClient {

    static let socketDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/OnePlaceTerminal/focus")

    /// True when at least one VS Code window has the extension loaded.
    static var isAvailable: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory.path)
        else { return false }
        return names.contains { $0.hasSuffix(".sock") }
    }

    /// Returns true if some window claimed the terminal.
    @discardableResult
    static func focus(shellPID: Int32) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory.path)
        else { return false }

        var claimed = false
        for name in names where name.hasSuffix(".sock") {
            let reply = send("\(shellPID)", to: socketDirectory.appending(path: name).path)
            if reply?.hasPrefix("ok") == true { claimed = true; break }
        }
        if claimed {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.microsoft.VSCode" }?
                .activate(options: [])
        }
        return claimed
    }

    /// Asks a VS Code window to recreate these sessions as terminals.
    /// Creating a dozen terminals takes a moment, so this waits longer.
    @discardableResult
    static func restore(_ entries: [Snapshot.Entry]) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory.path)
        else { return false }
        let payload = entries.map { e -> [String: String] in
            var row = ["cwd": e.cwd, "name": e.project]
            if let r = e.restore { row["restore"] = r }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return false }

        for name in names where name.hasSuffix(".sock") {
            let reply = send("restore \(json)", to: socketDirectory.appending(path: name).path,
                             timeout: 30)
            if reply?.hasPrefix("restored") == true {
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == "com.microsoft.VSCode" }?
                    .activate(options: [])
                return true
            }
        }
        return false
    }

    /// Sends one line and returns the reply, or nil if the window did not answer.
    @discardableResult
    private static func send(_ line: String, to path: String, timeout: Int32 = 1) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                strncpy(dst, path, maxLen - 1)
            }
        }

        // Don't let an unresponsive extension host stall the UI.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: timeout == 1 ? 400_000 : 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var payload = Array((line + "\n").utf8)
        guard write(fd, &payload, payload.count) > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

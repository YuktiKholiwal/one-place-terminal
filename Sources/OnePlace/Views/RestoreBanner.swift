import SwiftUI

/// Offers back the sessions that were open last time but are not running now.
///
/// This is the whole point of the snapshot: after a crash you should not have
/// to remember what was open, or go folder by folder starting agents again.
struct RestoreBanner: View {
    @Environment(SessionStore.self) private var store
    /// Open by default: the point of this is to see what was lost without
    /// having to go looking for it.
    @State private var expanded = true
    @State private var working = false
    @State private var failure: String?

    private var entries: [Snapshot.Entry] { store.restorable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        RestoreRow(entry: entry)
                    }
                }
                .padding(.top, 2)
            }
            if let failure {
                Text(failure)
                    .font(Theme.label)
                    .foregroundStyle(Theme.fgSubtle)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Theme.waiting.opacity(0.06))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    private var headline: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.waiting)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(entries.count) not running")
                    .font(Theme.bodyMed)
                    .foregroundStyle(Theme.fg)
                if let date = store.recoveryDate {
                    Text(verbatim: "last seen \(Self.when.string(from: date))")
                        .font(Theme.monoSm)
                        .foregroundStyle(Theme.fgSubtle)
                }
            }

            Spacer(minLength: 4)

            Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                .buttonStyle(QuietButtonStyle())

            Button(working ? "Restoring…" : "Restore all") { restoreAll() }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func restoreAll() {
        working = true
        failure = nil
        let batch = entries
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DispatchQueue.main.sync { store.restore(batch) }
            DispatchQueue.main.async {
                working = false
                if !ok {
                    failure = "VS Code extension not reachable — run ./vscode-extension/install.sh, "
                            + "or ./restore.sh --print to copy the commands."
                }
            }
        }
    }

    static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()
}

private struct RestoreRow: View {
    let entry: Snapshot.Entry
    @Environment(SessionStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.left")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.fgSubtle)
                .frame(width: 10)

            Text(entry.project)
                .font(Theme.bodyMed)
                .foregroundStyle(Theme.fgMuted)
                .lineLimit(1)

            Text(label)
                .font(Theme.monoSm)
                .foregroundStyle(Theme.fgSubtle)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if hovering {
                Button("Restore") { store.restore([entry]) }
                    .buttonStyle(QuietButtonStyle())
            } else if let agent = entry.agent {
                Text(agent)
                    .font(Theme.monoSm)
                    .foregroundStyle(Theme.fgSubtle.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(hovering ? Theme.bgHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Prefer the conversation's own title, then a short id, then the command.
    private var label: String {
        if let t = entry.title, !t.isEmpty { return t }
        if let sid = entry.sessionID { return String(sid.prefix(8)) }
        return entry.restore ?? entry.command ?? "shell"
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.labelCaps)
            .foregroundStyle(Theme.fgMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(configuration.isPressed ? Theme.border : Theme.bgElevated))
            .contentShape(Rectangle())
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.labelCaps)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Theme.running.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
    }
}

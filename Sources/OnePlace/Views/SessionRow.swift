import SwiftUI

struct SessionRow: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    @State private var hovering = false

    private var armed: Bool { store.pendingKill == session.id }
    private var terminating: Bool { store.killing.contains(session.id) }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: session.state)

            Text(session.project)
                .font(Theme.bodyMed)
                .foregroundStyle(session.state == .stale ? Theme.fgSubtle : Theme.fg)
                .lineLimit(1)

            Text(session.command ?? "zsh")
                .font(Theme.mono)
                .foregroundStyle(Theme.fgSubtle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let port = session.port {
                PortBadge(port: port)
            }

            if armed {
                Button("Kill?") { store.kill(session) }
                    .buttonStyle(DangerButtonStyle())
                    .transition(.opacity)
            } else if hovering {
                Button {
                    store.pendingKill = session.id
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(GhostButtonStyle())
                .help("End this session")
            } else {
                Text(displayAge)
                    .font(Theme.monoSm)
                    .foregroundStyle(Theme.fgSubtle)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius)
                .fill(hovering ? Theme.bgHover : .clear)
        )
        .opacity(terminating ? 0.3 : 1)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if !h && armed { store.pendingKill = nil }
        }
        .onTapGesture { store.focus(session) }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: armed)
        .animation(.easeOut(duration: 0.15), value: terminating)
    }

    /// For a running command show how long *it* has run; otherwise the tab's age.
    private var displayAge: String {
        (session.commandAge ?? session.age).compactAge
    }
}

struct StatusDot: View {
    let state: Session.State
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .waiting: Theme.waiting
        case .running: Theme.running
        case .idle:    Theme.idle
        case .stale:   Theme.stale
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 3)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear {
                guard state == .waiting else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

struct PortBadge: View {
    let port: Int
    var body: some View {
        // Interpolating an Int applies locale digit grouping (":3,000").
        Text(verbatim: ":\(String(port))")
            .font(Theme.monoSm)
            .monospacedDigit()
            .foregroundStyle(Theme.running)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.running.opacity(0.12))
            )
    }
}

// MARK: - Button styles

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.fg : Theme.fgSubtle)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Theme.border : .clear)
            )
            .contentShape(Rectangle())
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.labelCaps)
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.danger.opacity(configuration.isPressed ? 0.28 : 0.14))
            )
            .contentShape(Rectangle())
    }
}

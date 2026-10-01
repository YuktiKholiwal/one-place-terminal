import SwiftUI

struct PopoverView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            if !store.restorable.isEmpty {
                RestoreBanner()
            }

            if store.sessions.isEmpty {
                emptyState
            } else if naturalListHeight <= Theme.maxListHeight {
                // Common case: no ScrollView at all. A MenuBarExtra window sizes
                // itself to its content, and a flexible ScrollView inside it can
                // collapse rather than report the height it needs — which is how
                // a 16-session list ended up showing one row. Plain content has
                // a definite height and cannot collapse.
                SessionList()
            } else {
                ScrollView { SessionList() }
                    // An explicit height, never maxHeight: maxHeight is only an
                    // upper bound and leaves the ScrollView free to collapse.
                    .frame(height: Theme.maxListHeight)
            }

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: Theme.popoverWidth)
        .background(Theme.bg)
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.fg)

            Spacer()

            Text(verbatim: String(store.sessions.count))
                .font(Theme.mono).monospacedDigit()
                .foregroundStyle(Theme.fgMuted)
            Text("·").foregroundStyle(Theme.fgSubtle)
            Text(verbatim: "\(projectCount) projects")
                .font(Theme.label)
                .foregroundStyle(Theme.fgSubtle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.running)
                .frame(width: 5, height: 5)
            Text("live · \(scanLabel)")
                .font(Theme.monoSm).monospacedDigit()
                .foregroundStyle(Theme.fgSubtle)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.label)
                .foregroundStyle(Theme.fgSubtle)
                .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(store.isLoaded ? "No terminal sessions" : "Scanning…")
                .font(Theme.body)
                .foregroundStyle(Theme.fgMuted)
            if store.isLoaded {
                Text("Open a terminal and it will appear here.")
                    .font(Theme.label)
                    .foregroundStyle(Theme.fgSubtle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    /// Scans land around 1.3ms, so milliseconds alone would always read "1ms".
    private var scanLabel: String {
        let us = store.lastScanMicros
        return us < 10_000 ? String(format: "%.1fms", Double(us) / 1000) : "\(us / 1000)ms"
    }

    /// The height the list wants. Derived rather than measured, so the window
    /// can size itself correctly on its first layout pass.
    private var naturalListHeight: CGFloat {
        let rows = CGFloat(store.sessions.count) * Theme.rowHeight
        let headers = CGFloat(store.grouped.count) * Theme.sectionHeaderHeight
        return rows + headers + Theme.listVerticalPadding
    }

    private var projectCount: Int {
        Set(store.sessions.compactMap { $0.cwd }).count
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Theme.labelCaps)
                .tracking(0.6)
                .foregroundStyle(Theme.fgSubtle)
            Spacer()
            Text(verbatim: String(count))
                .font(Theme.monoSm).monospacedDigit()
                .foregroundStyle(Theme.fgSubtle)
        }
        .padding(.horizontal, 15)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }
}

/// The grouped rows. A separate view so it can be rendered standalone:
/// `ImageRenderer` does not rasterise `ScrollView` contents.
struct SessionList: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.grouped, id: \.state) { group in
                SectionHeader(title: group.state.title, count: group.items.count)
                ForEach(group.items) { session in
                    SessionRow(session: session)
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
    }
}

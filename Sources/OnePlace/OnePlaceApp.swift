import SwiftUI
import AppKit

@main
struct OnePlaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SessionStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(store)
        } label: {
            MenuBarLabel(attention: store.attentionCount, total: store.sessions.count)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        // Scan from launch so the badge is populated before the first click,
        // rather than waiting for the popover's onAppear.
        SessionStore.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.stop()
    }
}

struct MenuBarLabel: View {
    let attention: Int
    let total: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "apple.terminal.fill")
            if attention > 0 {
                Text("\(attention)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            } else if total > 0 {
                Text("\(total)")
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
            }
        }
    }
}

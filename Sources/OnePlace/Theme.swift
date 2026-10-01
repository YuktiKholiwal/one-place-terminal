import SwiftUI

/// Vercel / Geist design tokens.
/// Monochrome surfaces, 1px hairline borders, color reserved for status only.
enum Theme {
    // Surfaces
    static let bg          = Color(hex: 0x0A0A0A)
    static let bgElevated  = Color(hex: 0x141414)
    static let bgHover     = Color(hex: 0x1A1A1A)

    // Borders
    static let border      = Color(hex: 0x262626)
    static let borderSubtle = Color(hex: 0x1F1F1F)

    // Foreground
    static let fg          = Color(hex: 0xEDEDED)
    static let fgMuted     = Color(hex: 0xA1A1A1)
    static let fgSubtle    = Color(hex: 0x6E6E6E)

    // Status accents — the only color in the app
    static let waiting     = Color(hex: 0xF5A623)  // amber: needs you
    static let running     = Color(hex: 0x0070F3)  // blue: working
    static let idle        = Color(hex: 0x6E6E6E)  // grey: at a prompt
    static let stale       = Color(hex: 0x4A4A4A)  // dim: forgotten
    static let danger      = Color(hex: 0xE5484D)  // red: kill

    // Type scale — SF Pro / SF Mono, no bundled fonts
    static let label    = Font.system(size: 11, weight: .medium)
    static let labelCaps = Font.system(size: 10, weight: .semibold)
    static let body     = Font.system(size: 12, weight: .regular)
    static let bodyMed  = Font.system(size: 12, weight: .medium)
    static let mono     = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoSm   = Font.system(size: 10, weight: .regular, design: .monospaced)

    // Metrics
    static let radius: CGFloat = 6
    static let rowHeight: CGFloat = 27
    static let sectionHeaderHeight: CGFloat = 26
    static let listVerticalPadding: CGFloat = 12
    static let maxListHeight: CGFloat = 560
    static let popoverWidth: CGFloat = 340
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}

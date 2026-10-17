// Shared appearance for PikPak and Mikan.
import SwiftUI
import AppKit

extension NSColor {
    /// `#rrggbb` / `#rrggbbaa` hex.
    fileprivate convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:    CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:     CGFloat(hex & 0xFF) / 255,
                  alpha:    alpha)
    }
}

extension Color {
    /// A color that resolves to `dark` under a dark appearance, else `light`.
    static func dyn(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

public enum CloudTokens {
    public enum Spacing {
        public static let toolbarHeight: CGFloat = 52
    }
    public static let bg       = Color.dyn(NSColor(hex: 0x131316), NSColor(hex: 0xF4F5F8))
    public static let bg2      = Color.dyn(NSColor(hex: 0x1F1F22), NSColor(hex: 0xFFFFFF))
    public static let text     = Color.dyn(NSColor(hex: 0xF5F5F7), NSColor(hex: 0x1D1D1F))
    public static let text2    = Color.dyn(NSColor(hex: 0xA1A1A6), NSColor(hex: 0x6E6E73))
    public static let text3    = Color.dyn(NSColor(hex: 0x6E6E73), NSColor(hex: 0xA1A1A6))
    public static let sep      = Color.dyn(NSColor(hex: 0xFFFFFF, alpha: 0.10), NSColor(hex: 0x000000, alpha: 0.10))
    public static let accent     = Color.dyn(NSColor(hex: 0x0A84FF), NSColor(hex: 0x007AFF))
    public static let warn       = Color.dyn(NSColor(hex: 0xFF9F0A), NSColor(hex: 0xFF9500))
}

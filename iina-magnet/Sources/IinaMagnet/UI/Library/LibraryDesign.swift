//
//  LibraryDesign.swift
//  IinaMagnet
//
//  SwiftUI design tokens for the media-library UI, ported 1:1 from the handoff
//  design's `app/theme.css` (Apple-TV × macOS-Tahoe liquid glass, dark/light).
//  Colors are dynamic NSColors so they track the system appearance without the
//  views threading a ColorScheme; radii/spacing match the CSS variables.

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

/// Design tokens. `--c-*` → `Tokens.*`, `--r-*` → `Radius.*`.
public enum LibraryTokens {

    // MARK: Radii (--r-*)
    public enum Radius {
        public static let window: CGFloat = 12
        public static let poster: CGFloat = 7
        public static let card: CGFloat = 10
        public static let control: CGFloat = 7
        public static let panel: CGFloat = 17
        public static let pill: CGFloat = 999
    }

    // MARK: Spacing
    public enum Spacing {
        public static let wallGap: CGFloat = 22
        public static let pagePadding: CGFloat = 26
        public static let toolbarHeight: CGFloat = 52
        public static let statsHeight: CGFloat = 30
        public static let sidebarWidth: CGFloat = 244
    }

    // MARK: Backgrounds (--c-bg*)
    public static let bg       = Color.dyn(NSColor(hex: 0x131316), NSColor(hex: 0xF4F5F8))
    public static let bg2      = Color.dyn(NSColor(hex: 0x1F1F22), NSColor(hex: 0xFFFFFF))
    public static let bg3      = Color.dyn(NSColor(hex: 0x2A2A2E), NSColor(hex: 0xECECEF))

    // MARK: Text (--c-text*)
    public static let text     = Color.dyn(NSColor(hex: 0xF5F5F7), NSColor(hex: 0x1D1D1F))
    public static let text2    = Color.dyn(NSColor(hex: 0xA1A1A6), NSColor(hex: 0x6E6E73))
    public static let text3    = Color.dyn(NSColor(hex: 0x6E6E73), NSColor(hex: 0xA1A1A6))

    // MARK: Separators / fills
    public static let sep      = Color.dyn(NSColor(hex: 0xFFFFFF, alpha: 0.10), NSColor(hex: 0x000000, alpha: 0.10))
    public static let sep2     = Color.dyn(NSColor(hex: 0xFFFFFF, alpha: 0.16), NSColor(hex: 0x000000, alpha: 0.15))
    public static let fill     = Color.dyn(NSColor(hex: 0xFFFFFF, alpha: 0.08), NSColor(hex: 0x000000, alpha: 0.05))
    public static let fill2    = Color.dyn(NSColor(hex: 0xFFFFFF, alpha: 0.13), NSColor(hex: 0x000000, alpha: 0.09))

    // MARK: Accent + status (--c-accent / warn / done / fail / unmatched)
    public static let accent     = Color.dyn(NSColor(hex: 0x0A84FF), NSColor(hex: 0x007AFF))
    public static let accentSoft = Color.dyn(NSColor(hex: 0x0A84FF, alpha: 0.22), NSColor(hex: 0x007AFF, alpha: 0.14))
    public static let onAccent   = Color.white
    public static let warn       = Color.dyn(NSColor(hex: 0xFF9F0A), NSColor(hex: 0xFF9500))
    public static let warnSoft   = Color.dyn(NSColor(hex: 0xFF9F0A, alpha: 0.18), NSColor(hex: 0xFF9500, alpha: 0.16))
    public static let done       = Color.dyn(NSColor(hex: 0x30D158), NSColor(hex: 0x34C759))
    public static let fail       = Color.dyn(NSColor(hex: 0xFF453A), NSColor(hex: 0xFF3B30))
    public static let unmatched  = Color(nsColor: NSColor(hex: 0x8E8E93))

    // MARK: Rating-source brand colors (README Design Tokens)
    public static func ratingSource(_ s: RatingBadge.Source) -> Color {
        switch s {
        case .bangumi: return Color(nsColor: NSColor(hex: 0xFF6699))
        case .tmdb:    return Color(nsColor: NSColor(hex: 0x01B4E4))
        case .douban:  return Color(nsColor: NSColor(hex: 0x2D963D))
        }
    }
}

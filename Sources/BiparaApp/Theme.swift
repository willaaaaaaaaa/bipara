import AppKit
import BiparaCore
import SwiftUI

enum ReadingMetrics {
    static func textWidth(pane: CGFloat, layout: LayoutMode, preference: ReadingWidth, window: CGFloat) -> CGFloat {
        let available = max(80, pane - (window < 1100 ? 48 : 64))
        let cap: CGFloat
        switch preference {
        case .standard: cap = layout == .sideBySide ? 720 : 800
        case .wide: cap = layout == .sideBySide ? 960 : 1080
        case .window: cap = available
        }
        return min(available, cap)
    }
    static func inset(pane: CGFloat, layout: LayoutMode, preference: ReadingWidth, window: CGFloat) -> CGFloat {
        (pane - textWidth(pane: pane, layout: layout, preference: preference, window: window)) / 2
    }
}

public enum ThemeColors {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: 1)
    }
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
    static let source = adaptive(light: 0x202124, dark: 0xE4E4E7)
    static let translation = adaptive(light: 0x245C78, dark: 0xABCBD9)
}

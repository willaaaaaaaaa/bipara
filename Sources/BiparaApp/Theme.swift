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
    static func correspondence(_ preset: CorrespondenceColor) -> NSColor {
        let pair = tokens(preset)
        return adaptive(light: pair.0, dark: pair.1)
    }
    static func tokens(_ preset: CorrespondenceColor) -> (UInt32, UInt32) {
        switch preset {
        case .blue: return (0xDCEAF7, 0x28455C)
        case .teal: return (0xD9EEE9, 0x254A43)
        case .amber: return (0xF6E8C8, 0x514327)
        case .purple: return (0xEAE2F5, 0x443651)
        }
    }
    public static let correspondenceBackground = Color(nsColor: correspondence(.defaultPreset))
    public static func correspondenceBackground(light: Bool, increasedContrast: Bool) -> Color {
        let pair = tokens(.defaultPreset)
        return Color(nsColor: color(light ? pair.0 : pair.1))
    }
}

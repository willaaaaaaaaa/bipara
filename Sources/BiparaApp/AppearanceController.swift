import AppKit
import Foundation

/// Applies the appearance preference to the whole app: `nil` for System,
/// `.aqua` for Light, `.darkAqua` for Dark. Individual windows and text
/// views never carry conflicting forced appearances; in System mode the
/// app follows the OS appearance while running.
@MainActor
public final class AppearanceController: ObservableObject {
    @Published public private(set) var mode: AppearanceMode = .system

    public init() {
        apply(.system)
    }

    /// Sets `NSApp.appearance` per the mode and records the active mode.
    public func apply(_ mode: AppearanceMode) {
        self.mode = mode
        let app = NSApplication.shared
        switch mode {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The currently effective appearance (resolved, not preferred).
    public var effectiveAppearance: AppearanceMode {
        let app = NSApplication.shared
        if app.appearance == nil {
            return .system
        }
        let name = app.appearance?.bestMatch(from: [
            NSAppearance.Name.aqua, NSAppearance.Name.darkAqua,
        ])
        return name == NSAppearance.Name.darkAqua ? .dark : .light
    }
}

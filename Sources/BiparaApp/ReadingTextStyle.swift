import AppKit

/// Shared document typography for the editor and both reading modes.
@MainActor
enum ReadingTextStyle {
    static func monospacedFont(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func font(for typography: ReadingTypography) -> NSFont {
        let system = NSFont.systemFont(ofSize: typography.size)
        switch typography.family {
        case .monospaced: return monospacedFont(size: typography.size)
        case .system: return system
        case .serif:
            guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
            return NSFont(descriptor: descriptor, size: typography.size) ?? system
        }
    }

    static func paragraphStyle(for typography: ReadingTypography) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        // A point-based baseline grid keeps Latin and Chinese fallback runs aligned.
        style.minimumLineHeight = ceil(typography.size * (Double(typography.lineHeight.rawValue) ?? 1.5))
        style.maximumLineHeight = style.minimumLineHeight
        return style
    }
}

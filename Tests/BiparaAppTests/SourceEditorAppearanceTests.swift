import AppKit
@testable import BiparaAppKit
import SwiftUI
import Testing

@MainActor @Suite("Source editor appearance")
struct SourceEditorAppearanceTests {
    private func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    private func brightness(_ color: NSColor, appearance: NSAppearance) throws -> CGFloat {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func pastedTextAndFontUpdatesKeepSemanticColors(appearanceName: NSAppearance.Name) throws {
        _ = NSApplication.shared
        let appearance = try #require(NSAppearance(named: appearanceName))
        let frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        defer { window.close() }
        var source = "Original English 中文。"
        let binding = Binding(get: { source }, set: { source = $0 })
        let host = NSHostingView(rootView: SourceEditorView(text: binding, isComposing: .constant(false)))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        let text = try #require(editor(in: host))
        text.insertText(" Pasted English 新增中文。", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let content = text.string
        text.setSelectedRange(NSRange(location: 9, length: 7))
        for size in [12.0, 20.0] {
            window.appearance = appearance
            if size != 12 {
                var typography = ReadingTypography()
                typography.size = size
                host.rootView = SourceEditorView(text: binding, isComposing: .constant(false), typography: typography)
                host.layoutSubtreeIfNeeded()
            }
            #expect(text.string == content)
            #expect(text.selectedRange() == NSRange(location: 9, length: 7))
            #expect(text.font?.pointSize == CGFloat(size))
            #expect(text.font?.familyName == "Menlo")
            for name in [appearanceName, appearanceName == .aqua ? .darkAqua : .aqua] {
                let current = try #require(NSAppearance(named: name))
                window.appearance = current
                let background = try brightness(text.backgroundColor, appearance: current)
                let expected = try brightness(.textColor, appearance: current)
                let storage = try #require(text.textStorage)
                for offset in [0, storage.length - 1] {
                    let color = try #require(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
                    #expect(abs(try brightness(color, appearance: current) - expected) < 0.01)
                    #expect(abs(try brightness(color, appearance: current) - background) > 0.5)
                }
                let typingColor = try #require(text.typingAttributes[.foregroundColor] as? NSColor)
                #expect(abs(try brightness(typingColor, appearance: current) - expected) < 0.01)
            }
        }
    }
}

import AppKit
import BiparaCore
import SwiftUI

/// Read-only acknowledgement from the native surface after applying its current presentation.
@MainActor public protocol NativeReadingRenderState: AnyObject {
    var renderedIdentity: String? { get }
}

/// Fixed-size native text bridge: two text views for columns, one for alternating paragraphs.
struct NativeReadingSurface: NSViewRepresentable {
    let sessionID: UUID
    let document: BiparaDocument
    let layout: LayoutMode
    let typography: ReadingTypography
    let presentation: ReadingPresentation
    let language: InterfaceLanguage
    var readingWidth: ReadingWidth = .wide
    var correspondenceColor: CorrespondenceColor = .defaultPreset
    var jobState: JobState = .idle
    let onSelect: (ReadingSelection?) -> Void
    let onHover: (ReadingSelection?) -> Void
    let onAnchor: (ReadingAnchor) -> Void

    func makeNSView(context: Context) -> ParallelReader { ParallelReader() }
    func updateNSView(_ view: ParallelReader, context: Context) { view.update(self) }
}

@MainActor
final class ReadingMarksView: NSView {
    var rules: [NSRect] = []
    var unfinished: [NSRect] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ThemeColors.translation.withAlphaComponent(0.4).setFill()
        for rect in rules where rect.intersects(dirtyRect) { rect.fill() }
        NSColor.secondaryLabelColor.setFill()
        for rect in unfinished where rect.intersects(dirtyRect) { rect.fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class ReaderTextView: NSTextView {
    var hover: ((Int?) -> Void)?
    var rules: [NSRect] = [] { didSet { updateMarks() } }
    var unfinished: [NSRect] = [] { didSet { updateMarks() } }
    private lazy var marks: ReadingMarksView = {
        let view = ReadingMarksView(frame: bounds)
        view.setAccessibilityElement(false)
        addSubview(view)
        return view
    }()
    private func updateMarks() {
        marks.frame = bounds; marks.rules = rules; marks.unfinished = unfinished; marks.needsDisplay = true
    }
    override func layout() { super.layout(); updateMarks() }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        hover?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { hover?(nil) }
}

@MainActor
final class ParallelReader: NSView, NSTextViewDelegate, NativeReadingRenderState {
    private(set) var renderedIdentity:String?
    private var parent: NativeReadingSurface?
    private var index: RenderedTextIndex?
    private var renderedDocument: BiparaDocument?
    private var renderedSessionID: UUID?
    private var renderedTypography: ReadingTypography?
    private var renderedLayout: LayoutMode?
    private var renderedLanguage: InterfaceLanguage?
    private var renderedWidth: ReadingWidth?
    private var renderedColor: CorrespondenceColor?
    private var renderedState: JobState?
    private var updating = false
    private var revealGeneration = 0
    private var lastAnchor: ReadingAnchor?
    private var appliedHighlights: [[NSRange]] = [[],[]]
    // Cache intrinsic (unpadded) geometry only; text and all metric inputs are part of the key.
    private struct MeasurementKey: Hashable { let text:Data;let font:String;let size:CGFloat;let lineHeight:Double;let width:CGFloat }
    private var measuredHeights: [MeasurementKey:CGFloat] = [:]
    private let scrolls = [NSScrollView(), NSScrollView()]
    private let texts = [ReaderTextView(usingTextLayoutManager: true), ReaderTextView(usingTextLayoutManager: true)]
    private let emptyMessage = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for i in 0...1 {
            let text = texts[i], scroll = scrolls[i]
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.drawsBackground = false; text.delegate = self; text.textContainerInset = NSSize(width: 28, height: 24)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = false
            text.textContainer?.lineFragmentPadding = 0
            text.setAccessibilityIdentifier(i == 0 ? "reader.source" : "reader.translation")
            scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            text.hover = { [weak self] offset in
                guard let self, !self.updating else { return }
                self.parent?.onHover(offset.flatMap { self.index?.selection(column: i, range: NSRange(location: $0, length: 0)) })
            }
            addSubview(scroll)
        }
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.font = .systemFont(ofSize: 13)
        emptyMessage.isSelectable = false; emptyMessage.isHidden = true
        emptyMessage.setAccessibilityIdentifier("reader.emptyTranslation")
        addSubview(emptyMessage)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contrastChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ value: NativeReadingSurface) {
        parent = value
        let identityChanged = renderedSessionID != value.sessionID || renderedDocument?.sourceRevision != value.document.sourceRevision
        let changed = identityChanged || renderedDocument != value.document || renderedTypography != value.typography || renderedLayout != value.layout || renderedLanguage != value.language || renderedWidth != value.readingWidth
        let decorationChanged = renderedColor != value.correspondenceColor || renderedState != value.jobState
        if changed {
            updating = true
            let anchor: ReadingAnchor?
            if identityChanged {
                anchor = value.presentation.anchors[value.layout] ?? value.document.readingAnchor
                lastAnchor = nil; revealGeneration = value.presentation.revealGeneration
            } else if renderedLayout != value.layout {
                anchor = lastAnchor ?? value.presentation.anchors[value.layout] ?? value.document.readingAnchor
            } else { anchor = value.presentation.anchors[value.layout] ?? lastAnchor ?? value.document.readingAnchor }
            index = RenderedTextIndex(document: value.document, layout: value.layout)
            renderedSessionID = value.sessionID; renderedDocument = value.document; renderedTypography = value.typography; renderedLayout = value.layout; renderedLanguage = value.language
            renderedWidth = value.readingWidth
            needsLayout = true
            layoutSubtreeIfNeeded()
            layoutText(anchor: anchor)
            updating = false
        }
        renderedColor = value.correspondenceColor; renderedState = value.jobState
        highlight(force: decorationChanged)
        if changed || decorationChanged { decorate() }
        if revealGeneration != value.presentation.revealGeneration {
            revealGeneration = value.presentation.revealGeneration
            if let selection = value.presentation.pinned ?? value.presentation.selection ?? value.presentation.hover,
               let (column, span) = index?.span(selection, counterpart: true) {
                let range=value.presentation.displayedPhraseRanges.first.map{NSRange(location:span.range.location+$0.location,length:$0.length)} ?? span.range
                updating=true
                texts[column].scrollRangeToVisible(range)
                updating=false
            }
        }
        renderedIdentity="reader.surface.\(value.sessionID).\(value.document.sourceRevision).\(value.layout.rawValue).\(value.presentation.selectionGeneration)"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, index != nil {
            updating = true; layoutText(anchor: lastAnchor); updating = false
            highlight(force: true); decorate()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight(force: true)
        texts.forEach { $0.needsDisplay = true }
    }

    @objc private func contrastChanged() { highlight(force: true); decorate() }

    override func layout() {
        let oldWidth = scrolls[0].frame.width
        super.layout()
        let columns = parent?.layout == .sideBySide ? 2 : 1
        let width = floor(bounds.width / CGFloat(columns))
        scrolls[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrolls[1].isHidden = columns == 1
        if columns == 2 { scrolls[1].frame = NSRect(x: width, y: 0, width: bounds.width - width, height: bounds.height) }
        let inset = parent.map { ReadingMetrics.inset(pane: width, layout: $0.layout, preference: $0.readingWidth, window: bounds.width) } ?? 24
        emptyMessage.frame = NSRect(x: (columns == 2 ? width : 0) + inset, y: bounds.height - 52,
                                    width: max(0, width - inset * 2), height: 24)
        if abs(oldWidth - width) > 0.5, !updating, index != nil {
            updating = true; layoutText(anchor: lastAnchor); updating = false
            highlight(force: true); decorate()
        }
    }

    private func layoutText(anchor: ReadingAnchor?, stabilizeScrollers: Bool = true) {
        guard let parent, let index, scrolls[0].contentSize.width > 0 else { return }
        let count = parent.layout == .sideBySide ? 2 : 1
        let font: NSFont
        let system = NSFont.systemFont(ofSize: parent.typography.size)
        if parent.typography.family == .serif, let descriptor = system.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: descriptor, size: parent.typography.size) ?? system }
        else { font = system }
        let style = NSMutableParagraphStyle(); style.lineHeightMultiple = Double(parent.typography.lineHeight.rawValue) ?? 1.7; style.paragraphSpacing = 20
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ThemeColors.source, .paragraphStyle: style]
        let attributed = [NSMutableAttributedString(string: index.strings[0], attributes: base), NSMutableAttributedString(string: index.strings[1], attributes: base)]
        let paneWidths = (0..<count).map { scrolls[$0].contentSize.width }
        let widths = paneWidths.map { ReadingMetrics.textWidth(pane: $0, layout: parent.layout, preference: parent.readingWidth, window: bounds.width) }
        for col in 0..<count {
            for span in index.paragraphs[col] where span.range.length > 0 {
                let paragraphStyle = style.mutableCopy() as! NSMutableParagraphStyle
                if parent.layout == .paragraphs { paragraphStyle.paragraphSpacing = span.side == .source ? 8 : 24 }
                attributed[col].addAttributes([.foregroundColor: span.side == .source ? ThemeColors.source : ThemeColors.translation,
                                               .paragraphStyle: paragraphStyle], range: span.range)
            }
        }
        if count == 2 {
            let byParagraph=index.paragraphs.map{Dictionary(uniqueKeysWithValues:$0.map{($0.paragraphID,$0)})}
            for p in parent.document.paragraphs {
                guard let a = byParagraph[0][p.id], let b = byParagraph[1][p.id] else { continue }
                let spans = [a, b]
                let heights = (0...1).map { col in
                    let span = spans[col].range
                    let measuredRange = span.length > 0 ? span : NSRange(location: span.location, length: min(1, attributed[col].length - span.location))
                    let key=MeasurementKey(text:Data((attributed[col].string as NSString).substring(with:measuredRange).utf8),font:font.fontName,size:font.pointSize,lineHeight:style.lineHeightMultiple,width:widths[col])
                    if let height=measuredHeights[key] { return height }
                    let height=attributed[col].attributedSubstring(from:measuredRange).boundingRect(with:NSSize(width:widths[col],height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
                    if key.text.count <= 16 << 10 {
                        if measuredHeights.count >= 512 { measuredHeights.removeAll(keepingCapacity:true) }
                        measuredHeights[key]=height
                    }
                    return height
                }
                for col in 0...1 where heights[col] < heights[1-col] {
                    let padded = style.mutableCopy() as! NSMutableParagraphStyle
                    padded.paragraphSpacing += heights[1-col] - heights[col]
                    let span = spans[col].range
                    let range = span.length > 0 ? span : NSRange(location: span.location, length: min(1, attributed[col].length - span.location))
                    if range.length > 0 { attributed[col].addAttribute(.paragraphStyle, value: padded, range: range) }
                }
            }
        }
        for col in 0..<count {
            let blankStyle=NSMutableParagraphStyle()
            blankStyle.minimumLineHeight=font.pointSize*0.6;blankStyle.maximumLineHeight=font.pointSize*0.6
            for range in index.blankRanges[col] where range.length > 0 {
                attributed[col].addAttribute(.paragraphStyle,value:blankStyle,range:range)
            }
            texts[col].textContainerInset = NSSize(width: max(0,(scrolls[col].contentSize.width-widths[col])/2), height:24)
            texts[col].textContainer?.containerSize = NSSize(width: widths[col], height: CGFloat.greatestFiniteMagnitude)
            guard let storage = texts[col].textStorage else { continue }
            storage.beginEditing()
            if !TextIdentity.equal(storage.string, attributed[col].string) {
                replaceDifference(in: storage, with: attributed[col])
            }
            attributed[col].enumerateAttributes(in: NSRange(location: 0, length: attributed[col].length)) { attrs, range, _ in storage.setAttributes(attrs, range: range) }
            storage.endEditing()
            // Legacy scrollers can replace the document frame while tiling.
            scrolls[col].layoutSubtreeIfNeeded()
            if let manager = texts[col].textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
                texts[col].setFrameSize(NSSize(width: scrolls[col].contentSize.width,
                    height: max(scrolls[col].contentSize.height, manager.usageBoundsForTextContainer.maxY + 48)))
            }
        }
        if stabilizeScrollers, (0..<count).contains(where: { abs(paneWidths[$0] - scrolls[$0].contentSize.width) > 0.5 }) {
            layoutText(anchor: anchor, stabilizeScrollers: false)
            return
        }
        for col in 0...1 {
            var range = NSRange(location:0,length:0)
            if col < count, let selection = parent.presentation.selection,
               let (column,span) = index.span(selection,counterpart:false), column == col {
                let projected = NSRange(location:span.range.location + selection.range.location,length:selection.range.length)
                if NSMaxRange(projected) <= texts[col].string.utf16.count { range = projected }
            }
            texts[col].setSelectedRange(range)
        }
        appliedHighlights=[[],[]]
        if let anchor { restore(anchor) }
        else {
            for col in 0..<count { scrolls[col].contentView.scroll(to:.zero);scrolls[col].reflectScrolledClipView(scrolls[col].contentView) }
        }
    }

    private func replaceDifference(in storage: NSTextStorage, with new: NSAttributedString) {
        let old = storage.string, next = new.string
        let a = Array(old.utf16), b = Array(next.utf16)
        var prefix = 0
        while prefix < min(a.count,b.count), a[prefix] == b[prefix] { prefix += 1 }
        while prefix > 0, (!old.hasValidRange(.init(location: 0, length: prefix)) || !next.hasValidRange(.init(location: 0, length: prefix))) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count,b.count)-prefix, a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        while suffix > 0, (!old.hasValidRange(.init(location: a.count-suffix, length: suffix)) || !next.hasValidRange(.init(location: b.count-suffix, length: suffix))) { suffix -= 1 }
        storage.replaceCharacters(in: NSRange(location: prefix, length: a.count-prefix-suffix), with: new.attributedSubstring(from: NSRange(location: prefix, length: b.count-prefix-suffix)))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !updating, let text = notification.object as? NSTextView, let column = texts.firstIndex(where: { $0 === text }) else { return }
        let range = text.selectedRange()
        parent?.onSelect(range.length > 0 ? index?.selection(column: column, range: range) : nil)
    }

    private func highlight(force: Bool = false) {
        guard let parent, let index else { return }
        let selection = parent.presentation.pinned ?? parent.presentation.selection ?? parent.presentation.hover
        updating = true
        defer { updating = false }
        var desired:[[NSRange]]=[[],[]]
        if let selection {
            for counterpart in [false,true] {
                guard let (column,span)=index.span(selection,counterpart:counterpart) else { continue }
                let phrases=parent.presentation.displayedPhraseRanges
                desired[column] += counterpart && !phrases.isEmpty
                    ? phrases.map{NSRange(location:span.range.location+$0.location,length:$0.length)}:[span.range]
            }
        }
        let color = ThemeColors.correspondence(parent.correspondenceColor)
        let underline: NSUnderlineStyle = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .thick : .single
        for col in 0...1 where force || desired[col] != appliedHighlights[col] {
            guard let storage=texts[col].textStorage else { continue }
            storage.beginEditing()
            for range in appliedHighlights[col] where NSMaxRange(range) <= storage.length {
                for key in [NSAttributedString.Key.backgroundColor,.underlineStyle,.underlineColor] { storage.removeAttribute(key,range:range) }
            }
            for range in desired[col] where NSMaxRange(range) <= storage.length {
                storage.addAttributes([.backgroundColor:color,.underlineStyle:underline.rawValue,.underlineColor:NSColor.labelColor],range:range)
            }
            storage.endEditing();texts[col].needsDisplay=true
            appliedHighlights[col]=desired[col]
        }
    }

    private func decorate() {
        guard let parent, let index else { return }
        let combined = parent.layout == .paragraphs
        texts[0].setAccessibilityLabel(AppLocalization.text(combined ? "Original and translation" : "Original text", language: parent.language))
        texts[0].setAccessibilityHelp(combined ? AppLocalization.text("Each original paragraph is followed by its translation.", language: parent.language) : nil)
        texts[1].setAccessibilityLabel(AppLocalization.text("Translation", language: parent.language))
        emptyMessage.stringValue = AppLocalization.text("Translation will appear here", language: parent.language)
        emptyMessage.isHidden = parent.layout != .sideBySide || parent.jobState != .idle || !parent.document.translations.isEmpty
        for col in 0...1 {
            texts[col].rules = []; texts[col].unfinished = []
            for span in index.paragraphs[col] {
                if parent.layout == .paragraphs, span.side == .translation, span.range.length > 0 {
                    let first = rect(span, column: col)
                    let last = rect(.init(paragraphID: span.paragraphID, unitID: nil, side: span.side,
                        range: NSRange(location: NSMaxRange(span.range) - 1, length: 1)), column: col)
                    texts[col].rules.append(NSRect(x: first.minX - 12, y: first.minY, width: 2, height: max(12, last.maxY - first.minY)))
                }
                if [.paused, .failed].contains(parent.jobState), span.side == .source,
                   !index.paragraphs[parent.layout == .sideBySide ? 1 : 0].contains(where: { $0.paragraphID == span.paragraphID && $0.side == .translation && $0.range.length > 0 }), span.range.length > 0 {
                    let frame = rect(span, column: col)
                    texts[col].unfinished.append(NSRect(x: frame.minX - 12, y: frame.minY + 6, width: 3, height: 12))
                }
            }
            texts[col].needsDisplay = true
        }
    }

    private func rect(_ span: RenderedSpan, column: Int) -> NSRect {
        guard let manager = texts[column].textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(content.documentRange.location,offsetBy:span.range.location),
              let fragment = manager.textLayoutFragment(for:location) else { return .zero }
        return fragment.layoutFragmentFrame.offsetBy(dx:texts[column].textContainerInset.width,dy:texts[column].textContainerInset.height)
    }
    @objc private func scrolled(_ notification: Notification) {
        guard !updating, let index, let column = scrolls.firstIndex(where: { $0.contentView === notification.object as? NSClipView }) else { return }
        let y = scrolls[column].contentView.bounds.minY
        let spans = index.paragraphs[column].filter{$0.range.length > 0}
        guard let position = spans.indices.last(where: { rect(spans[$0], column: column).minY <= y + 8 }) ?? spans.indices.first else { return }
        let span = spans[position], top = rect(span, column: column).minY
        let bottom = position + 1 < spans.count ? rect(spans[position+1], column: column).minY : texts[column].bounds.height
        let anchor = ReadingAnchor(paragraphID: span.paragraphID, side: span.side, fraction: max(0,min(1,(y-top)/max(1,bottom-top))))
        lastAnchor = anchor
        if parent?.layout == .sideBySide { updating = true; restore(anchor, only: 1-column); updating = false }
        parent?.onAnchor(anchor)
    }
    private func restore(_ anchor: ReadingAnchor, only: Int? = nil) {
        guard let index else { return }
        for col in 0..<(parent?.layout == .sideBySide ? 2 : 1) where only == nil || only == col {
            let spans = index.paragraphs[col]
            let side = anchor.side == .translation && parent?.layout == .paragraphs
                && !spans.contains(where: { $0.paragraphID == anchor.paragraphID && $0.side == .translation && $0.range.length > 0 }) ? ReadingSide.source : anchor.side
            guard let i = spans.firstIndex(where: { $0.paragraphID == anchor.paragraphID && (parent?.layout == .sideBySide || $0.side == side) }) else { continue }
            let top = rect(spans[i], column: col).minY
            let bottom = i+1 < spans.count ? rect(spans[i+1], column: col).minY : texts[col].bounds.height
            let y = min(max(0,top + anchor.fraction*max(1,bottom-top)),max(0,texts[col].bounds.height-scrolls[col].contentSize.height))
            scrolls[col].contentView.scroll(to: NSPoint(x:0,y:y));scrolls[col].reflectScrolledClipView(scrolls[col].contentView)
        }
        lastAnchor = anchor
    }
}

@MainActor
final class SourceTextView:NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { window.makeFirstResponder(self) }
    }
}

public struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var language: InterfaceLanguage
    public init(text: Binding<String>, isComposing: Binding<Bool>, language: InterfaceLanguage = .english) { _text = text; _isComposing = isComposing; self.language = language }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditorView
        init(_ parent: SourceEditorView) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            parent.text = text.string; parent.isComposing = text.hasMarkedText()
        }
        public func textViewDidChangeSelection(_ notification: Notification) {
            if let text = notification.object as? NSTextView { parent.isComposing = text.hasMarkedText() }
        }
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSScrollView {
        let text = SourceTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x:0,y:0,width:600,height:300)
        text.minSize = .zero; text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.isRichText = false; text.allowsUndo = true; text.usesFindBar = true
        text.font = .systemFont(ofSize:17); text.textContainerInset = NSSize(width:18,height:18)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator; text.string = self.text
        text.setAccessibilityIdentifier("source.editor"); text.setAccessibilityLabel(AppLocalization.text("Original text", language: language))
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityLabel(AppLocalization.text("Original text", language: language))
        if !view.hasMarkedText(), !TextIdentity.equal(view.string,text) { view.string = text }
    }
}

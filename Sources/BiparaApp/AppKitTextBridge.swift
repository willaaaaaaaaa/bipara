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
    var markdown: MarkdownReadingProjection? = nil
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
    var linkAt: ((Int) -> (title: String, action: () -> Void)?)?
    var copyText: ((NSRange) -> String?)?
    private var contextLinkAction: (() -> Void)?
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        contextLinkAction = nil
        guard let link = linkAt?(offset) else { return menu }
        contextLinkAction = link.action
        let updated = menu ?? NSMenu()
        let item = NSMenuItem(title: link.title, action: #selector(openContextLink), keyEquivalent: "")
        item.target = self
        updated.insertItem(item, at: 0)
        return updated
    }

    @objc private func openContextLink() { contextLinkAction?() }

    override func copy(_ sender: Any?) {
        guard let text = copyText?(selectedRange()) else {
            super.copy(sender)
            return
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
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
    private var renderedMarkdown: MarkdownReadingProjection?
    private var updating = false
    private var revealGeneration = 0
    private var lastAnchor: ReadingAnchor?
    private var anchorPublication: DispatchWorkItem?
    private var appliedHighlights: [[NSRange]] = [[],[]]
    private var markdownAttributes: [NSAttributedString] = []
    private var stackedTables: Set<UUID> = []
    private struct MarkdownPosition {
        let span: RenderedSpan
        let groupID: UUID
        let frame: NSRect
    }
    private var markdownPositions: [[MarkdownPosition]] = [[], []]
    // Cache intrinsic (unpadded) geometry only; text and all metric inputs are part of the key.
    private struct MeasurementKey: Hashable { let text:Data;let font:String;let size:CGFloat;let lineHeight:Double;let width:CGFloat }
    private var measuredHeights: [MeasurementKey:CGFloat] = [:]
    private let scrolls = [NSScrollView(), NSScrollView()]
    private var texts: [ReaderTextView] = []
    private let emptyMessage = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        installTextViews(markdown: false)
        for i in 0...1 {
            let scroll = scrolls[i]
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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

    private func installTextViews(markdown: Bool) {
        // NSTextTable paragraph attributes are laid out by TextKit 1.
        // Keep a reader's engine stable for both Markdown presentation modes.
        texts = (0...1).map { i in
            let text = ReaderTextView(usingTextLayoutManager: !markdown)
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.drawsBackground = false; text.delegate = self; text.textContainerInset = NSSize(width: 28, height: 24)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = false
            text.textContainer?.lineFragmentPadding = 0
            text.setAccessibilityIdentifier(i == 0 ? "reader.source" : "reader.translation")
            text.hover = { [weak self] offset in
                guard let self, !self.updating else { return }
                self.parent?.onHover(offset.flatMap { self.index?.selection(column: i, range: NSRange(location: $0, length: 0)) })
            }
            if markdown {
                text.linkAt = { [weak self] offset in self?.contextLink(column: i, offset: offset) }
                text.copyText = { [weak self] range in self?.markdownCopy(column: i, range: range) }
            }
            scrolls[i].documentView = text
            return text
        }
    }

    func update(_ value: NativeReadingSurface) {
        parent = value
        let identityChanged = renderedSessionID != value.sessionID || renderedDocument?.sourceRevision != value.document.sourceRevision
        let changed = identityChanged || renderedDocument != value.document || renderedTypography != value.typography || renderedLayout != value.layout || renderedLanguage != value.language || renderedWidth != value.readingWidth || renderedMarkdown != value.markdown
        let decorationChanged = renderedColor != value.correspondenceColor || renderedState != value.jobState
        if changed {
            anchorPublication?.cancel()
            updating = true
            let anchor: ReadingAnchor?
            if identityChanged {
                anchor = value.presentation.anchors[value.layout] ?? value.document.readingAnchor
                lastAnchor = nil; revealGeneration = value.presentation.revealGeneration
            } else if renderedLayout != value.layout {
                anchor = lastAnchor ?? value.presentation.anchors[value.layout] ?? value.document.readingAnchor
            } else { anchor = lastAnchor ?? value.presentation.anchors[value.layout] ?? value.document.readingAnchor }
            if (renderedMarkdown == nil) != (value.markdown == nil) { installTextViews(markdown: value.markdown != nil) }
            stackedTables = []
            index = RenderedTextIndex(document: value.document, layout: value.layout, markdown: value.markdown)
            renderedMarkdown = value.markdown
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
               let (column, ranges) = index?.highlightedRanges(selection, counterpart: true, ranges: value.presentation.displayedPhraseRanges),
               let range = ranges.first {
                updating=true
                texts[column].scrollRangeToVisible(range)
                if index?.isMarkdown == true { markdownScrolled(column: column) }
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
        let font = ReadingTextStyle.font(for: parent.typography)
        let style = ReadingTextStyle.paragraphStyle(for: parent.typography); style.paragraphSpacing = 20
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ThemeColors.source, .paragraphStyle: style, .ligature: 0]
        let paneWidths = (0..<count).map { scrolls[$0].contentSize.width }
        let widths = paneWidths.map { ReadingMetrics.textWidth(pane: $0, layout: parent.layout, preference: parent.readingWidth, window: bounds.width) }
        if let projection = parent.markdown {
            layoutMarkdown(parent, projection: projection, font: font, style: style, widths: widths, anchor: anchor)
            if stabilizeScrollers, (0..<count).contains(where: { abs(paneWidths[$0] - scrolls[$0].contentSize.width) > 0.5 }) {
                layoutText(anchor: anchor, stabilizeScrollers: false)
            }
            return
        }
        let attributed = [NSMutableAttributedString(string: index.strings[0], attributes: base), NSMutableAttributedString(string: index.strings[1], attributes: base)]
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
               let (column, ranges) = index.displayRanges(selection, counterpart: false, ranges: [selection.range]),
               column == col, let projected = ranges.first {
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

    private func layoutMarkdown(_ parent: NativeReadingSurface, projection: MarkdownReadingProjection, font: NSFont,
                                style: NSParagraphStyle, widths: [CGFloat], anchor: ReadingAnchor?) {
        let stack = MarkdownReaderStyles.stackedTableIDs(in: projection, width: widths.min() ?? 0, fontSize: font.pointSize)
        if stack != stackedTables {
            stackedTables = stack
            index = RenderedTextIndex(document: parent.document, layout: parent.layout, markdown: projection,
                                      stackedTables: stack, columnLabel: AppLocalization.text("Column", language: parent.language))
        }
        guard let index else { return }
        let attributed = widths.indices.map { column in
            MarkdownReaderStyles.attributed(index: index, column: column, sourceMode: projection.isSourceMode,
                                            font: font, baseStyle: style, width: widths[column], stackedTables: stack)
        }
        for column in widths.indices {
            let text = texts[column]
            text.textContainerInset = NSSize(width: max(0, (scrolls[column].contentSize.width - widths[column]) / 2), height: 24)
            text.textContainer?.containerSize = NSSize(width: widths[column], height: CGFloat.greatestFiniteMagnitude)
            guard let storage = text.textStorage else { continue }
            storage.beginEditing()
            if !TextIdentity.equal(storage.string, attributed[column].string) {
                replaceDifference(in: storage, with: attributed[column])
            }
            attributed[column].enumerateAttributes(in: NSRange(location: 0, length: attributed[column].length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        }
        if widths.count == 2 {
            // Align corresponding blocks, keeping a whole table together.
            // Distribute length differences throughout a section.
            let measured = widths.indices.map { column in
                let groups = index.markdownAlignmentGroups[column]
                let tops = groups.map { markdownRect(at: $0.span.range.location, column: column).minY }
                let end = markdownTextHeight(column: column) + texts[column].textContainerOrigin.y
                return tops.indices.map { i in max(0, (i + 1 < tops.count ? tops[i + 1] : end) - tops[i]) }
            }
            for column in widths.indices {
                guard let storage = texts[column].textStorage else { continue }
                storage.beginEditing()
                for (i, group) in index.markdownAlignmentGroups[column].enumerated() where measured[1 - column].indices.contains(i) {
                    let extra = measured[1 - column][i] - measured[column][i]
                    guard extra > 0.5,
                          let spacerStyle = attributed[column].attribute(.paragraphStyle, at: group.spacer.location, effectiveRange: nil) as? NSParagraphStyle,
                          let padded = spacerStyle.mutableCopy() as? NSMutableParagraphStyle else { continue }
                    padded.paragraphSpacing += extra
                    attributed[column].addAttribute(.paragraphStyle, value: padded, range: group.spacer)
                    storage.addAttribute(.paragraphStyle, value: padded, range: group.spacer)
                }
                storage.endEditing()
            }
        }
        markdownAttributes = attributed
        markdownPositions = [[], []]
        for column in widths.indices {
            let text = texts[column]
            scrolls[column].layoutSubtreeIfNeeded()
            let height = markdownTextHeight(column: column)
            text.setFrameSize(NSSize(width: scrolls[column].contentSize.width,
                                     height: max(scrolls[column].contentSize.height, height + 48)))
            var groupIndex = 0
            for span in index.paragraphs[column] where span.range.length > 0 {
                let groups = index.markdownGroups[column]
                while groupIndex + 1 < groups.count, span.range.location >= NSMaxRange(groups[groupIndex].spacer) {
                    groupIndex += 1
                }
                guard groups.indices.contains(groupIndex) else { continue }
                let first = markdownRect(at: span.range.location, column: column)
                let last = markdownRect(at: NSMaxRange(span.range) - 1, column: column)
                markdownPositions[column].append(.init(span: span, groupID: groups[groupIndex].span.paragraphID, frame: first.union(last)))
            }
        }
        if widths.count == 2 {
            let height = max(texts[0].frame.height, texts[1].frame.height)
            for text in texts { text.setFrameSize(NSSize(width: text.frame.width, height: height)) }
        }
        for column in 0...1 {
            var restoredRange = NSRange(location: 0, length: 0)
            if column < widths.count, let selection = parent.presentation.selection,
               let (selectedColumn, ranges) = index.displayRanges(selection, counterpart: false, ranges: [selection.range]),
               selectedColumn == column, let first = ranges.first, let last = ranges.last,
               NSMaxRange(last) - first.location == selection.range.length {
                restoredRange = NSUnionRange(first, last)
            }
            texts[column].setSelectedRange(restoredRange)
        }
        appliedHighlights = [[], []]
        if let anchor { restoreMarkdown(anchor) }
        else { for column in widths.indices { scrollMarkdown(column: column, to: 0) } }
    }

    private func markdownTextHeight(column: Int) -> CGFloat {
        let text = texts[column]
        guard let manager = text.layoutManager, let container = text.textContainer else { return 0 }
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).maxY
    }

    private func markdownRect(at offset: Int, column: Int) -> NSRect {
        let text = texts[column]
        guard let manager = text.layoutManager, let container = text.textContainer,
              offset >= 0, offset < (text.textStorage?.length ?? 0) else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let rect = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil, withoutAdditionalLayout: true)
        return rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    private func scrollMarkdown(column: Int, to y: CGFloat) {
        let scroll = scrolls[column]
        let top = min(max(0, y), max(0, texts[column].bounds.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func markdownScrolled(column: Int) {
        guard let parent, let index else { return }
        if parent.layout == .sideBySide {
            updating = true
            scrollMarkdown(column: 1 - column, to: scrolls[column].contentView.bounds.minY)
            updating = false
        }
        let y = scrolls[column].contentView.bounds.minY + 4
        let positions = markdownPositions[column]
        // Cells share a row and can have differing heights. Pick the first
        // candidate that intersects the viewport's leading edge.
        let position = positions.first(where: { $0.frame.minY <= y && $0.frame.maxY > y })
            ?? positions.last(where: { $0.frame.minY <= y })
            ?? positions.first
        if let position {
            let span = position.span
            let fraction = Double(min(1, max(0, (y - position.frame.minY) / max(1, position.frame.height))))
            let anchor = ReadingAnchor(paragraphID: span.paragraphID, side: span.side, fraction: fraction,
                                       sectionID: position.groupID)
            lastAnchor = anchor
            publishMarkdownAnchor(anchor)
        } else if let first = index.markdownGroups[column].first {
            let anchor = ReadingAnchor(paragraphID: first.span.paragraphID, side: first.span.side, fraction: 0,
                                       sectionID: first.span.paragraphID)
            publishMarkdownAnchor(anchor)
        }
    }

    private func publishMarkdownAnchor(_ anchor: ReadingAnchor) {
        lastAnchor = anchor
        anchorPublication?.cancel()
        let publication = DispatchWorkItem { [weak self] in self?.parent?.onAnchor(anchor) }
        anchorPublication = publication
        // Persist after a short idle period; dragging only touches cached geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: publication)
    }

    private func restoreMarkdown(_ anchor: ReadingAnchor, only: Int? = nil) {
        guard let parent, let index else { return }
        let count = parent.layout == .sideBySide ? 2 : 1
        for column in 0..<count where only == nil || only == column {
            let side = count == 2 ? (column == 0 ? ReadingSide.source : .translation) : anchor.side
            let positions = markdownPositions[column]
            let match = positions.first { $0.span.paragraphID == anchor.paragraphID && $0.span.side == side }
                ?? (count == 1 ? positions.first { $0.span.paragraphID == anchor.paragraphID && $0.span.side == .source } : nil)
            if let position = match {
                let span = position.span
                let fraction = min(1, max(0, anchor.fraction))
                var top = position.frame.minY + CGFloat(fraction) * max(0, position.frame.height - 4)
                if span.side == anchor.side, parent.markdown?.isSourceMode == false,
                   let offset = anchor.offset, offset >= 0, offset < span.range.length {
                    top = markdownRect(at: span.range.location + offset, column: column).minY
                }
                scrollMarkdown(column: column, to: top)
            } else if let group = index.markdownGroups[column].first(where: {
                $0.span.paragraphID == (anchor.sectionID ?? anchor.paragraphID) && $0.span.side == side
            }) {
                scrollMarkdown(column: column, to: markdownRect(at: group.span.range.location, column: column).minY)
            }
        }
        if count == 2, only == nil {
            let leading = anchor.side == .translation ? 1 : 0
            scrollMarkdown(column: 1 - leading, to: scrolls[leading].contentView.bounds.minY)
        }
        lastAnchor = anchor
    }

    private func decorateMarkdown(_ parent: NativeReadingSurface, index: RenderedTextIndex) {
        let completedBlocks = Set(index.paragraphs.flatMap { $0.filter { $0.side == .translation && $0.range.length > 0 }.map(\.paragraphID) })
        for column in 0...1 {
            var rules: [NSRect] = []
            var unfinished: [NSRect] = []
            if parent.layout == .paragraphs {
                for group in index.markdownGroups[column] where group.span.side == .translation && group.span.range.length > 0 {
                    let first = markdownRect(at: group.span.range.location, column: column)
                    let last = markdownRect(at: NSMaxRange(group.span.range) - 1, column: column)
                    rules.append(NSRect(x: first.minX - 12, y: first.minY, width: 2, height: max(12, last.maxY - first.minY)))
                }
            }
            if [.paused, .failed, .running, .queued].contains(parent.jobState) {
                for position in markdownPositions[column] where position.span.side == .source && !completedBlocks.contains(position.span.paragraphID) {
                    let frame = position.frame
                    unfinished.append(NSRect(x: frame.minX - 12, y: frame.minY + 6, width: 3, height: 12))
                }
            }
            texts[column].rules = rules
            texts[column].unfinished = unfinished
            texts[column].needsDisplay = true
        }
    }

    private func markdownCopy(column: Int, range: NSRange) -> String? {
        guard let index, index.isMarkdown, range.length > 0,
              let text = index.strings[column].substring(utf16: .init(location: range.location, length: range.length)) else { return nil }
        let copy = NSMutableString(string: text)
        for spacer in index.generatedSpacers[column].reversed() {
            let intersection = NSIntersectionRange(range, spacer)
            if intersection.length > 0 {
                copy.deleteCharacters(in: NSRange(location: intersection.location - range.location, length: intersection.length))
            }
        }
        return copy as String
    }

    private func contextLink(column: Int, offset: Int) -> (title: String, action: () -> Void)? {
        guard let parent, let index, parent.markdown?.isSourceMode == false,
              let value = index.markdownRuns[column].first(where: {
                  NSLocationInRange(offset, $0.span.range) && ($0.run.destination != nil || $0.run.linkTargetBlockID != nil)
              }) else { return nil }
        let title = AppLocalization.text("Open Link", language: parent.language)
        if let block = value.run.linkTargetBlockID,
           let position = markdownPositions[column].first(where: { $0.span.paragraphID == block && $0.span.side == value.span.side }) {
            return (title, { [weak self] in self?.scrollMarkdown(column: column, to: position.frame.minY) })
        }
        guard let destination = value.run.destination, let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return (title, { NSWorkspace.shared.open(url) })
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
                let phrases=parent.presentation.displayedPhraseRanges
                guard let (column, ranges) = index.highlightedRanges(selection, counterpart: counterpart, ranges: counterpart ? phrases : []) else { continue }
                desired[column] += ranges
            }
        }
        let color = ThemeColors.correspondence(parent.correspondenceColor)
        let underline: NSUnderlineStyle = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .thick : .single
        for col in 0...1 where force || desired[col] != appliedHighlights[col] {
            guard let storage=texts[col].textStorage else { continue }
            storage.beginEditing()
            for range in appliedHighlights[col] where NSMaxRange(range) <= storage.length {
                for key in [NSAttributedString.Key.backgroundColor,.underlineStyle,.underlineColor] {
                    storage.removeAttribute(key,range:range)
                    if index.isMarkdown, markdownAttributes.indices.contains(col), NSMaxRange(range) <= markdownAttributes[col].length {
                        markdownAttributes[col].enumerateAttribute(key, in: range) { value, original, _ in
                            if let value { storage.addAttribute(key, value: value, range: original) }
                        }
                    }
                }
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
        let help = index.isMarkdown ? "Each original section is followed by its translation." : "Each original paragraph is followed by its translation."
        texts[0].setAccessibilityHelp(combined ? AppLocalization.text(help, language: parent.language) : nil)
        texts[1].setAccessibilityLabel(AppLocalization.text("Translation", language: parent.language))
        emptyMessage.stringValue = AppLocalization.text("Translation will appear here", language: parent.language)
        emptyMessage.isHidden = parent.layout != .sideBySide || parent.jobState != .idle ||
            !parent.document.translations.isEmpty || (index.isMarkdown && index.markdownGroups[1].contains { $0.span.range.length > 0 })
        if index.isMarkdown {
            decorateMarkdown(parent, index: index)
            return
        }
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
        if index?.isMarkdown == true { return markdownRect(at: span.range.location, column: column) }
        guard let manager = texts[column].textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(content.documentRange.location,offsetBy:span.range.location),
              let fragment = manager.textLayoutFragment(for:location) else { return .zero }
        return fragment.layoutFragmentFrame.offsetBy(dx:texts[column].textContainerInset.width,dy:texts[column].textContainerInset.height)
    }
    @objc private func scrolled(_ notification: Notification) {
        guard !updating, let index, let column = scrolls.firstIndex(where: { $0.contentView === notification.object as? NSClipView }) else { return }
        if index.isMarkdown {
            markdownScrolled(column: column)
            return
        }
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
        if index.isMarkdown {
            restoreMarkdown(anchor, only: only)
            return
        }
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
    var typography: ReadingTypography
    public init(text: Binding<String>, isComposing: Binding<Bool>, language: InterfaceLanguage = .english, typography: ReadingTypography = .init()) { _text = text; _isComposing = isComposing; self.language = language; self.typography = typography }
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
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.font = ReadingTextStyle.font(for: typography)
        text.defaultParagraphStyle = ReadingTextStyle.paragraphStyle(for: typography)
        text.typingAttributes = [.font: ReadingTextStyle.font(for: typography), .paragraphStyle: ReadingTextStyle.paragraphStyle(for: typography), .ligature: 0, .foregroundColor: NSColor.textColor]
        text.textContainerInset = NSSize(width:18,height:18)
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
        guard !view.hasMarkedText() else { return }
        if !TextIdentity.equal(view.string,text) { view.string = text }
        let font = ReadingTextStyle.font(for: typography)
        let style = ReadingTextStyle.paragraphStyle(for: typography)
        if view.font != font || view.defaultParagraphStyle != style {
            view.font = font
            view.defaultParagraphStyle = style
            view.textStorage?.addAttributes([.font: font, .paragraphStyle: style, .ligature: 0, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: (view.string as NSString).length))
        }
        view.typingAttributes = [.font: font, .paragraphStyle: style, .ligature: 0, .foregroundColor: NSColor.textColor]
    }
}

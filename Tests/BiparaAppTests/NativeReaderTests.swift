import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import SwiftUI
import Testing

@MainActor @Suite("Native TextKit reading state")
struct NativeReaderTests {
    @Test func nativeMarkedTextPreventsApplyUntilCommit() async throws {
        _ = NSApplication.shared
        let app=AppRuntime(gateway:ScriptedGateway(),keychain:FaultCredentials(),defaults:UserDefaults(suiteName:"dev.bipara.ime-test.\(UUID())")!)
        app.newTab();let session=try #require(app.activeSession)
        let parent=SourceEditorView(text:Binding(get:{app.workspace.tabs[0].draftText},set:{value in app.workspace.withTab(0){$0.draftText=value}}),isComposing:Binding(get:{app.composing.contains(session)},set:{value in if value{app.composing.insert(session)}else{app.composing.remove(session)}}))
        let coordinator=parent.makeCoordinator(),text=SourceTextView(usingTextLayoutManager:true)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=text;text.delegate=coordinator
        defer{withExtendedLifetime(coordinator){window.close()}}
        text.setMarkedText("中",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        #expect(text.hasMarkedText());#expect(app.composing.contains(session))
        await #expect(throws:AppRuntime.ActionError.composing){try await app.apply(session)}
        #expect(app.workspace.tabs[0].document.source.isEmpty)
        text.insertText("中文",replacementRange:text.markedRange())
        #expect(!text.hasMarkedText());#expect(!app.composing.contains(session))
        try await app.apply(session)
        #expect(app.workspace.tabs[0].document.source == "中文")
    }
    private func surface(_ document:BiparaDocument,session:UUID,layout:LayoutMode,presentation:ReadingPresentation,typography:ReadingTypography = .init()) -> NativeReadingSurface {
        .init(sessionID:session,document:document,layout:layout,typography:typography,presentation:presentation,language:.english,onSelect:{_ in},onHover:{_ in},onAnchor:{_ in})
    }
    private func texts(_ reader:ParallelReader) -> [NSTextView] {
        reader.subviews.compactMap{($0 as? NSScrollView)?.documentView as? NSTextView}
    }
    private func nativePoint(_ text:NSTextView,offset:Int) throws -> NSPoint {
        let manager=try #require(text.textLayoutManager),content=try #require(manager.textContentManager)
        manager.ensureLayout(for:manager.documentRange)
        let location=try #require(content.location(content.documentRange.location,offsetBy:offset))
        let fragment=try #require(manager.textLayoutFragment(for:location))
        let relative=content.offset(from:fragment.rangeInElement.location,to:location)
        let line=try #require(fragment.textLineFragments.first{NSLocationInRange(relative,$0.characterRange)})
        return NSPoint(x:text.textContainerInset.width+4,y:fragment.layoutFragmentFrame.minY+line.typographicBounds.minY+text.textContainerInset.height+2)
    }
    private func window(_ reader:ParallelReader) -> NSWindow {
        _ = NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=reader
        reader.frame=NSRect(x:0,y:0,width:1000,height:700)
        return window
    }
    @Test func translatedSelectionSurvivesBothLayoutsAndFontChange() throws {
        let w=WorkspaceStore();try w.newTab(source:"Hello window.\n\nAnother paragraph.",direction:.enToZh)
        var document=w.tabs[0].document
        document.translations=document.units.map{.init(unitID:$0.id,text:"窗户开着。",returnedModel:nil,completedAt:Date())}
        let reader=ParallelReader(),window=window(reader),session=UUID()
        defer{window.close()}
        var presentation=ReadingPresentation()
        presentation.selection = .init(paragraphID:document.paragraphs[0].id,unitID:document.units[0].id,side:.translation,range:.init(location:0,length:2))
        reader.update(surface(document,session:session,layout:.sideBySide,presentation:presentation))
        let views=texts(reader)
        #expect(views[0].selectedRange().length == 0)
        #expect((views[1].string as NSString).substring(with:views[1].selectedRange()) == "窗户")
        reader.update(surface(document,session:session,layout:.paragraphs,presentation:presentation))
        #expect((views[0].string as NSString).substring(with:views[0].selectedRange()) == "窗户")
        #expect(views[1].selectedRange().length == 0)
        var font=ReadingTypography();font.size=28
        reader.update(surface(document,session:session,layout:.sideBySide,presentation:presentation,typography:font))
        #expect(views[0].selectedRange().length == 0)
        #expect((views[1].string as NSString).substring(with:views[1].selectedRange()) == "窗户")
        reader.update(surface(document,session:UUID(),layout:.sideBySide,presentation:.init(),typography:font))
        #expect(views.allSatisfy{$0.selectedRange().length == 0})
    }
    @Test func counterpartHighlightSurvivesNativeRelayout() throws {
        let w=WorkspaceStore();try w.newTab(source:"The window is open.",direction:.enToZh)
        var doc=w.tabs[0].document
        doc.translations=[.init(unitID:doc.units[0].id,text:"窗户开着。",returnedModel:nil,completedAt:Date())]
        let reader=ParallelReader(),window=window(reader)
        defer{window.close()}
        var state=ReadingPresentation()
        state.selection = .init(paragraphID:doc.paragraphs[0].id,unitID:doc.units[0].id,side:.source,range:.init(location:4,length:6))
        state.phraseRanges=[.init(location:0,length:2)]
        reader.update(surface(doc,session:UUID(),layout:.sideBySide,presentation:state))
        let target=texts(reader)[1],storage=try #require(target.textStorage)
        target.textLayoutManager?.ensureLayout(for:target.textLayoutManager!.documentRange)
        #expect(storage.attribute(.backgroundColor,at:0,effectiveRange:nil) as? NSColor != nil)
        #expect(storage.attribute(.underlineStyle,at:0,effectiveRange:nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(storage.attribute(.backgroundColor,at:2,effectiveRange:nil) == nil)
        #expect(target.string == "窗户开着。")
    }
    @Test func revealShowsOffscreenPhraseInsideLongCounterpart() throws {
        let w=WorkspaceStore();try w.newTab(source:"The window is open.",direction:.enToZh)
        var doc=w.tabs[0].document
        let target=String(repeating:"这是一句示例译文。",count:200)+"目标词"+String(repeating:"这是后面的示例译文。",count:50)
        #expect(target.utf8.count <= 8192);#expect(!target.contains(where:{$0.isNewline}))
        doc.translations=[.init(unitID:doc.units[0].id,text:target,returnedModel:nil,completedAt:Date())]
        let phrase=(target as NSString).range(of:"目标词"),reader=ParallelReader(),window=window(reader),session=UUID()
        defer{window.close()}
        var state=ReadingPresentation()
        state.selection = .init(paragraphID:doc.paragraphs[0].id,unitID:doc.units[0].id,side:.source,range:.init(location:4,length:6))
        state.phraseRanges=[.init(location:phrase.location,length:phrase.length)]
        reader.update(surface(doc,session:session,layout:.sideBySide,presentation:state))
        let text=texts(reader)[1],clip=try #require(text.enclosingScrollView?.contentView),point=try nativePoint(text,offset:phrase.location)
        #expect(!clip.documentVisibleRect.contains(point))
        let originalPosition=texts(reader)[0].enclosingScrollView?.contentView.bounds.origin
        state.revealGeneration += 1
        reader.update(surface(doc,session:session,layout:.sideBySide,presentation:state))
        #expect(clip.documentVisibleRect.contains(point))
        #expect(texts(reader)[0].enclosingScrollView?.contentView.bounds.origin == originalPosition)
    }
    @Test func explicitRevealSupportsHoverWithoutSelection() throws {
        let w=WorkspaceStore();try w.newTab(source:(1...80).map{"Paragraph \($0)."}.joined(separator:"\n\n"),direction:.enToZh)
        var doc=w.tabs[0].document
        doc.translations=doc.units.enumerated().map{.init(unitID:$0.element.id,text:"译文\($0.offset)",returnedModel:nil,completedAt:Date())}
        let unit=doc.units[60],reader=ParallelReader(),window=window(reader),session=UUID()
        defer{window.close()}
        var state=ReadingPresentation()
        state.hover = .init(paragraphID:unit.paragraphID,unitID:unit.id,side:.source,range:.init(location:0,length:0))
        reader.update(surface(doc,session:session,layout:.sideBySide,presentation:state))
        let text=texts(reader)[1],clip=try #require(text.enclosingScrollView?.contentView)
        let point=try nativePoint(text,offset:(text.string as NSString).range(of:"译文60").location)
        #expect(state.selection == nil);#expect(state.pinned == nil)
        #expect(!clip.documentVisibleRect.contains(point))
        let originalPosition=texts(reader)[0].enclosingScrollView?.contentView.bounds.origin
        state.revealGeneration += 1
        reader.update(surface(doc,session:session,layout:.sideBySide,presentation:state))
        #expect(clip.documentVisibleRect.contains(point))
        #expect(texts(reader)[0].enclosingScrollView?.contentView.bounds.origin == originalPosition)
    }
    @Test func userScrollReportsVisibleParagraphAcrossBlankLines() throws {
        let w=WorkspaceStore();try w.newTab(source:(1...80).map{"Paragraph \($0). " + String(repeating:"An example sentence. ",count:8)}.joined(separator:"\r\n\r\n"),direction:.enToZh)
        let doc=w.tabs[0].document,reader=ParallelReader(),window=window(reader)
        defer{window.close()}
        var observed:ReadingAnchor?
        let parent=NativeReadingSurface(sessionID:UUID(),document:doc,layout:.sideBySide,typography:.init(),presentation:.init(),language:.english,onSelect:{_ in},onHover:{_ in},onAnchor:{observed=$0})
        reader.update(parent)
        let text=texts(reader)[0],manager=try #require(text.textLayoutManager),content=try #require(manager.textContentManager)
        #expect(TextIdentity.equal(text.string,doc.source))
        let paragraph=doc.paragraphs[40],location=try #require(content.location(content.documentRange.location,offsetBy:paragraph.sourceRange.location))
        let fragment=try #require(manager.textLayoutFragment(for:location)),clip=try #require(text.enclosingScrollView?.contentView)
        clip.scroll(to:NSPoint(x:0,y:fragment.layoutFragmentFrame.minY+text.textContainerInset.height+4))
        text.enclosingScrollView?.reflectScrolledClipView(clip)
        #expect(observed?.paragraphID == paragraph.id)
        let alternating=RenderedTextIndex(document:doc,layout:.paragraphs)
        #expect(!alternating.strings[0].contains("Not translated yet"))
        #expect(!alternating.strings[0].contains("Original\n"))
    }
    @Test(arguments:[NSScroller.Style.legacy,.overlay])
    func layoutKeepsLogicalParagraphAndCopiedTabStartsAtTop(scrollerStyle:NSScroller.Style) throws {
        let w=WorkspaceStore()
        try w.newTab(source:(1...220).map{"Paragraph \($0). " + String(repeating:"A useful example sentence. ",count:20)}.joined(separator:"\n\n"),direction:.enToZh)
        let document=w.tabs[0].document,session=UUID(),reader=ParallelReader(),window=window(reader)
        defer{window.close()}
        reader.subviews.compactMap{$0 as? NSScrollView}.forEach{$0.scrollerStyle=scrollerStyle}
        var presentation=ReadingPresentation()
        let paragraph=document.paragraphs[150].id
        presentation.anchors[.sideBySide] = .init(paragraphID:paragraph,side:.source,fraction:0.35)
        reader.update(surface(document,session:session,layout:.sideBySide,presentation:presentation))
        func visibleParagraph(_ layout:LayoutMode) throws -> UUID {
            let text=texts(reader)[0],clip=try #require(text.enclosingScrollView?.contentView)
            let container=try #require(text.textContainer)
            let expectedWidth=ReadingMetrics.textWidth(pane:clip.bounds.width,layout:layout,preference:.wide,window:reader.bounds.width)
            #expect(abs(container.containerSize.width-expectedWidth) < 0.5)
            let index=RenderedTextIndex(document:document,layout:layout)
            let offset=text.characterIndexForInsertion(at:NSPoint(x:text.textContainerInset.width+4,y:clip.bounds.minY+8))
            let visible=index.selection(column:0,range:NSRange(location:offset,length:0))
            return try #require(visible?.paragraphID,"layout \(layout), clip \(clip.bounds), text \(text.frame), native hit offset \(offset)")
        }
        let before=try visibleParagraph(.sideBySide)
        #expect(document.paragraphs.firstIndex(where:{$0.id == before}) == 150)
        reader.update(surface(document,session:session,layout:.paragraphs,presentation:presentation))
        #expect(try visibleParagraph(.paragraphs) == paragraph)
        reader.update(surface(document,session:session,layout:.sideBySide,presentation:presentation))
        #expect(try visibleParagraph(.sideBySide) == paragraph)
        reader.update(surface(document,session:UUID(),layout:.sideBySide,presentation:.init()))
        #expect(texts(reader)[0].enclosingScrollView?.contentView.bounds.minY == 0)
    }
}

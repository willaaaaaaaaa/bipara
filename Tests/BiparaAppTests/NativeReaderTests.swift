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
    private func surface(_ document:BiparaDocument,session:UUID,layout:LayoutMode,presentation:ReadingPresentation = .init(),typography:ReadingTypography = .init()) -> NativeReadingSurface {
        .init(sessionID:session,document:document,layout:layout,typography:typography,presentation:presentation,language:.english,onAnchor:{_ in})
    }
    private func texts(_ reader:ParallelReader) -> [NSTextView] {
        reader.subviews.compactMap{($0 as? NSScrollView)?.documentView as? NSTextView}
    }
    private func window(_ reader:ParallelReader) -> NSWindow {
        _ = NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=reader
        reader.frame=NSRect(x:0,y:0,width:1000,height:700)
        return window
    }
    @Test func nativeSelectionStaysInOnePaneAcrossFontChange() throws {
        let w=WorkspaceStore();try w.newTab(source:"Hello window.\n\nAnother paragraph.",direction:.enToZh)
        var document=w.tabs[0].document
        document.translations=document.units.map{.init(unitID:$0.id,text:"窗户开着。",returnedModel:nil,completedAt:Date())}
        let reader=ParallelReader(),window=window(reader),session=UUID()
        defer{window.close()}
        reader.update(surface(document,session:session,layout:.sideBySide))
        let views=texts(reader)
        views[1].setSelectedRange(NSRange(location: 0, length: 2))
        var font=ReadingTypography();font.size=28
        reader.update(surface(document,session:session,layout:.sideBySide,typography:font))
        #expect(views[0].selectedRange().length == 0)
        #expect((views[1].string as NSString).substring(with:views[1].selectedRange()) == "窗户")
        #expect(views[0].textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        reader.update(surface(document,session:UUID(),layout:.sideBySide,typography:font))
        #expect(views.allSatisfy{$0.selectedRange().length == 0})
    }
    @Test func userScrollReportsVisibleParagraphAcrossBlankLines() throws {
        let w=WorkspaceStore();try w.newTab(source:(1...80).map{"Paragraph \($0). " + String(repeating:"An example sentence. ",count:8)}.joined(separator:"\r\n\r\n"),direction:.enToZh)
        let doc=w.tabs[0].document,reader=ParallelReader(),window=window(reader)
        defer{window.close()}
        var observed:ReadingAnchor?
        let parent=NativeReadingSurface(sessionID:UUID(),document:doc,layout:.sideBySide,typography:.init(),presentation:.init(),language:.english,onAnchor:{observed=$0})
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
            let visible = index.paragraphs[0].first { NSLocationInRange(offset, $0.range) }
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

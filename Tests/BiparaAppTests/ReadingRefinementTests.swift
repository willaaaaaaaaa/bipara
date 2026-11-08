import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor @Suite("Reading refinements")
struct ReadingRefinementTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName:"dev.bipara.reading.\(UUID())")! }
    private func snapshot(_ document:BiparaDocument) -> JobSnapshot {
        .init(jobID:UUID(),sourceRevision:document.sourceRevision,sourceLanguage:.en,targetLanguage:.zh,
              provider:"openai",model:"fixture",profile:WorkerContract.currentProfiles["openai"]!,effort:.auto,
              translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1")
    }

    @Test func oldPreferencesDefaultNewFieldsAndDraftSaveCancelPreserveModels() throws {
        let keys=FaultCredentials(),defs=defaults(),store=SettingsStore(defaults:defs,keychain:keys)
        store.updateDraft { $0.interfaceLanguage = .simplifiedChinese; $0.typography.size = 23 }
        try store.saveDraft()
        let original=store.record
        var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        for key in ["preferredReadingWidth","preferredCorrespondenceColor","skipDocumentSavePrompt"] { object.removeValue(forKey:key) }
        defs.set(try JSONSerialization.data(withJSONObject:object),forKey:SettingsStore.defaultsKey)
        let migrated=SettingsStore(defaults:defs,keychain:keys)
        #expect(migrated.record.readingWidth == .wide)
        #expect(migrated.record.correspondenceColor == .amber)
        #expect(!migrated.record.dontAskToSaveOnClose)
        migrated.updateDraft { $0.preferredReadingWidth = .window; $0.preferredCorrespondenceColor = .purple; $0.skipDocumentSavePrompt = true }
        migrated.cancelDraft()
        #expect(migrated.draft == migrated.record)
        migrated.updateDraft { $0.preferredReadingWidth = .standard; $0.preferredCorrespondenceColor = .teal; $0.skipDocumentSavePrompt = true }
        try migrated.saveDraft()
        let reloaded=SettingsStore(defaults:defs,keychain:keys)
        #expect(reloaded.record.readingWidth == .standard)
        #expect(reloaded.record.correspondenceColor == .teal)
        #expect(reloaded.record.dontAskToSaveOnClose)
        #expect(reloaded.record.interfaceLanguage == .simplifiedChinese)
        #expect(reloaded.record.typography == original.typography)
        #expect(reloaded.record.modelConfigurations == original.modelConfigurations)
        #expect(keys.writes == 0)
    }

    @Test func meaningfulTitlesKeepSourceIdentityAndOpenedTitles() throws {
        let w=WorkspaceStore()
        try w.newTab();try w.newTab()
        #expect(w.tabs.map(\.document.title) == ["Untitled 1","Untitled 2"])
        w.closeTab(at:0);try w.newTab()
        #expect(w.tabs.last?.document.title == "Untitled 3")
        let source="\r\n---\r\n```markdown\r\n# Useful heading 👨‍👩‍👧\r\nBody."
        let id=w.tabs[0].document.documentID
        w.withTab(0) { $0.draftText=source }
        try w.applyDraft(at:0)
        #expect(w.tabs[0].document.title == "Useful heading 👨‍👩‍👧")
        #expect(TextIdentity.equal(w.tabs[0].document.source,source))
        #expect(w.tabs[0].document.documentID == id)
        #expect(DocumentTitle.derive(from:"👨‍👩‍👧\n---\n1. 中文标题") == "中文标题")
        #expect(DocumentTitle.derive(from:String(repeating:"a\u{301}",count:70)).count == 48)
        var opened=w.tabs[0].document;opened.title="Saved title"
        w.openDocument(opened,at:URL(fileURLWithPath:"/tmp/reading-title-fixture.bipara"))
        let index=try #require(w.activeTabIndex)
        w.withTab(index) { $0.draftText="Changed source." }
        try w.applyDraft(at:index)
        #expect(w.tabs[index].document.title == "Saved title")
    }

    @Test func importUsesMeaningfulFilenameWithoutChangingSource() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("Reading notes.txt"),source="---\r\nFirst content."
        try Data(source.utf8).write(to:url)
        let app=AppRuntime(gateway:ScriptedGateway(),keychain:FaultCredentials(),defaults:defaults())
        await app.open(url)
        let tab=try #require(app.workspace.activeTab)
        #expect(tab.document.title == "Reading notes")
        #expect(TextIdentity.equal(tab.document.source,source))
        app.workspace.withTab(0) { $0.draftText="A different first line." }
        try await app.apply(tab.sessionID)
        #expect(app.workspace.activeTab?.document.title == "Reading notes")
    }

    @Test func monotonicTimeSpansQueueParallelBatchesPauseRetryAndReplacement() throws {
        let start=ContinuousClock.now
        var time=start
        let w=WorkspaceStore(now:{time})
        try w.newTab(source:"First. Second.")
        let snap=snapshot(w.tabs[0].document),units=w.tabs[0].document.units
        w.withTab(0) { _ = $0.job.apply(.translate(snapshot:snap,batches:[0,1],totalNonblankUnits:units.count)) }
        time=start.advanced(by:.seconds(4))
        w.withTab(0) { _ = $0.job.apply(.batchDispatched(batchID:0)); _ = $0.job.apply(.batchDispatched(batchID:1)) }
        time=start.advanced(by:.seconds(11))
        w.withTab(0) { _ = $0.job.apply(.cancel) }
        #expect(w.tabs[0].elapsed.seconds(at:time) == 11)
        time=start.advanced(by:.seconds(111))
        #expect(w.tabs[0].elapsed.seconds(at:time) == 11)
        w.withTab(0) { _ = $0.job.apply(.resume(batches:[0,1])) }
        time=start.advanced(by:.seconds(116))
        w.withTab(0) { _ = $0.job.apply(.batchDispatched(batchID:0)); _ = $0.job.apply(.batchFailed(batchID:0)) }
        time=start.advanced(by:.seconds(200))
        #expect(w.tabs[0].elapsed.seconds(at:time) == 16)
        let fresh=snapshot(w.tabs[0].document)
        w.withTab(0) { _ = $0.job.apply(.retranslate(snapshot:fresh,batches:[0])) }
        #expect(w.tabs[0].elapsed.seconds(at:time) == 0)
        #expect(TranslationElapsed.format(seconds:9) == "9s")
        #expect(TranslationElapsed.format(seconds:83) == "1m 23s")
        #expect(TranslationElapsed.format(seconds:3840) == "1h 04m")
    }

    @Test func reopeningNeverInventsElapsedTimeOrDirtiesDocument() throws {
        let w=WorkspaceStore();try w.newTab(source:"Hello.")
        var doc=w.tabs[0].document;doc.jobSnapshot=snapshot(doc)
        doc.resolvedDirection = .enToZh
        doc.translations=[.init(unitID:doc.units[0].id,text:"你好。",completedAt:Date())]
        let reopened=try DocumentCodec.decode(DocumentCodec.encode(doc))
        w.openDocument(reopened,at:URL(fileURLWithPath:"/tmp/reading-elapsed-fixture.bipara"))
        let tab=try #require(w.activeTab)
        #expect(!tab.elapsed.hasActivity);#expect(tab.elapsed.sinceOpen)
        #expect(!tab.isDirty)
        #expect(!String(decoding:try DocumentCodec.encode(tab.document),as:UTF8.self).contains("elapsed"))
    }

    @Test(arguments:[false,true]) func skipSaveOnlyControlsDocumentReview(skip:Bool) async throws {
        let app=AppRuntime(gateway:ScriptedGateway(),keychain:FaultCredentials(),defaults:defaults())
        app.settings.updateDraft { $0.skipDocumentSavePrompt=skip };try app.settings.saveDraft()
        app.newTab();let session=try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftText="Unsaved content." }
        var alerts:[String]=[]
        app.alertHandler = { title,_,_ in alerts.append(title);return 1 }
        #expect(await app.close(session))
        #expect(alerts == (skip ? [] : ["Save changes before closing?"]))
    }

    @Test func skipSaveKeepsStopAndSettingsReviewAndNeverWritesSavedFile() async throws {
        let app=AppRuntime(gateway:ScriptedGateway(),keychain:FaultCredentials(),defaults:defaults())
        app.settings.updateDraft { $0.skipDocumentSavePrompt=true };try app.settings.saveDraft()
        try app.workspace.newTab(source:"Saved original.")
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("saved.bipara"),bytes=try DocumentCodec.encode(app.workspace.tabs[0].document)
        try bytes.write(to:url)
        app.workspace.openDocument(app.workspace.tabs[0].document,at:url)
        let index=try #require(app.workspace.activeTabIndex),session=app.workspace.tabs[index].sessionID
        let snap=snapshot(app.workspace.tabs[index].document)
        app.workspace.withTab(index) { $0.draftText="Unsaved replacement."; _ = $0.job.apply(.translate(snapshot:snap,batches:[0],totalNonblankUnits:1)) }
        var alerts:[String]=[]
        app.alertHandler = { title,_,_ in alerts.append(title);return 1 }
        #expect(!(await app.close(session)))
        #expect(alerts == ["Stop translation and close?"])
        app.alertHandler = { title,_,_ in alerts.append(title);return 0 }
        #expect(await app.close(session))
        #expect(try Data(contentsOf:url) == bytes)
        #expect(app.workspace.tabs.count == 1)
        app.settings.updateDraft { $0.appearance = .dark }
        app.alertHandler = { title,_,_ in alerts.append(title);return 2 }
        #expect(!(await app.closeSettings()))
        #expect(alerts.last == "Save Settings changes?")
    }

    @Test func globalModelSwitchDoesNotMigrateConcurrentJob() async throws {
        let gateway=ScriptedGateway(),barrier=TestBarrier(),keys=FaultCredentials(),defs=defaults()
        gateway.barrier=barrier
        let app=AppRuntime(gateway:gateway,keychain:keys,defaults:defs)
        let configurations=app.settings.record.modelConfigurations
        for config in configurations { keys.keys[config.id]="SYNTHETIC_READING_TEST" }
        defs.set(true,forKey:"dev.bipara.disclosure.openai|https://api.openai.com")
        defs.set(true,forKey:"dev.bipara.disclosure.glm|https://open.bigmodel.cn")
        try app.workspace.newTab(source:"First document.",direction:.enToZh)
        let a=app.workspace.tabs[0].sessionID
        let taskA=Task { await app.translate(a) }
        try await appWaitUntil { gateway.dispatchCount == 1 }
        try app.settings.selectActiveModel(configurations[1].id)
        try app.workspace.newTab(source:"Second document.",direction:.enToZh)
        let b=app.workspace.tabs[1].sessionID
        let taskB=Task { await app.translate(b) }
        try await appWaitUntil { gateway.dispatchCount == 2 }
        #expect(app.workspace.tabs[0].job.snapshot?.model == configurations[0].modelID)
        #expect(app.workspace.tabs[1].job.snapshot?.model == configurations[1].modelID)
        await barrier.release(1);await barrier.release(2)
        await taskA.value;await taskB.value
        #expect(app.workspace.tabs.allSatisfy { $0.job.state == .completed && $0.elapsed.hasActivity })
        #expect(app.settings.record.defaultModelConfigurationID == configurations[1].id)
    }

    @Test func pendingTextNeverBecomesSelectableContent() throws {
        let w=WorkspaceStore();try w.newTab(source:"Original content.\r\n\r\nNext paragraph.")
        let doc=w.tabs[0].document
        for layout in [LayoutMode.paragraphs,.sideBySide] {
            let index=RenderedTextIndex(document:doc,layout:layout)
            #expect(!index.strings.joined().contains("Not translated yet"))
            #expect(!index.strings[0].hasPrefix("Original\n"))
            let targetColumn=layout == .sideBySide ? 1 : 0
            #expect(index.paragraphs[targetColumn].filter { $0.side == .translation }.allSatisfy { $0.range.length == 0 })
            let source=ReadingSelection(paragraphID:doc.paragraphs[0].id,unitID:doc.units[0].id,side:.source,range:.init(location:0,length:8))
            #expect(index.span(source,counterpart:true) == nil)
        }
    }

    @Test(arguments:[AppearanceMode.light,.dark]) func paletteAndWidthChangesPreserveNativeSelection(appearance:AppearanceMode) throws {
        _ = NSApplication.shared
        let w=WorkspaceStore();try w.newTab(source:"The window is open.\n\nAnother paragraph.")
        var doc=w.tabs[0].document
        doc.translations=doc.units.map { .init(unitID:$0.id,text:"窗户开着。",completedAt:Date()) }
        let reader=ParallelReader(),session=UUID()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:2560,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:appearance == .dark ? .darkAqua : .aqua)
        window.contentView=reader;reader.frame=NSRect(x:0,y:0,width:2560,height:900)
        defer { window.close() }
        var presentation=ReadingPresentation()
        presentation.selection = .init(paragraphID:doc.paragraphs[0].id,unitID:doc.units[0].id,side:.source,range:.init(location:4,length:6))
        func update(_ width:ReadingWidth,_ color:CorrespondenceColor) {
            reader.update(.init(sessionID:session,document:doc,layout:.paragraphs,typography:.init(),presentation:presentation,language:.english,
                readingWidth:width,correspondenceColor:color,jobState:.completed,onSelect:{_ in},onHover:{_ in},onAnchor:{_ in}))
        }
        update(.standard,.blue)
        let views=reader.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ReaderTextView }
        let text=try #require(views.first)
        let selected=text.selectedRange(),storage=try #require(text.textStorage)
        #expect(text.textContainer?.containerSize.width == 800)
        let nativeSelection=text.selectedTextAttributes
        for color in CorrespondenceColor.allCases {
            update(.wide,color)
            #expect(text.selectedRange() == selected)
            #expect((text.string as NSString).substring(with:selected) == "window")
            #expect(text.textContainer?.containerSize.width == 1080)
            #expect(!text.rules.isEmpty)
            #expect(text.rules.allSatisfy { $0.minX >= 0 && $0.intersects(text.bounds) }, "Translation rules must lie inside the text view: \(text.rules)")
            let fill=try #require(storage.attribute(.backgroundColor,at:selected.location,effectiveRange:nil) as? NSColor)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                #expect(fill.usingColorSpace(.sRGB) == ThemeColors.correspondence(color).usingColorSpace(.sRGB))
            }
            #expect(text.selectedTextAttributes[.backgroundColor] as? NSColor == nativeSelection[.backgroundColor] as? NSColor)
        }
        update(.window,.amber)
        #expect(text.textContainer!.containerSize.width > 1080)
        let overlays=text.subviews.compactMap { $0 as? ReadingMarksView }
        let overlay=try #require(overlays.first),rule=try #require(text.rules.first)
        #expect(overlay.hitTest(NSPoint(x:rule.midX,y:rule.midY)) == nil)
        let capture=NSRect(x:rule.minX-3,y:rule.minY-3,width:rule.width+6,height:min(rule.height,20)+6)
        let bitmap=try #require(overlay.bitmapImageRepForCachingDisplay(in:capture))
        overlay.cacheDisplay(in:capture,to:bitmap)
        let xScale=CGFloat(bitmap.pixelsWide)/capture.width,yScale=CGFloat(bitmap.pixelsHigh)/capture.height
        let pixel=try #require(bitmap.colorAt(x:Int((rule.midX-capture.minX)*xScale),y:Int(6*yScale)))
        #expect(pixel.alphaComponent > 0.1, "The translation rule must actually render, not only have a layout rectangle.")
        window.appearance=NSAppearance(named:appearance == .dark ? .aqua : .darkAqua)
        reader.displayIfNeeded()
        #expect(text.textStorage === storage)
        #expect(text.selectedRange() == selected)
    }

    @Test func pendingColumnsKeepParagraphStartsAligned() throws {
        _ = NSApplication.shared
        let w=WorkspaceStore()
        try w.newTab(source:(1...4).map { "Paragraph \($0): " + String(repeating:"A longer example sentence. ",count:6) }.joined(separator:"\n\n"))
        let doc=w.tabs[0].document,reader=ParallelReader()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=reader;reader.frame=NSRect(x:0,y:0,width:1440,height:900)
        defer { window.close() }
        reader.update(.init(sessionID:UUID(),document:doc,layout:.sideBySide,typography:.init(),presentation:.init(),language:.english,
            jobState:.paused,onSelect:{_ in},onHover:{_ in},onAnchor:{_ in}))
        let views=reader.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ReaderTextView }
        let index=RenderedTextIndex(document:doc,layout:.sideBySide)
        func y(_ column:Int,_ offset:Int) throws -> CGFloat {
            let manager=try #require(views[column].textLayoutManager),content=try #require(manager.textContentManager)
            let location=try #require(content.location(content.documentRange.location,offsetBy:offset))
            return try #require(manager.textLayoutFragment(for:location)).layoutFragmentFrame.minY
        }
        for paragraph in doc.paragraphs where !paragraph.unitIDs.isEmpty {
            let a=try #require(index.paragraphs[0].first { $0.paragraphID == paragraph.id })
            let b=try #require(index.paragraphs[1].first { $0.paragraphID == paragraph.id })
            #expect(abs(try y(0,a.range.location) - y(1,b.range.location)) < 2)
        }
        #expect(views[0].unfinished.count == 4)
    }

    @Test func resolvedColorsMeetReadingContrastInEveryPresetAndAppearance() throws {
        func luminance(_ color:NSColor) throws -> Double {
            let rgb=try #require(color.usingColorSpace(.sRGB))
            let channels=[rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { value in
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055,2.4)
            }
            return Double(channels[0]*0.2126 + channels[1]*0.7152 + channels[2]*0.0722)
        }
        for name in [NSAppearance.Name.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua] {
            let appearance=try #require(NSAppearance(named:name))
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    for foreground in [ThemeColors.source,ThemeColors.translation] {
                        for background in CorrespondenceColor.allCases.map({ThemeColors.correspondence($0)}) + [.textBackgroundColor,.windowBackgroundColor] {
                            let a=try luminance(foreground),b=try luminance(background)
                            #expect((max(a,b)+0.05)/(min(a,b)+0.05) >= 4.5)
                        }
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        }
    }
}

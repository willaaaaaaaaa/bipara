import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor @Suite("Native acceptance repair regressions")
struct AcceptanceRepairTests {
    private func runtime(_ gateway: ScriptedGateway = ScriptedGateway(), files: DocumentFileService = DocumentFileService()) -> AppRuntime {
        AppRuntime(gateway:gateway,keychain:FaultCredentials(),defaults:UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!,files:files)
    }
    private func snapshot(_ doc:BiparaDocument) -> JobSnapshot {
        .init(jobID:UUID(),sourceRevision:doc.sourceRevision,sourceLanguage:.en,targetLanguage:.zh,
              provider:"openai",model:"original",profile:WorkerContract.currentProfiles["openai"]!,effort:.auto,translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1")
    }
    private func preparedRuntime(_ gateway:ScriptedGateway = ScriptedGateway(),files:DocumentFileService = DocumentFileService()) -> AppRuntime {
        let keys=FaultCredentials(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let app=AppRuntime(gateway:gateway,keychain:keys,defaults:defs,files:files)
        keys.prepareDefault(app.settings,defaults:defs)
        return app
    }
    @Test func directionPreferenceAppliesToNewJobsAndAmbiguousReplacementKeepsResults() async throws {
        let gateway = ScriptedGateway()
        let app = preparedRuntime(gateway)
        app.newTab()
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftText = "12345" }
        app.settings.updateDraft { $0.preferredTranslationDirection = .zhToEn }
        try app.settings.saveDraft()
        await app.translate(session)
        let before = app.workspace.tabs[0].document
        #expect(before.resolvedDirection == .zhToEn)
        #expect(!before.translations.isEmpty)
        #expect(gateway.dispatchCount == 1)

        app.settings.updateDraft { $0.preferredTranslationDirection = .auto }
        try app.settings.saveDraft()
        app.alertHandler = { _, _, buttons in
            #expect(buttons == ["Open Settings", "Cancel"])
            return 0
        }
        await app.translate(session, retranslate: true)
        #expect(app.settingsRequested)
        #expect(app.workspace.tabs[0].document == before)
        #expect(gateway.dispatchCount == 1)
    }

    @Test(arguments:[""," \n\t"])
    func blankTranslateKeepsEditorWithoutReportingModelFailure(draft:String) async throws {
        let gateway=ScriptedGateway(),defaults=UserDefaults(suiteName:"dev.bipara.blank-test.\(UUID())")!
        defaults.set(true,forKey:"dev.bipara.disclosure.openai|https://api.openai.com")
        let app=AppRuntime(gateway:gateway,keychain:FaultCredentials(),defaults:defaults)
        app.newTab();let session=try #require(app.activeSession)
        app.workspace.withTab(0){$0.draftText=draft}
        await app.translate(session)
        #expect(app.editing.contains(session))
        #expect(app.errorMessage == nil)
        #expect(app.workspace.tabs[0].document.source.isEmpty)
        #expect(app.workspace.tabs[0].draftText == draft)
        #expect(app.workspace.tabs[0].job.state == .idle)
        #expect(gateway.dispatchCount == 0)
    }
    @Test(arguments:["First.\r\nSecond.","First.\rSecond.",String(repeating:"a" + String(repeating:"\u{301}",count:6),count:50)])
    func derivedTitlesAlwaysRoundTripWithoutChangingSource(source:String) throws {
        let w=WorkspaceStore();try w.newTab(source:source,direction:.enToZh)
        let doc=w.tabs[0].document,reopened=try DocumentCodec.decode(DocumentCodec.encode(doc))
        #expect(TextIdentity.equal(reopened.source,source))
        #expect(!reopened.title.contains(where:{$0.isNewline}))
        #expect(reopened.title.unicodeScalars.count <= DocumentCodec.maxTitleCharacters)
        #expect(reopened.title.utf8.elementsEqual(doc.title.utf8))
    }

    @Test func oversizedPlanKeepsPreviousDocumentAndEditorDraft() async throws {
        let app=runtime();try app.workspace.newTab(source:"Previous original.",direction:.enToZh)
        let before=app.workspace.tabs[0].document,session=app.workspace.tabs[0].sessionID
        let draft=String(repeating:"A.\n",count:60_000)
        #expect(draft.utf8.count < WorkerContract.maxSourceUTF8Bytes)
        app.workspace.withTab(0){$0.draftText=draft}
        await #expect(throws:WorkspaceStore.PlanningError.documentTooLarge){try await app.apply(session)}
        #expect(app.workspace.tabs[0].document == before)
        #expect(app.workspace.tabs[0].draftText == draft);#expect(app.workspace.tabs[0].isDirty)
    }

    @Test func existingPinCanBeReplacedWithoutChangingItsDisplayedGranularity() throws {
        let app=runtime();try app.workspace.newTab(source:"Hello there. Another sentence.",direction:.enToZh)
        let tab=app.workspace.tabs[0],first=try #require(tab.document.units.first),last=try #require(tab.document.units.last)
        let a=ReadingSelection(paragraphID:first.paragraphID,unitID:first.id,side:.source,range:.init(location:0,length:5))
        let b=ReadingSelection(paragraphID:last.paragraphID,unitID:last.id,side:.source,range:.init(location:0,length:7))
        #expect(a != b)
        app.reading[tab.sessionID,default:.init()].selection=a
        app.reading[tab.sessionID]?.phraseRanges=[.init(location:0,length:2)];app.pin()
        app.reading[tab.sessionID]?.selection=b;app.reading[tab.sessionID]?.phraseRanges=[]
        #expect(app.reading[tab.sessionID]?.canPin == true)
        #expect(app.reading[tab.sessionID]?.displayedPhraseRanges == [.init(location:0,length:2)])
        app.pin();#expect(app.reading[tab.sessionID]?.pinned == b)
        #expect(app.reading[tab.sessionID]?.displayedPhraseRanges == [])
    }

    @Test func partialTranslationExportRequiresExplicitChoice() throws {
        let w=WorkspaceStore();try w.newTab(source:"First paragraph.\r\n\r\nSecond paragraph.",direction:.enToZh)
        var document=w.tabs[0].document
        document.translations=[.init(unitID:document.units[0].id,text:"译文一",returnedModel:nil,completedAt:Date())]
        let files=DocumentFileService()
        #expect(throws:DocumentFileService.FileError.incompleteTranslation){try files.exportTranslation(document)}
        let first=try #require(document.paragraphs.first)
        #expect(try files.exportTranslation(document,allowPartial:true) == "译文一" + document.source.substring(utf16:first.separatorRange)!)
        #expect(try files.exportBilingual(document).contains("[untranslated]"))
        document.translations.append(.init(unitID:document.units.last!.id,text:"译文二",returnedModel:nil,completedAt:Date()))
        #expect(try files.exportTranslation(document) == "译文一\r\n\r\n译文二")
    }

    @Test func simultaneousResumeCallersShareOneAttempt() async throws {
        let w=WorkspaceStore();try w.newTab(source:"The window is open.",direction:.enToZh)
        let g=ScriptedGateway(),barrier=TestBarrier();g.barrier=barrier
        let coordinator=TranslationCoordinator(gateway:g)
        let snapshot=DispatchFixtures.snapshot(model:"original")
        let old=Task{try await coordinator.translate(tabIndex:0,workspace:w,snapshot:snapshot,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())}
        await barrier.started(1);coordinator.cancel(tabIndex:0,workspace:w)
        let a=Task{try await coordinator.translate(tabIndex:0,workspace:w,snapshot:snapshot,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())}
        let b=Task{try await coordinator.translate(tabIndex:0,workspace:w,snapshot:snapshot,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())}
        // The cancelled first attempt unparks and unwinds on its own (the
        // barrier is cancellation-safe), so both newcomers serialize through
        // the drain loop; observing waitingCallerCount mid-flight would race
        // with that unwind. Assert the shared-attempt outcome instead: after
        // the drain, exactly one new attempt dispatches (dispatch 2) and
        // parks at the barrier until released.
        await barrier.release(1);await barrier.started(2)
        await barrier.release(2)
        await #expect(throws:CancellationError.self){try await old.value}
        try await a.value;try await b.value
        #expect(g.dispatchCount == 2)
        #expect(w.tabs[0].job.state == .completed)
        #expect(coordinator.waitingCallerCount == 0)
    }

    @Test func explicitRetranslateDiscardsPartialSnapshot() async throws {
        let g=ScriptedGateway();g.failAtDispatch=2
        let app=runtime(g);try app.workspace.newTab(source:String(repeating:"Hello there. ",count:100),direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        let original=DispatchFixtures.snapshot(model:"original")
        do{try await app.coordinator.translate(tabIndex:0,workspace:app.workspace,snapshot:original,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential());Issue.record("expected partial failure")}
        catch let error as GatewayError{#expect(error.code == .network)}
        let completed=Set(app.workspace.tabs[0].document.translations.map(\.unitID))
        #expect(!completed.isEmpty)
        let revision=app.workspace.tabs[0].document.sourceRevision
        app.discardTranslations(session)
        #expect(app.workspace.tabs[0].document.translations.isEmpty)
        #expect(app.workspace.tabs[0].document.jobSnapshot == nil)
        #expect(app.workspace.tabs[0].job.snapshot == nil)
        #expect(app.workspace.tabs[0].document.sourceRevision == revision)
        try await app.coordinator.translate(tabIndex:0,workspace:app.workspace,snapshot:DispatchFixtures.snapshot(provider:"glm",model:"changed-default",profile:WorkerContract.currentProfiles["glm"]),binding:DispatchFixtures.binding(baseURL:WorkerContract.glmStandardBaseURL),credential:DispatchFixtures.credential())
        #expect(!completed.isDisjoint(with:g.requests.dropFirst(2).flatMap(\.units).map(\.unitID)))
        #expect(g.configurations.dropFirst(2).allSatisfy{$0.provider == "glm" && $0.model == "changed-default"})
        #expect(app.workspace.tabs[0].job.state == .completed)
    }

    @Test func combinedAlignmentLimitMakesNoTask() throws {
        let app=runtime();try app.workspace.newTab(source:"Hello there.",direction:.enToZh)
        let doc=app.workspace.tabs[0].document,unit=try #require(doc.units.first),paragraph=try #require(doc.paragraphs.first)
        let binding=RuntimeModelBinding(configurationID:try #require(app.settings.record.defaultConfiguration?.id),baseURL:WorkerContract.openAIStandardBaseURL, provider: "openai")
        app.workspace.withTab(0){$0.document.jobSnapshot=snapshot(doc);$0.runtimeBinding=binding;$0.document.translations=[.init(unitID:unit.id,text:String(repeating:"x",count:8192),returnedModel:nil,completedAt:Date())]}
        let selection=ReadingSelection(paragraphID:paragraph.id,unitID:unit.id,side:.source,range:.init(location:0,length:5))
        app.selected(selection,session:app.workspace.tabs[0].sessionID)
        #expect(!app.hasSelectionTask(for:app.workspace.tabs[0].sessionID))
        #expect(app.reading[app.workspace.tabs[0].sessionID]?.selection == selection)
    }

    @Test func phraseCacheIsBoundedLRUAndSeparatesConfiguration() throws {
        let unit=UUID(),source=Data("Hello".utf8),target=Data("你好".utf8),date=Date()
        func key(_ offset:Int,model:String="original",effort:String="auto",bindingID:UUID=UUID()) -> SelectionCache.Key {
            .init(sourceRevision:1,unit:unit,source:source,target:target,targetCompletedAt:date,
                  side:"source",location:offset,length:1,provider:"openai",model:model,profile:WorkerContract.currentProfiles["openai"]!,effort:effort,bindingID:bindingID,promptVersion:"alignment.v1")
        }
        var cache=SelectionCache()
        let identity=UUID()
        for i in 0..<128 { cache.insert([],for:key(i,bindingID:identity)) }
        #expect(cache.value(for:key(0,bindingID:identity)) == [])
        cache.insert([.init(location:0,length:1)],for:key(128,bindingID:identity))
        #expect(cache.count == 128);#expect(cache.value(for:key(1,bindingID:identity)) == nil)
        #expect(cache.value(for:key(0,bindingID:identity)) == [])
        #expect(cache.value(for:key(0,model:"changed",bindingID:identity)) == nil)
        #expect(cache.value(for:key(0,effort:"low",bindingID:identity)) == nil)
        #expect(cache.value(for:key(0,bindingID:UUID())) == nil)
        #expect(cache.value(for:key(128,bindingID:identity)) == [.init(location:0,length:1)])
    }

    @Test func failedNewDestinationDoesNotRemainOwned() async throws {
        let counter=WriteCounter()
        let files=DocumentFileService{data,url in
            if await counter.next() == 1 { throw NSError(domain:"synthetic write failure",code:1) }
            try await DocumentFileService.atomicWrite(data,to:url)
        }
        let app=runtime(files:files),url=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-failed-save-\(UUID()).bipara")
        defer{try? FileManager.default.removeItem(at:url)}
        app.newTab();app.workspace.withTab(0){$0.draftText="First document."}
        #expect(await !app.save(app.workspace.tabs[0].sessionID,to:url))
        app.newTab();app.workspace.withTab(1){$0.draftText="Second document."}
        #expect(await app.save(app.workspace.tabs[1].sessionID,to:url))
        #expect(try await files.open(url).source == "Second document.")
        #expect(app.workspace.tabs[0].isDirty)
    }

    @Test func candidateAboveFileLimitRejectsWholeBatch() async throws {
        let app=runtime();try app.workspace.newTab(source:(1...3000).map{"Example sentence \($0)."}.joined(separator:"\n"),direction:.enToZh)
        var doc=app.workspace.tabs[0].document
        let pending=32,completed=doc.units.count-pending,date=Date()
        doc.jobSnapshot=snapshot(doc);doc.resolvedDirection = .enToZh
        doc.translations=doc.units.prefix(completed).map{.init(unitID:$0.id,text:"",returnedModel:nil,completedAt:date)}
        let overhead=try DocumentCodec.encode(doc).count
        let bytesPerUnit=(WorkerContract.documentFileByteLimit-overhead-(64 << 10))/completed
        #expect(bytesPerUnit > 0 && bytesPerUnit <= WorkerContract.maxTranslationBytes)
        let text=String(repeating:"x",count:bytesPerUnit)
        doc.translations=doc.units.prefix(completed).map{.init(unitID:$0.id,text:text,returnedModel:nil,completedAt:date)}
        let data=try DocumentCodec.encode(doc)
        #expect(data.count <= WorkerContract.documentFileByteLimit)
        _ = try DocumentCodec.decode(data)
        app.workspace.withTab(0){$0.document=doc}
        let g=ScriptedGateway();g.replyPrefix=String(repeating:"y",count:3900)
        let coordinator=TranslationCoordinator(gateway:g)
        await #expect(throws:TranslationCoordinator.CoordinatorError.documentTooLarge){
            try await coordinator.translate(tabIndex:0,workspace:app.workspace,snapshot:DispatchFixtures.snapshot(model:"original"),binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())
        }
        #expect(g.dispatchCount == 1);#expect(app.workspace.tabs[0].document.translations == doc.translations)
        #expect(app.workspace.tabs[0].job.state == .failed)
        #expect(try DocumentCodec.encode(app.workspace.tabs[0].document).count <= WorkerContract.documentFileByteLimit)
    }

    // MARK: - Runtime snapshots vs Settings edits (JOB-04)

    @Test func settingsEditsDoNotMutateJobAndDeletionBlocksLaterDispatches() async throws {
        let g=ScriptedGateway(),barrier=TestBarrier();g.barrier=barrier
        let keys=FaultCredentials(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let app=AppRuntime(gateway:g,keychain:keys,defaults:defs)
        keys.prepareDefault(app.settings,defaults:defs)
        try app.workspace.newTab(source:String(repeating:"Hello there.\n\n",count:WorkerContract.maxUnitsPerBatch * 4),direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        let defaultID=try #require(app.settings.record.defaultConfiguration?.id)
        let job=Task{await app.translate(session)}
        await barrier.started(1)
        // A model edit at the same endpoint does not mutate the running
        // job: its batches keep the original model/effort snapshot.
        app.settings.updateDraft{
            if let i=$0.modelConfigurations.firstIndex(where:{$0.id == defaultID}){$0.modelConfigurations[i].modelID="edited-model"}
        }
        try app.settings.saveDraft()
        await barrier.release(1)
        await barrier.started(3)
        // Deleting the configuration blocks later dispatches locally
        // (configuration_unavailable) without retargeting; completed work
        // is preserved and the in-flight request keeps its key.
        app.settings.updateDraft{
            $0.modelConfigurations.removeAll{$0.id == defaultID}
            $0.defaultModelConfigurationID=$0.modelConfigurations.first?.id
        }
        try app.settings.saveDraft()
        await barrier.release(2)
        await barrier.release(3)
        await job.value
        let tab=app.workspace.tabs[0]
        #expect(tab.job.state == .failed)
        #expect(!tab.document.translations.isEmpty)
        #expect(g.configurations.allSatisfy{$0.model=="gpt-4.1-mini-2025-04-14"})
        #expect(g.configurations.allSatisfy{$0.baseURL==WorkerContract.openAIStandardBaseURL})
        // The frozen binding never retargets to another entry.
        #expect(tab.runtimeBinding?.configurationID == defaultID)
    }

    @Test func openedDocumentRequiresExplicitBindingBeforeResume() async throws {
        let g=ScriptedGateway()
        let keys=FaultCredentials(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let app=AppRuntime(gateway:g,keychain:keys,defaults:defs)
        keys.prepareDefault(app.settings,defaults:defs)
        try app.workspace.newTab(source:"First sentence here.\n\nSecond sentence follows.",direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        // Simulate an opened file: a paused partial job with a snapshot
        // but no session-local runtime binding.
        let openedSnapshot=JobSnapshot(jobID:UUID(),sourceRevision:1,sourceLanguage:.en,targetLanguage:.zh,
            provider:"openai",model:"gpt-4.1-mini-2025-04-14",profile:ModelProfileID.openaiV2,effort:.auto,
            translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1")
        let firstUnit=app.workspace.tabs[0].document.units[0]
        app.workspace.withTab(0){
            $0.document.jobSnapshot=openedSnapshot
            $0.document.resolvedDirection = .enToZh
            $0.document.translations=[.init(unitID:firstUnit.id,text:"第一句。",returnedModel:nil,completedAt:Date())]
            $0.job.snapshot=openedSnapshot
            $0.job.completedUnitIDs=[firstUnit.id]
            $0.job.totalNonblankUnits=$0.document.units.count
            $0.job.state = .paused
        }
        let dirtyBefore=app.workspace.tabs[0].isDirty
        await app.translate(session)
        // The binding sheet is offered; no dispatch happened, the current
        // default was never substituted implicitly, and the binding itself
        // does not mark the document dirty.
        let request=try #require(app.bindingRequest)
        #expect(request.snapshot == openedSnapshot)
        #expect(!request.matches.isEmpty)
        #expect(g.dispatchCount == 0)
        #expect(app.workspace.tabs[0].isDirty == dirtyBefore)

        let match=try #require(request.matches.first)
        app.bindAndResume(request,configurationID:match.id)
        try await appWaitUntil{app.workspace.tabs[0].job.state == .completed}
        #expect(g.dispatchCount == 1)
        #expect(g.configurations.allSatisfy{$0.baseURL==WorkerContract.openAIStandardBaseURL && $0.effort == .auto})
        #expect(app.workspace.tabs[0].runtimeBinding?.configurationID == match.id)
    }

    @Test func emptyConfigurationListPreflightOffersSettingsWithoutDispatch() async throws {
        let g=ScriptedGateway(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let app=AppRuntime(gateway:g,keychain:FaultCredentials(),defaults:defs)
        app.settings.updateDraft{$0.modelConfigurations=[];$0.defaultModelConfigurationID=nil}
        try app.settings.saveDraft()
        try app.workspace.newTab(source:"The window is open.",direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        var offered:[String]=[]
        app.alertHandler={ _,_,buttons in offered=buttons;return 1} // Cancel
        await app.translate(session)
        #expect(g.dispatchCount == 0)
        #expect(app.workspace.tabs[0].job.state == .idle)
        // A dispatch-blocking preflight offers Settings (model-settings
        // contract) instead of only explaining.
        #expect(offered == ["Open Settings","Cancel"])
        #expect(!app.settingsRequested)
        app.alertHandler={ _,_,_ in 0} // Open Settings
        await app.translate(session)
        #expect(app.settingsRequested)
        #expect(g.dispatchCount == 0)
    }
}

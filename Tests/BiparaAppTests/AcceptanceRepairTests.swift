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
        SavedResponsesFixture.install(defs)
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

    @Test func incompleteTranslationReportsSourceUnitNumbers() async throws {
        let gateway = ScriptedGateway()
        let app = preparedRuntime(gateway)
        let index = try app.workspace.newTab(source: "First.\nSecond.\nThird.", direction: .enToZh)
        gateway.failureForRequest = { request in
            request.units.contains { $0.text == "Second." } ? .init(code: .invalidOutput, validationFailure: .unitMismatch) : nil
        }
        await app.translate(app.workspace.tabs[index].sessionID)
        let ids = app.workspace.tabs[index].document.units.map(\.id)
        try #require(ids.count == 3)
        #expect(app.workspace.tabs[index].document.translations.map(\.unitID) == [ids[0], ids[2]])
        #expect(app.errorMessage == String(format: app.text("Unfinished translation units (%lld): %@. Retry translates only these units."), 1, "2"))
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

    @Test(arguments: ["source edit", "new attempt", "discard"])
    func waitingResumeCannotStartOnChangedDocumentOrAttempt(_ change: String) async throws {
        let gateway = ScriptedGateway(), barrier = TestBarrier()
        gateway.barrier = barrier
        gateway.waitsForReplyAfterCancellation = true
        let app = preparedRuntime(gateway)
        let index = try app.workspace.newTab(source: "Original source.", direction: .enToZh)
        let session = app.workspace.tabs[index].sessionID
        let original = Task { await app.translate(session) }
        try await appWaitUntil { await barrier.count == 1 }
        app.coordinator.cancel(tabIndex: index, workspace: app.workspace)
        let resume = Task { await app.translate(session) }
        defer { Task { await barrier.release(1) } }
        try await appWaitUntil { app.coordinator.waitingCallerCount == 1 }

        switch change {
        case "source edit":
            app.workspace.withTab(index) { $0.draftText = "New source." }
            #expect(try await app.apply(session))
        case "new attempt":
            try app.coordinator.resume(tabIndex: index, workspace: app.workspace)
        default:
            app.discardTranslations(session)
        }

        let expected = app.workspace.tabs[index]
        gateway.barrier = nil
        await barrier.release(1)
        await original.value
        await resume.value
        #expect(gateway.dispatchCount == 1)
        #expect(app.workspace.tabs[index] == expected)
        #expect(!app.hasTranslationFailure(for: session))
    }

    @Test(arguments: [false, true])
    func retryWhileFailedSiblingDrainsCoalescesLiveCallers(cancelAll: Bool) async throws {
        let gateway = ScriptedGateway(), barrier = TestBarrier()
        gateway.barrier = barrier
        gateway.waitsForReplyAfterCancellation = true
        gateway.failAtDispatch = 1
        let app = preparedRuntime(gateway)
        let source = (0..<80).map { "Sentence number \($0)." }.joined(separator: "\n")
        let index = try app.workspace.newTab(source: source, direction: .enToZh)
        let session = app.workspace.tabs[index].sessionID
        let original = Task { await app.translate(session) }
        try await appWaitUntil { await barrier.count == 2 }
        defer { Task { await barrier.release(2) } }
        let failedIDs = gateway.requests[0].units.map(\.unitID)
        await barrier.release(1)
        try await appWaitUntil { app.workspace.tabs[index].job.state == .failed }

        let retries = (0..<3).map { _ in Task { await app.translate(session) } }
        try await appWaitUntil { app.coordinator.waitingCallerCount == retries.count }
        retries[0].cancel()
        if cancelAll {
            for retry in retries.dropFirst() { retry.cancel() }
            gateway.barrier = nil
        }
        await barrier.release(2)
        if cancelAll {
            await original.value
        } else {
            try await appWaitUntil { await barrier.count >= 3 }
            await original.value
            #expect(app.workspace.tabs[index].job.state == .running)
            #expect(!app.hasTranslationFailure(for: session))
            #expect(app.errorMessage == nil)
            gateway.barrier = nil
            await barrier.release(3)
        }
        for retry in retries { await retry.value }

        let tab = app.workspace.tabs[index]
        if cancelAll {
            #expect(gateway.dispatchCount == 2)
            #expect(tab.job.state == .failed)
            #expect(app.hasTranslationFailure(for: session))
        } else {
            #expect(gateway.dispatchCount == 3)
            #expect(gateway.requests.dropFirst(2).flatMap(\.units).map(\.unitID) == failedIDs)
            #expect(tab.job.state == .completed)
            #expect(tab.document.translations.count == tab.document.units.count)
            #expect(!app.hasTranslationFailure(for: session))
            #expect(app.errorMessage == nil)
        }
        #expect(app.coordinator.waitingCallerCount == 0)
    }

    @Test(arguments: ["edit", "retry"])
    func previousFailureLosesOwnershipBeforePresentation(_ change: String) async throws {
        let gateway = ScriptedGateway(), app = preparedRuntime(gateway)
        let index = try app.workspace.newTab(source: "Original source.", direction: .enToZh)
        let tab = app.workspace.tabs[index], snapshot = DispatchFixtures.snapshot()
        gateway.failAtDispatch = 1
        do {
            try await app.coordinator.translate(tab: tab, workspace: app.workspace, snapshot: snapshot,
                binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())
            Issue.record("Expected a failed attempt")
        } catch let failure as TranslationCoordinator.Failure {
            #expect(failure.isCurrent())
            if change == "edit" {
                app.workspace.withTab(index) { $0.draftText = "Changed source." }
                #expect(try await app.apply(tab.sessionID))
            } else {
                try await app.coordinator.translate(tabIndex: index, workspace: app.workspace, snapshot: snapshot,
                    binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())
                #expect(app.workspace.tabs[index].job.state == .completed)
            }
            #expect(!failure.isCurrent())
        }
    }

    @Test func mismatchedSnapshotRevisionCannotDispatch() async throws {
        let gateway = ScriptedGateway(), app = preparedRuntime(gateway)
        let index = try app.workspace.newTab(source: "New source.", direction: .enToZh)
        let before = app.workspace.tabs[index]
        try await app.coordinator.translate(tabIndex: index, workspace: app.workspace,
            snapshot: DispatchFixtures.snapshot(revision: before.document.sourceRevision - 1),
            binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())
        #expect(gateway.dispatchCount == 0)
        #expect(app.workspace.tabs[index] == before)
    }

    @Test func cancelledRetranslationImmediatelyAcceptsResume() async throws {
        let gateway = ScriptedGateway(), barrier = TestBarrier()
        let app = preparedRuntime(gateway)
        let index = try app.workspace.newTab(source: "Translate again.", direction: .enToZh)
        let session = app.workspace.tabs[index].sessionID
        await app.translate(session)
        let firstJob = try #require(app.workspace.tabs[index].job.snapshot)
        gateway.barrier = barrier
        gateway.waitsForReplyAfterCancellation = true
        app.alertHandler = { _, _, buttons in
            #expect(buttons.first == "Retranslate")
            #expect(app.replacing.contains(session))
            #expect(!app.showsCompletionCopy(app.workspace.tabs[index]))
            return 0
        }
        let replacement = Task { await app.translate(session, retranslate: true) }
        try await appWaitUntil { await barrier.count == 2 }
        defer { Task { await barrier.release(2) } }
        let replacementJob = try #require(app.workspace.tabs[index].job.snapshot)
        #expect(replacementJob.jobID != firstJob.jobID)
        app.primaryAction()
        #expect(app.workspace.tabs[index].job.state == .paused)
        let resume = Task { await app.translate(session) }
        try await appWaitUntil { app.coordinator.waitingCallerCount == 1 }
        gateway.barrier = nil
        await barrier.release(2)
        await replacement.value
        await resume.value
        #expect(gateway.dispatchCount == 3)
        #expect(app.workspace.tabs[index].job.snapshot == replacementJob)
        #expect(app.workspace.tabs[index].job.state == .completed)
        #expect(app.showsCompletionCopy(app.workspace.tabs[index]))
    }

    @Test func closeTargetsOriginalSessionAfterStopConfirmationMovesTabs() async throws {
        let gateway = ScriptedGateway(), barrier = TestBarrier()
        gateway.barrier = barrier
        let app = preparedRuntime(gateway)
        _ = try app.workspace.newTab()
        let closing = try app.workspace.newTab(source: "Closing document.")
        let closingSession = app.workspace.tabs[closing].sessionID
        let firstJob = Task { await app.translate(closingSession) }
        try await appWaitUntil { await barrier.count == 1 }
        let surviving = try app.workspace.newTab(source: "Surviving document.")
        let survivingSession = app.workspace.tabs[surviving].sessionID
        let otherJob = Task { await app.translate(survivingSession) }
        try await appWaitUntil { await barrier.count == 2 }
        app.alertHandler = { _, _, buttons in
            if buttons.first == "Stop and Close" {
                app.workspace.closeTab(at: 0)
                return 0
            }
            #expect(buttons == ["Save", "Discard", "Cancel"])
            return 1
        }
        #expect(await app.close(closingSession))
        await barrier.release(1)
        await barrier.release(2)
        await firstJob.value
        await otherJob.value
        #expect(app.workspace.tabs.map(\.sessionID) == [survivingSession])
        #expect(app.workspace.activeTab?.job.state == .completed)
    }

    @Test func backgroundFailuresKeepSeparateReopenableDetails() async throws {
        let gateway = ScriptedGateway(), barrier = TestBarrier()
        gateway.barrier = barrier
        gateway.failureForRequest = { request in
            request.units.first?.text == "Plain source." ? .init(code: .network, httpStatus: 503) : nil
        }
        let app = preparedRuntime(gateway)
        let plain = try app.workspace.newTab(source: "Plain source.", direction: .enToZh)
        let plainSession = app.workspace.tabs[plain].sessionID
        let plainJob = Task { await app.translate(plainSession) }
        try await appWaitUntil { await barrier.count == 1 }
        let markdown = try app.workspace.newTab(source: "# Setup\n\nOpen the `window`.", direction: .enToZh)
        let markdownSession = app.workspace.tabs[markdown].sessionID
        let markdownJob = Task { await app.translate(markdownSession) }
        try await appWaitUntil { await barrier.count == 2 }
        _ = try app.workspace.newTab()
        await barrier.release(1)
        await barrier.release(2)
        await plainJob.value
        await markdownJob.value
        #expect(app.hasTranslationFailure(for: plainSession))
        #expect(app.hasTranslationFailure(for: markdownSession))
        app.showTranslationFailure(for: markdownSession)
        #expect(app.errorMessage == nil)
        #expect(app.markdownFailure == nil)

        app.workspace.switchTab(to: markdown)
        app.showTranslationFailure(for: markdownSession)
        let report = try #require(app.markdownFailure)
        #expect(report.title == app.workspace.tabs[markdown].document.title)
        #expect(report.units.first?.passage.input == "Open the `window`.")
        app.workspace.switchTab(to: plain)
        #expect(app.markdownFailure == nil)
        app.showTranslationFailure(for: plainSession)
        #expect(app.errorMessage?.contains("HTTP 503") == true)
        app.errorMessage = nil
        app.showTranslationFailure(for: plainSession)
        #expect(app.errorMessage?.contains("HTTP 503") == true)

        gateway.barrier = nil
        gateway.failureForRequest = nil
        await app.translate(plainSession)
        #expect(app.workspace.tabs[plain].job.state == .completed)
        #expect(!app.hasTranslationFailure(for: plainSession))
        #expect(app.errorMessage == nil)
        #expect(app.hasTranslationFailure(for: markdownSession))
        app.workspace.withTab(markdown) { $0.draftText = "# New source\n\nOpen the `door`." }
        #expect(try await app.apply(markdownSession))
        #expect(!app.hasTranslationFailure(for: markdownSession))
        await app.translate(markdownSession)
        #expect(app.hasTranslationFailure(for: markdownSession))
        app.alertHandler = { _, _, _ in 1 }
        #expect(await app.close(markdownSession))
        #expect(!app.hasTranslationFailure(for: markdownSession))
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
        let retained = snapshot(doc)
        doc.jobSnapshot=retained;doc.resolvedDirection = .enToZh
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
            try await coordinator.translate(tabIndex:0,workspace:app.workspace,snapshot:retained,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())
        }
        #expect(g.dispatchCount == 1);#expect(app.workspace.tabs[0].document.translations == doc.translations)
        #expect(app.workspace.tabs[0].job.state == .failed)
        #expect(try DocumentCodec.encode(app.workspace.tabs[0].document).count <= WorkerContract.documentFileByteLimit)
    }

    // MARK: - Runtime snapshots vs Settings edits (JOB-04)

    @Test func settingsEditsDoNotMutateJobAndDeletionBlocksLaterDispatches() async throws {
        let g=ScriptedGateway(),barrier=TestBarrier();g.barrier=barrier
        let keys=FaultCredentials(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        SavedResponsesFixture.install(defs)
        let app=AppRuntime(gateway:g,keychain:keys,defaults:defs)
        keys.prepareDefault(app.settings,defaults:defs)
        try app.workspace.newTab(source:String(repeating:"Hello there.\n\n",count:WorkerContract.maxUnitsPerBatch * 4),direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        let original=try #require(app.settings.record.defaultConfiguration)
        let defaultID=original.id
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
        #expect(g.configurations.allSatisfy{$0.model==original.modelID && $0.requestOptions==original.requestOptions})
        #expect(g.configurations.allSatisfy{$0.baseURL==WorkerContract.openAIStandardBaseURL})
        // The frozen binding never retargets to another entry.
        #expect(tab.runtimeBinding?.configurationID == defaultID)
    }

    @Test func openedDocumentRequiresExplicitBindingBeforeResume() async throws {
        let g=ScriptedGateway()
        let keys=FaultCredentials(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        SavedResponsesFixture.install(defs)
        let app=AppRuntime(gateway:g,keychain:keys,defaults:defs)
        keys.prepareDefault(app.settings,defaults:defs)
        try app.workspace.newTab(source:"First sentence here.\n\nSecond sentence follows.",direction:.enToZh)
        let session=app.workspace.tabs[0].sessionID
        // Simulate an opened file: a paused partial job with a snapshot
        // but no session-local runtime binding.
        let current=try #require(app.settings.record.defaultConfiguration)
        let openedSnapshot=JobSnapshot(jobID:UUID(),sourceRevision:1,sourceLanguage:.en,targetLanguage:.zh,
            provider:current.provider,model:current.modelID,profile:current.profile,effort:current.effort,
            translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1",configurationRevision:current.revision)
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
        #expect(g.configurations.allSatisfy{$0.baseURL==WorkerContract.openAIStandardBaseURL && $0.effort == current.effort})
        #expect(app.workspace.tabs[0].runtimeBinding?.configurationID == match.id)
    }

    @Test func emptyConfigurationListPreflightOffersSettingsWithoutDispatch() async throws {
        let g=ScriptedGateway(),defs=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let app=AppRuntime(gateway:g,keychain:FaultCredentials(),defaults:defs)
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

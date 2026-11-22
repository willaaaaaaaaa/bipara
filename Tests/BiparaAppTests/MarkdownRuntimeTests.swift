@testable import BiparaAppKit
import BiparaCore
import BiparaWorker
import Foundation
import Testing

@MainActor
@Suite("Markdown document workflow")
struct MarkdownRuntimeTests {
    private func runtime(_ gateway: any ModelGateway, withCredential: Bool = true) -> AppRuntime {
        let defaults = UserDefaults(suiteName: "dev.bipara.markdown-tests.\(UUID())")!
        if withCredential { SavedResponsesFixture.install(defaults) }
        let keys = FaultCredentials()
        let app = AppRuntime(gateway: gateway, keychain: keys, defaults: defaults)
        if withCredential { keys.prepareDefault(app.settings, defaults: defaults) }
        return app
    }

    @Test func pastedMarkdownDispatchesStructuralPayloadsAndPersistsFormat() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        let source = "# Setup\r\n\r\nThe window\r\nis open.\r\n\r\n```sh\r\necho ready\r\n```\r\n"
        app.newTab()
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftText = source }
        await app.detectDraftFormat(session)
        #expect(app.formatStatus(app.workspace.tabs[0]) == "Markdown")
        await app.translate(session)
        #expect(app.errorMessage == nil)
        let tab = app.workspace.tabs[0]
        #expect(tab.document.isMarkdown)
        #expect(tab.document.requestedFormat == .auto)
        #expect(TextIdentity.equal(tab.document.source, source))
        #expect(tab.document.readingMode == .rendered)
        #expect(tab.job.state == .completed)
        #expect(gateway.requests.map(\.promptVersion) == [WorkerContract.markdownTranslationPromptVersion])
        #expect(gateway.requests.flatMap(\.units).map(\.text) == ["Setup", "The window is open."])
        #expect(try app.files.exportTranslation(tab.document, markdown: true).contains("echo ready"))
        let reopened = try DocumentCodec.decode(DocumentCodec.encode(tab.document))
        #expect(reopened.isMarkdown && reopened.requestedFormat == .auto)
        #expect(reopened.units.map(\.id) == tab.document.units.map(\.id))

        app.workspace.withTab(0) { $0.draftFormat = .markdown }
        #expect(try await app.apply(session))
        let pinnedFormat = app.workspace.tabs[0].document
        #expect(pinnedFormat.requestedFormat == .markdown)
        #expect(pinnedFormat.sourceRevision == tab.document.sourceRevision)
        #expect(pinnedFormat.translations == tab.document.translations)
        #expect(gateway.dispatchCount == 1)
    }

    @Test func pastedFrontmatterOpensRenderedReadingWithoutACredential() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway, withCredential: false)
        let source = "---\nname: example\ndescription: Read the guide.\n---\n\nOpen the **window**."
        app.newTab()
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftText = source }
        await app.detectDraftFormat(session)
        #expect(app.formatStatus(app.workspace.tabs[0]) == "Markdown")

        #expect(try await app.apply(session))
        let document = app.workspace.tabs[0].document
        #expect(!app.editing.contains(session))
        #expect(document.isMarkdown && document.canUseMarkdownPlan)
        #expect(document.readingMode == .rendered)
        #expect(document.markdownProjection() != nil)
        app.changeReadingMode(.source, session: session)
        #expect(app.workspace.tabs[0].document.readingMode == .source)
        #expect(TextIdentity.equal(app.workspace.tabs[0].document.source, source))
        #expect(gateway.dispatchCount == 0)
    }

    @Test func reorderedTableCellCommitsAndReopensThroughPackagedWorker() async throws {
        try await checkTableCell("Use `Bash` with `rg` if both `Grep` and `Glob` are unavailable.",
                                 reply: "如果 `Grep` 和 `Glob` 都不可用，就在 `Bash` 中使用 `rg`。")
        try await checkTableCell("Before saving, run `check` from `toolkit`. Before publishing, **review**.",
                                 reply: "保存前，运行 `toolkit` 中的 `check`。发布前，**请审阅**。")
    }

    private func checkTableCell(_ cell: String, reply: String) async throws {
        let gateway = PythonModelGateway(executableURL: CoordinatorRealWorkerTests.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        let app = runtime(gateway)
        let source = "| `ID` | `Notes` |\n| --- | --- |\n| 1 | \(cell) |"
        _ = try app.workspace.newTab(source: source, direction: .enToZh)
        let session = try #require(app.activeSession)
        await app.translate(session)
        let tab = app.workspace.tabs[0]
        #expect(tab.job.state == .completed)
        #expect(app.markdownFailure == nil)
        #expect(tab.document.translations.map(\.text) == [reply])
        let restored = try DocumentCodec.decode(DocumentCodec.encode(tab.document))
        #expect(restored.jobSnapshot?.translationPromptVersion == "translation.markdown.v5")
        #expect(restored.markdownExport(bilingual: false, plain: false, allowPartial: false)
            == source.replacingOccurrences(of: cell, with: reply))
    }

    @Test(arguments: ["translation.markdown.v3", "translation.markdown.v4"])
    func resumingSavedV4PlanKeepsCompletedTextAndJob(_ retainedPrompt: String) async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        app.alertHandler = { _, _, _ in 0 }
        _ = try app.workspace.newTab(source: "# Setup\n\nOpen the **window**.", direction: .enToZh)
        let session = try #require(app.activeSession)
        await app.translate(session)
        var saved = app.workspace.tabs[0].document
        let binding = try #require(app.workspace.tabs[0].runtimeBinding)
        saved.translations = [try #require(saved.translations.first)]
        saved.jobSnapshot?.translationPromptVersion = retainedPrompt
        let data = try DocumentCodec.encode(saved)
        let legacyData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: MarkdownPlan.version, with: "markdown-plan.v4").utf8)
        let reopened = try DocumentCodec.decode(legacyData)
        app.workspace.openDocument(reopened, at: URL(fileURLWithPath: "/tmp/\(UUID()).bipara"))
        let legacy = try #require(app.activeSession)
        #expect(app.workspace.tabs[1].document.markdownPlan?.planVersion == "markdown-plan.v4")

        let beforeResume = gateway.dispatchCount
        await app.translate(legacy, overrideBinding: binding)
        let resumed = gateway.requests.dropFirst(beforeResume)
        #expect(resumed.map(\.promptVersion) == [retainedPrompt])
        #expect(resumed.flatMap(\.units).map(\.unitID) == Array(saved.units.dropFirst()).map(\.id))
        let tab = app.workspace.tabs[1]
        #expect(tab.job.state == .completed)
        #expect(tab.runtimeBinding == binding)
        #expect(tab.document.jobSnapshot == reopened.jobSnapshot)
        #expect(tab.document.sourceRevision == reopened.sourceRevision)
        #expect(tab.document.units == reopened.units)
        #expect(tab.document.translations.first == reopened.translations.first)
        #expect(try DocumentCodec.decode(DocumentCodec.encode(tab.document)).markdownPlan?.planVersion == MarkdownPlan.version)

        let beforeRetranslate = gateway.dispatchCount
        await app.translate(legacy, retranslate: true)
        #expect(gateway.requests.dropFirst(beforeRetranslate).map(\.promptVersion) == ["translation.markdown.v5"])
        #expect(gateway.requests.dropFirst(beforeRetranslate).flatMap(\.units).map(\.unitID) == saved.units.map(\.id))
    }

    @Test func resumeRetainsV4WhenCompletedCodeFragmentsNeedLegacyJoining() async throws {
        let source = "`a` " + String(repeating: "word ", count: WorkerContract.maxBatchTextBytes / 5) + "`b` tail\n\nOther block."
        var saved = try WorkspaceStore.prepareDocument(source: source, direction: .enToZh, format: .markdown).document
        let legacyPlan = try #require(try MarkdownPlan.prepare(source, format: .markdown, plannerVersion: "markdown-plan.v4"))
        try #require(legacyPlan.units.count == 3)
        saved.markdownPlan = legacyPlan
        saved.paragraphs = legacyPlan.paragraphs
        saved.units = legacyPlan.units
        var snapshot = DispatchFixtures.snapshot()
        snapshot.translationPromptVersion = "translation.markdown.v4"
        saved.jobSnapshot = snapshot
        saved.resolvedDirection = .enToZh
        saved.translations = zip(saved.units, ["`a`", "`b`"]).map {
            .init(unitID: $0.id, text: $1, completedAt: Date())
        }
        let reopened = try DocumentCodec.decode(DocumentCodec.encode(saved))
        let workspace = WorkspaceStore()
        workspace.openDocument(reopened, at: URL(fileURLWithPath: "/tmp/\(UUID()).bipara"))
        let gateway = ScriptedGateway()
        try await TranslationCoordinator(gateway: gateway).translate(tabIndex: 0, workspace: workspace, snapshot: snapshot,
            binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())

        let tab = workspace.tabs[0]
        #expect(tab.job.state == .completed)
        #expect(gateway.requests.map { $0.units.map(\.unitID) } == [[saved.units[2].id]])
        #expect(tab.document.translations.prefix(2).elementsEqual(reopened.translations))
        #expect(tab.document.jobSnapshot == reopened.jobSnapshot)
        #expect(try DocumentCodec.decode(DocumentCodec.encode(tab.document)).markdownPlan?.planVersion == "markdown-plan.v4")
    }

    @Test func explicitRetranslationUpgradesSupportedLegacyMetadataPlan() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        let source = "---\nname: stable-id\ndescription: Read the guide.\n---\n\n# Setup\n\nOpen the window."
        _ = try app.workspace.newTab(source: source, direction: .enToZh)
        let legacy = try #require(try MarkdownPlan.prepare(source, format: .markdown, plannerVersion: "markdown-plan.v1"))
        app.workspace.withTab(0) {
            $0.document.markdownPlan = legacy
            $0.document.paragraphs = legacy.paragraphs
            $0.document.units = legacy.units
        }
        app.alertHandler = { _, _, _ in 0 }
        let session = try #require(app.activeSession)
        #expect(app.workspace.tabs[0].document.units.count == 2)
        await app.translate(session, retranslate: true)
        #expect(app.errorMessage == nil)
        #expect(app.workspace.tabs[0].document.markdownPlan?.planVersion == MarkdownPlan.version)
        #expect(gateway.requests.flatMap(\.units).map(\.text) == ["Read the guide.", "Setup", "Open the window."])
    }

    @Test func syntaxOnlyDocumentNeedsNoModelOrCredential() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway, withCredential: false)
        let source = "```sh\necho hello\n```"
        app.newTab()
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftText = source }
        app.alertHandler = { _, _, _ in
            Issue.record("A syntax-only document must not prompt for model settings.")
            return 1
        }
        await app.translate(session)
        let tab = app.workspace.tabs[0]
        #expect(tab.document.isMarkdown && tab.document.units.isEmpty)
        #expect(tab.document.jobSnapshot == nil)
        #expect(!app.editing.contains(session))
        #expect(tab.canCopyTranslation)
        #expect(gateway.dispatchCount == 0)
        #expect(TextIdentity.equal(try app.files.exportTranslation(tab.document, markdown: true), source))
    }

    @Test func staleFormatConfirmationCannotApplyANewerDraft() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        _ = try app.workspace.newTab(source: "The window is open.", direction: .enToZh)
        let session = try #require(app.activeSession)
        await app.translate(session)
        let translated = app.workspace.tabs[0].document
        #expect(!translated.translations.isEmpty)
        app.workspace.withTab(0) { $0.draftFormat = .markdown }
        app.alertHandler = { _, _, buttons in
            #expect(buttons.first == "Apply Format")
            app.workspace.withTab(0) { $0.draftText = "New draft while confirmation is open." }
            return 0
        }
        await #expect(throws: AppRuntime.ActionError.self) { try await app.apply(session) }
        #expect(app.workspace.tabs[0].document == translated)
        #expect(app.workspace.tabs[0].draftText == "New draft while confirmation is open.")
        #expect(gateway.dispatchCount == 1)
    }

    @Test func mixedMarkdownRepliesKeepSiblingAndQueuedBatchesAndRetryOnlyRejectedUnits() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        var paragraphs = (0..<132).map { "Sentence \($0)." }
        paragraphs[0] = "# Guide"
        paragraphs[1] = "Open the **window**."
        paragraphs[2] = "Run `check` now."
        paragraphs[68] = "Open [the guide](https://example.org/guide)."
        let source = paragraphs.joined(separator: "\n\n")
        _ = try app.workspace.newTab(source: source, direction: app.settings.record.translationDirection)
        let session = try #require(app.activeSession)
        let ids = app.workspace.tabs[0].document.units.map(\.id)
        try #require(ids.count == paragraphs.count)
        let missingID = ids[3]
        gateway.transformResult = { request, result in
            if request.units.count > 1, request.units.contains(where: { $0.unitID == missingID }) {
                result.translations.removeAll { $0.unitID == missingID }
                result.incompleteUnitIDs = [missingID]
            }
            for row in result.translations.indices {
                result.translations[row].text = "译文"
            }
        }

        await app.translate(session)
        let partial = app.workspace.tabs[0]
        #expect(partial.document.source == source)
        #expect(partial.job.state == .failed)
        let rejected = [ids[2], ids[68]]
        #expect(partial.document.translations.map(\.unitID) == ids.filter { !rejected.contains($0) })
        #expect(partial.document.translations[1].text == "译文")
        #expect(gateway.dispatchCount == 4)
        #expect(gateway.requests.filter(\.singleTextRecovery).map { $0.units.map(\.unitID) } == [[missingID]])
        let report = try #require(app.markdownFailure)
        #expect(report.units.map(\.id) == rejected)
        #expect(report.units.map(\.passage.unitNumber) == [3, 69])
        #expect(report.units.map(\.passage.input) == [paragraphs[2], paragraphs[68]])
        #expect(report.units.map(\.passage.reply) == ["译文", "译文"])
        #expect(report.units[0].difference != report.units[1].difference)
        #expect(try DocumentCodec.decode(DocumentCodec.encode(partial.document)).translations.map(\.text) == partial.document.translations.map(\.text))

        let calls = gateway.dispatchCount
        gateway.transformResult = { request, result in
            result.translations = request.units.map { .init(unitID: $0.unitID, text: $0.text) }
        }
        await app.translate(session)
        let complete = app.workspace.tabs[0]
        #expect(gateway.requests.dropFirst(calls).map { $0.units.map(\.unitID) } == [rejected])
        #expect(complete.job.state == .completed)
        #expect(complete.document.translations.filter { !rejected.contains($0.unitID) } == partial.document.translations)
        #expect(complete.document.jobSnapshot == partial.document.jobSnapshot)
        #expect(complete.document.markdownExport(bilingual: false, plain: false, allowPartial: false) != nil)
        #expect(app.markdownFailure == nil)
    }

    @Test(arguments: [true, false])
    func markdownDetailsKeepOtherFailuresInTheSameAttempt(fatal: Bool) async throws {
        let gateway = ScriptedGateway()
        let barrier = TestBarrier()
        gateway.barrier = barrier
        let app = runtime(gateway)
        var paragraphs = (0..<65).map { "Sentence \($0)." }
        paragraphs[0] = "# Guide"
        paragraphs[1] = "Run `check`."
        _ = try app.workspace.newTab(source: paragraphs.joined(separator: "\n\n"), direction: app.settings.record.translationDirection)
        let session = try #require(app.activeSession)
        let ids = app.workspace.tabs[0].document.units.map(\.id)
        try #require(ids.count == 65)
        let last = ids[64]
        gateway.failureForRequest = { request in
            guard request.units.first?.unitID == last else { return nil }
            return fatal ? GatewayError(code: .network, httpStatus: 503) : GatewayError(code: .invalidOutput, validationFailure: .invalidTranslationText)
        }
        let translation = Task { await app.translate(session) }
        defer { translation.cancel() }
        try await appWaitUntil { await barrier.count == 2 }
        let firstBatch = try #require(gateway.requests.firstIndex { $0.units.count == 64 }) + 1
        await barrier.release(firstBatch)
        try await appWaitUntil { app.workspace.tabs[0].document.translations.count == 63 }
        await barrier.release(firstBatch == 1 ? 2 : 1)
        if !fatal {
            try await appWaitUntil { await barrier.count == 3 }
            await barrier.release(3)
        }
        await translation.value

        let report = try #require(app.markdownFailure)
        #expect(report.units.map(\.id) == [ids[1]])
        #expect(report.units.first?.passage.reply == "译\(firstBatch)-1")
        let message = try #require(report.otherFailureMessage)
        if fatal {
            #expect(message.contains("HTTP 503"))
        } else {
            #expect(message.contains("2, 65"))
        }
        #expect(app.workspace.tabs[0].job.state == .failed)
        #expect(app.workspace.tabs[0].document.translations.map(\.unitID) == ids.filter { $0 != ids[1] && $0 != last })
    }

    @Test func finalRejectedReplyDrainsAfterAnInFlightNetworkFailure() async throws {
        let gateway = ScriptedGateway()
        let barrier = TestBarrier()
        gateway.barrier = barrier
        gateway.waitsForReplyAfterCancellation = true
        gateway.failureForRequest = { $0.units.count > 1 ? GatewayError(code: .network, httpStatus: 503) : nil }
        let app = runtime(gateway)
        let paragraphs = ["# Guide"] + (1..<64).map { "Sentence \($0)." } + ["Run `check`."]
        _ = try app.workspace.newTab(source: paragraphs.joined(separator: "\n\n"))
        let session = try #require(app.activeSession)
        let translation = Task { await app.translate(session) }
        defer { Task { await barrier.release(1); await barrier.release(2) } }
        try await appWaitUntil { await barrier.count == 2 }
        let networkCall = try #require(gateway.requests.firstIndex { $0.units.count > 1 }) + 1
        await barrier.release(networkCall)
        try await appWaitUntil { app.workspace.tabs[0].job.state == .failed }
        await barrier.release(networkCall == 1 ? 2 : 1)
        await translation.value

        let report = try #require(app.markdownFailure)
        #expect(report.units.map(\.passage.input) == ["Run `check`."])
        #expect(report.otherFailureMessage?.contains("HTTP 503") == true)
        #expect(app.workspace.tabs[0].job.activeBatchIDs.isEmpty)
        #expect(app.workspace.tabs[0].document.translations.isEmpty)
        #expect(gateway.dispatchCount == 2)
    }

    @Test func unsalvageableMarkdownWorkerRowDoesNotStopIndependentUnits() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        _ = try app.workspace.newTab(source: "# Guide\n\nFirst line.\n\nSecond line.", direction: app.settings.record.translationDirection)
        let session = try #require(app.activeSession)
        let ids = app.workspace.tabs[0].document.units.map(\.id)
        let bad = ids[1]
        gateway.failureForRequest = { request in
            request.units.contains { $0.unitID == bad } ? GatewayError(code: .invalidOutput, validationFailure: .invalidTranslationText) : nil
        }
        await app.translate(session)
        #expect(app.workspace.tabs[0].job.state == .failed)
        #expect(app.workspace.tabs[0].document.translations.map(\.unitID) == [ids[0], ids[2]])
        #expect(gateway.requests.filter { $0.singleTextRecovery && $0.units.first?.unitID == bad }.count == 1)
        let calls = gateway.dispatchCount
        gateway.failureForRequest = nil
        await app.translate(session)
        #expect(app.workspace.tabs[0].job.state == .completed)
        #expect(gateway.requests.dropFirst(calls).map { $0.units.map(\.unitID) } == [[bad]])
    }

    @Test(arguments: ["omitted", "overlap", "unknown", "duplicate", "reordered", "empty", "legacy"])
    func invalidPartialResultCannotCommitOrScheduleRecovery(_ fault: String) async throws {
        let gateway = ScriptedGateway()
        gateway.transformResult = { request, result in
            let missing = request.units[1].unitID
            result.translations.remove(at: 1)
            switch fault {
            case "omitted": break
            case "overlap": result.incompleteUnitIDs = [request.units[0].unitID, missing]
            case "unknown": result.incompleteUnitIDs = [missing, UUID()]
            case "duplicate": result.incompleteUnitIDs = [missing, missing]
            case "reordered":
                result.incompleteUnitIDs = [missing]
                result.translations.reverse()
            case "empty":
                result.translations = []
                result.incompleteUnitIDs = request.units.map(\.unitID)
            default: result.incompleteUnitIDs = [missing]
            }
        }
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: "# Guide\n\nFirst line.\n\nSecond line.", direction: .enToZh)
        var snapshot = DispatchFixtures.snapshot()
        snapshot.translationPromptVersion = fault == "legacy" ? "translation.markdown.v4" : WorkerContract.markdownTranslationPromptVersion
        let coordinator = TranslationCoordinator(gateway: gateway)
        await #expect(throws: TranslationCoordinator.CoordinatorError.invalidBatch) {
            try await coordinator.translate(tabIndex: index, workspace: workspace, snapshot: snapshot,
                                            binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())
        }
        #expect(workspace.tabs[index].document.translations.isEmpty)
        #expect(workspace.tabs[index].job.state == .failed)
        #expect(gateway.dispatchCount == 1)
    }

    @Test func formatReplacementCancelsAnInFlightMarkdownAttempt() async throws {
        let gateway = ScriptedGateway()
        let barrier = TestBarrier()
        gateway.barrier = barrier
        let app = runtime(gateway)
        let source = "# Setup\n\nOpen the window."
        _ = try app.workspace.newTab(source: source, direction: .enToZh)
        let session = try #require(app.activeSession)
        let translation = Task { await app.translate(session) }
        try await appWaitUntil { await barrier.count == 1 }
        let runningRevision = app.workspace.tabs[0].document.sourceRevision

        app.workspace.withTab(0) { $0.draftFormat = .plainText }
        app.alertHandler = { _, _, buttons in
            #expect(buttons.first == "Apply Format")
            return 0
        }
        #expect(try await app.apply(session))
        await translation.value
        let tab = app.workspace.tabs[0]
        #expect(tab.document.sourceRevision == runningRevision + 1)
        #expect(!tab.document.isMarkdown)
        #expect(tab.document.translations.isEmpty)
        #expect(tab.job.state == .idle)
        #expect(gateway.dispatchCount == 1)
    }

    @Test func importHintsMarkdownAndUserOverrideCanRestorePlainText() async throws {
        let app = runtime(ScriptedGateway())
        let source = "One unmarked line."
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bipara-markdown-\(UUID()).markdown")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        await app.open(url)
        let session = try #require(app.activeSession)
        #expect(app.workspace.tabs[0].document.isMarkdown)
        app.changeFormat(.plainText, session: session)
        #expect(try await app.apply(session))
        #expect(!app.workspace.tabs[0].document.isMarkdown)
        #expect(app.workspace.tabs[0].document.source == source)
    }

    @Test func changingRequestedFormatOnAnUnavailablePlanRequiresConfirmedRebuild() async throws {
        let app = runtime(ScriptedGateway())
        let source = "# Setup\n\nOpen the window."
        let prepared = try WorkspaceStore.prepareDocument(source: source, direction: .enToZh)
        let json = try #require(String(data: DocumentCodec.encode(prepared.document), encoding: .utf8))
        let original = Data(json.replacingOccurrences(of: MarkdownPlan.version, with: "markdown-plan.future").utf8)
        let unavailable = try DocumentCodec.decode(original)
        #expect(!unavailable.canUseMarkdownPlan)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bipara-markdown-\(UUID()).bipara")
        app.workspace.openDocument(unavailable, at: url)
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.draftFormat = .markdown }

        app.alertHandler = { _, _, buttons in
            #expect(buttons.first == "Apply Format")
            return 1
        }
        #expect(try await !app.apply(session))
        #expect(try DocumentCodec.encode(app.workspace.tabs[0].document) == original)

        app.alertHandler = { _, _, buttons in
            #expect(buttons.first == "Apply Format")
            return 0
        }
        #expect(try await app.apply(session))
        let rebuilt = app.workspace.tabs[0].document
        #expect(rebuilt.canUseMarkdownPlan)
        #expect(rebuilt.requestedFormat == .markdown)
        #expect(rebuilt.sourceRevision == unavailable.sourceRevision + 1)
        #expect(rebuilt.source == source)
        #expect(try DocumentCodec.decode(DocumentCodec.encode(rebuilt)).requestedFormat == .markdown)
    }
}

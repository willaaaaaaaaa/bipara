@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor
@Suite("Markdown document workflow")
struct MarkdownRuntimeTests {
    private func runtime(_ gateway: ScriptedGateway, withCredential: Bool = true) -> AppRuntime {
        let defaults = UserDefaults(suiteName: "dev.bipara.markdown-tests.\(UUID())")!
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

    @Test func rejectsStructureChangingResultAndKeepsSource() async throws {
        let gateway = ScriptedGateway()
        let app = runtime(gateway)
        let source = "# Setup\n\nOpen the **window**."
        _ = try app.workspace.newTab(source: source, direction: .enToZh)
        let session = try #require(app.activeSession)
        await app.translate(session)
        let tab = app.workspace.tabs[0]
        #expect(gateway.dispatchCount == 1)
        #expect(tab.document.source == source)
        #expect(tab.document.translations.isEmpty)
        #expect(tab.job.state == .failed)
        #expect(app.errorMessage == "The model changed the Markdown structure. Completed translations were kept.")
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

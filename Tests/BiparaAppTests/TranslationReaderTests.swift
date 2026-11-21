import AppKit
@testable import BiparaAppKit
import BiparaCore
import Testing

@MainActor @Suite("Translation reader and explicit copy")
struct TranslationReaderTests {
    private func runtime() -> AppRuntime {
        AppRuntime(gateway: ScriptedGateway(), keychain: FaultCredentials(),
                   defaults: UserDefaults(suiteName: UUID().uuidString)!, pasteboard: NSPasteboard.withUniqueName())
    }

    private func completed(_ source: String, markdown: Bool = false) throws -> BiparaDocument {
        var document = try WorkspaceStore.prepareDocument(source: source, direction: .enToZh, format: markdown ? .markdown : .plainText).document
        document.jobSnapshot = .init(jobID: UUID(), sourceRevision: document.sourceRevision,
                                     sourceLanguage: .en, targetLanguage: .zh,
                                     provider: "openai", model: "fixture", profile: WorkerContract.currentProfiles["openai"]!,
                                     effort: .auto, translationPromptVersion: document.translationPromptVersion, alignmentPromptVersion: "alignment.v1")
        document.resolvedDirection = .enToZh
        document.translations = document.units.enumerated().map { .init(unitID: $1.id, text: "译文\($0)。", completedAt: Date()) }
        return document
    }

    @Test(arguments: [true, false]) func copyUsesCompleteCanonicalResultAndCanRetry(markdown: Bool) async throws {
        let app = runtime()
        defer { app.pasteboard.releaseGlobally() }
        let document = try completed(markdown ? "# First\n\nSecond." : "First.\nSecond.", markdown: markdown)
        app.workspace.openDocument(document, at: URL(fileURLWithPath: "/copy-fixture.bipara"))
        let tab = try #require(app.workspace.activeTab)
        #expect(app.showsCompletionCopy(tab))
        #expect(app.pasteboard.string(forType: .string) == nil)
        let writer = app.writeClipboard
        app.writeClipboard = { _ in false }
        await app.copy(original: false)?.value
        #expect(app.copyFeedback == .init(session: tab.sessionID, succeeded: false))
        app.writeClipboard = writer
        await app.copy(original: false)?.value
        #expect(app.pasteboard.string(forType: .string) == (try app.files.exportTranslation(document, markdown: markdown)))
        #expect(app.copyFeedback == .init(session: tab.sessionID, succeeded: true))
        app.editing.insert(tab.sessionID)
        #expect(!app.showsCompletionCopy(tab))
        app.discardTranslations(tab.sessionID)
        #expect(app.copy(original: false) == nil)
    }

    @Test(arguments: ["switch", "close", "replace", "clipboard", "copy"]) func staleCopyCannotWrite(_ change: String) async throws {
        let app = runtime()
        defer { app.pasteboard.releaseGlobally() }
        let doc = try completed("# Title", markdown: true)
        app.workspace.openDocument(doc, at: URL(fileURLWithPath: "/race-fixture.bipara"))
        let session = try #require(app.activeSession)
        var resume: CheckedContinuation<String, Never>?
        app.translationForCopy = { _ in await withCheckedContinuation { resume = $0 } }
        let request = app.copy(original: false)
        try await appWaitUntil { resume != nil }
        switch change {
        case "switch": app.newTab(); app.workspace.switchTab(to: 0)
        case "close": app.workspace.closeTab(at: 0)
        case "replace": app.discardTranslations(session)
        case "clipboard": app.pasteboard.clearContents(); app.pasteboard.setString("newer", forType: .string)
        default: await app.copy(original: true)?.value
        }
        resume?.resume(returning: "obsolete")
        await request?.value
        #expect(app.pasteboard.string(forType: .string) != "obsolete")
        #expect(app.copyFeedback == nil)
    }

    @Test func targetProjectionUsesWholePassagesAndNearestReadyAnchor() throws {
        var doc = try completed("First.\nSecond sentence. Again.\nThird.")
        let second = doc.paragraphs[1]
        doc.translations.removeAll { $0.unitID == second.unitIDs.last }
        let index = RenderedTextIndex(document: doc, layout: .paragraphs, translationOnly: true)
        #expect(index.strings == ["译文0。\n译文3。", ""])
        let anchor = index.targetAnchor(nearest: .init(paragraphID: second.id, side: .source, fraction: 0.4), in: doc)
        #expect(anchor?.paragraphID == doc.paragraphs[0].id)
    }

    @Test(arguments: [MarkdownReadingMode.rendered, .source]) func localOnlyMarkdownWaitsForVisibleProse(mode: MarkdownReadingMode) throws {
        let code = "```\nlocal-only\n```"
        func target(_ document: BiparaDocument) throws -> String {
            let projection = try #require(document.markdownProjection())
            return RenderedTextIndex(document: document, layout: .paragraphs, markdown: projection, translationOnly: true).strings[0]
        }
        var literal = try completed(code, markdown: true)
        literal.readingMode = mode
        #expect(try target(literal).contains("local-only"))
        var mixed = try completed(code + "\n\n| Header | Other |\n| --- | --- |\n| Row | Data |", markdown: true)
        mixed.readingMode = mode
        let translations = mixed.translations
        mixed.translations = []
        #expect(try target(mixed).isEmpty)
        mixed.translations = [translations[2]]
        #expect(try target(mixed).isEmpty)
        mixed.translations = Array(translations.prefix(2))
        #expect(try target(mixed).contains("local-only"))
        #expect(try target(mixed).contains("译文1。"))
    }

    @Test func saveKeepsFractionWhenRenderedOffsetExceedsFileLimit() async throws {
        let app = runtime()
        defer { app.pasteboard.releaseGlobally() }
        let document = try completed("# One\n\nTwo.", markdown: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        app.workspace.openDocument(document, at: url)
        let session = try #require(app.activeSession)
        app.setReadingView(.translationReader)
        let id = try #require(document.paragraphs.last?.id)
        var anchor = ReadingAnchor(paragraphID: id, side: .translation, fraction: 0.75, offset: WorkerContract.maxSourceUTF8Bytes + 1)
        app.reading[session, default: .init()].readerAnchor = anchor
        #expect(await app.save(session, to: url))
        anchor.offset = nil
        #expect(try DocumentCodec.decode(Data(contentsOf: url)).readingAnchor == anchor)
    }

    @Test func sessionChoiceAndNativeSaveAnchorSurviveEarlierArrivals() async throws {
        _ = NSApplication.shared
        let app = runtime()
        defer { app.pasteboard.releaseGlobally() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try completed((0..<45).map { "Original paragraph \($0)." }.joined(separator: "\n"))
        var partial = full
        partial.translations.removeFirst(10)
        app.workspace.openDocument(partial, at: url)
        let tab = try #require(app.workspace.activeTab)
        app.setLayout(.paragraphs)
        app.setReadingView(.translationReader)
        let reader = ParallelReader()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
        defer { window.close() }
        let wanted = ReadingAnchor(paragraphID: full.paragraphs[23].id, side: .translation, fraction: 0.4)
        var presentation = ReadingPresentation()
        presentation.readerAnchor = wanted
        func render(_ document: BiparaDocument) {
            reader.update(.init(sessionID: tab.sessionID, document: document, layout: .paragraphs, typography: .init(),
                                presentation: presentation, language: .english, translationOnly: true, reduceMotion: true,
                                onMount: { app.nativeReader = $0 }, onAnchor: { _ in }))
        }
        render(partial)
        let before = try #require(reader.visibleAnchor(for: tab.sessionID))
        #expect(before.paragraphID == wanted.paragraphID)
        app.workspace.withTab(0) { $0.document.translations = full.translations; $0.contentGeneration += 1 }
        render(full)
        let after = try #require(reader.visibleAnchor(for: tab.sessionID))
        #expect(before.paragraphID == after.paragraphID)
        #expect(abs(before.fraction - after.fraction) < 0.05)
        #expect(await app.save(tab.sessionID, to: url))
        let reopened = try DocumentCodec.decode(Data(contentsOf: url))
        let saved = try #require(reopened.readingAnchor)
        #expect(saved.paragraphID == after.paragraphID)
        #expect(saved.side == after.side)
        // AppKit can snap the scroll origin to a backing pixel during the asynchronous save.
        #expect(abs(saved.fraction - after.fraction) < 0.025)
        #expect(reopened.layout == .paragraphs)
        app.newTab()
        #expect(app.workspace.activeTab?.readingView == .paired(.sideBySide))
        app.workspace.switchTab(to: 0)
        #expect(app.workspace.activeTab?.readingView == .translationReader)
        let other = WorkspaceStore()
        other.openDocument(reopened, at: url)
        #expect(other.activeTab?.readingView == .paired(.paragraphs))
    }
}

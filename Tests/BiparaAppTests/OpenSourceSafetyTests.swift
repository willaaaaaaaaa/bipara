import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor @Suite("Document safety at publication boundaries")
struct OpenSourceSafetyTests {
    @Test func retainedJobDoesNotOfferAChangedEndpointBinding() async throws {
        let gateway = ScriptedGateway(), keys = FaultCredentials()
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        let app = AppRuntime(gateway: gateway, keychain: keys, defaults: defaults)
        keys.prepareDefault(app.settings, defaults: defaults)
        let configuration = try #require(app.settings.record.defaultConfiguration)
        try app.workspace.newTab(source: "First sentence. Second sentence.")
        let original = try #require(app.workspace.activeTab?.document)
        let session = try #require(app.activeSession)
        let snapshot = JobSnapshot(jobID: UUID(), sourceRevision: original.sourceRevision,
                                   sourceLanguage: .en, targetLanguage: .zh, provider: configuration.provider,
                                   model: configuration.modelID, profile: configuration.profile, effort: configuration.effort,
                                   translationPromptVersion: "translation.v2", alignmentPromptVersion: "alignment.v1")
        app.workspace.withTab(0) {
            $0.document.jobSnapshot = snapshot; $0.document.resolvedDirection = .enToZh
            $0.job.snapshot = snapshot; $0.job.state = .paused
            $0.runtimeBinding = RuntimeModelBinding(configurationID: configuration.id, baseURL: configuration.baseURL, provider: configuration.provider)
        }
        app.settings.updateDraft { draft in
            let index = draft.modelConfigurations.firstIndex { $0.id == configuration.id }!
            draft.modelConfigurations[index].baseURL = "https://changed.example.com/v1/"
        }
        try app.settings.saveDraft()
        var offeredSettings = false
        app.alertHandler = { title, _, _ in offeredSettings = title == "The original model configuration is unavailable."; return 1 }
        await app.translate(session)
        #expect(offeredSettings)
        #expect(app.bindingRequest == nil)
        #expect(gateway.dispatchCount == 0)
        #expect(app.workspace.activeTab?.runtimeBinding?.baseURL == configuration.baseURL)
        #expect(app.workspace.activeTab?.document.sourceRevision == original.sourceRevision)
    }

    @Test func closeKeepsEditsMadeDuringItsSave() async throws {
        let barrier = TestBarrier()
        let files = DocumentFileService { _, _ in try await barrier.arrive(1) }
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        let app = AppRuntime(gateway: ScriptedGateway(), keychain: FaultCredentials(), defaults: defaults, files: files)
        try app.workspace.newTab(source: "Saved snapshot.")
        let session = try #require(app.activeSession)
        app.workspace.withTab(0) { $0.saveURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bipara") }
        app.alertHandler = { _, _, _ in 0 }
        let closing = Task { await app.close(session) }
        await barrier.started(1)
        app.workspace.withTab(0) { $0.draftText = "New edit during save." }
        await barrier.release(1)
        #expect(!(await closing.value))
        #expect(app.workspace.tabs.count == 1)
        #expect(app.workspace.activeTab?.draftText == "New edit during save.")
        #expect(app.workspace.activeTab?.isDirty == true)
    }

    @Test func externalRevisionCannotOverflowOnEdit() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab()
        var external = try #require(workspace.activeTab?.document)
        external.sourceRevision = Int.max
        let data = try DocumentCodec.encode(external)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(data) }
        #expect(throws: WorkspaceStore.PlanningError.self) {
            try WorkspaceStore.prepareDocument(source: "Changed.", direction: .auto, replacing: external)
        }
    }

    @Test func copiedLongCommandRetainsFragmentWhitespace() throws {
        let source = "echo " + Array(repeating: "item", count: 600).joined(separator: "  ")
        let plan = try SourcePlanner.plan(source)
        #expect(plan.units.count > 1)
        let copied = Dictionary(uniqueKeysWithValues: plan.units.map { ($0.id, source.substring(utf16: $0.textRange)!) })
        for language in [Language.zh, .en] {
            #expect(ParagraphAssembler.assembleDocument(plan, translations: copied, targetLanguage: language) == source)
        }
    }

    @Test func oversizedImportIsRejectedAndBOMAtLimitIsAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let limit = WorkerContract.maxSourceUTF8Bytes
        try Data(repeating: 65, count: limit + 4).write(to: url)
        let service = DocumentFileService()
        #expect(throws: CoreError.self) { try service.importText(url) }
        var allowed = Data([0xEF, 0xBB, 0xBF])
        allowed.append(Data(repeating: 65, count: limit))
        try allowed.write(to: url)
        #expect(try service.importText(url).utf8.count == limit)
    }
}

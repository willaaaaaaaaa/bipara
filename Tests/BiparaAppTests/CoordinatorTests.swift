import BiparaAppKit
import BiparaCore
import BiparaWorker
import Foundation
import Testing

/// A scripted ModelGateway for ownership tests: it captures dispatched
/// requests and can delay or replay results after the document changed.
final class ScriptedGateway: ModelGateway, @unchecked Sendable {
    struct Recorded {
        var request: TranslateBatchRequest
        var configuration: ModelConfiguration
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var recordedAlignments: [ModelConfiguration] = []
    private var alignmentCount = 0
    /// Delay before answering each request (seconds).
    var delay: TimeInterval = 0
    var barrier: TestBarrier?
    var failAtDispatch: Int?
    var failureForRequest: (@Sendable (TranslateBatchRequest) -> GatewayError?)?
    /// Optional text prefix used in replies.
    var replyPrefix = "译"

    private func record(_ entry: Recorded) -> (count: Int, prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(entry)
        return (recorded.count, replyPrefix)
    }

    func translateBatch(
        _ request: TranslateBatchRequest,
        configuration: ModelConfiguration
    ) async throws -> TranslateBatchResult {
        let (count, prefix) = record(.init(request: request, configuration: configuration))
        if let barrier { try await barrier.arrive(count) }
        if count == failAtDispatch { throw GatewayError(code: .network) }
        if let failure = failureForRequest?(request) { throw failure }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return TranslateBatchResult(
            translations: request.units.enumerated().map { index, unit in
                .init(unitID: unit.unitID, text: "\(prefix)\(count)-\(index)")
            },
            meta: GatewayMeta(
                provider: configuration.provider,
                requestedModel: configuration.model,
                requestedEffort: configuration.effort,
                returnedModel: nil,
                promptVersion: request.promptVersion,
                inputTokens: nil,
                outputTokens: nil
            )
        )
    }

    func alignSelection(
        _ request: AlignSelectionRequest,
        configuration: ModelConfiguration
    ) async throws -> AlignSelectionResult {
        recordAlignConfiguration(configuration)
        return AlignSelectionResult(
            match: .noMatch(reason: "ambiguous"),
            meta: GatewayMeta(
                provider: configuration.provider,
                requestedModel: configuration.model,
                requestedEffort: configuration.effort,
                returnedModel: nil,
                promptVersion: "alignment.v1",
                inputTokens: nil,
                outputTokens: nil
            )
        )
    }

    func shutdown() async {}

    private func recordAlignment() { lock.lock(); defer { lock.unlock() }; alignmentCount += 1 }
    private func recordAlignConfiguration(_ configuration: ModelConfiguration) {
        lock.lock(); defer { lock.unlock() }
        recordedAlignments.append(configuration)
        alignmentCount += 1
    }
    var alignmentDispatchCount: Int { lock.lock(); defer { lock.unlock() }; return alignmentCount }
    var alignConfigurations: [ModelConfiguration] { lock.lock(); defer { lock.unlock() }; return recordedAlignments }

    var requests: [TranslateBatchRequest] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.request) }
    var configurations: [ModelConfiguration] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.configuration) }

    var dispatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }
}

/// Shared fixtures for coordinator-level tests: a frozen snapshot and
/// binding plus a static credential resolver.
@MainActor
enum DispatchFixtures {
    static func snapshot(provider: String = "openai", model: String = "gpt-4.1-mini-2025-04-14",
                         profile: String? = nil, effort: ModelEffort = .auto, revision: Int = 1) -> JobSnapshot {
        JobSnapshot(jobID: UUID(), sourceRevision: revision, sourceLanguage: .en, targetLanguage: .zh,
                    provider: provider, model: model,
                    profile: profile ?? WorkerContract.currentProfiles[provider] ?? "",
                    effort: effort,
                    translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1")
    }
    static func binding(baseURL: String = WorkerContract.openAIStandardBaseURL) -> RuntimeModelBinding {
        RuntimeModelBinding(configurationID: UUID(), baseURL: baseURL, provider: "openai")
    }
    static func credential(_ key: String = "SYNTHETIC_TEST_CREDENTIAL") -> TranslationCoordinator.CredentialResolver {
        { _ in key }
    }
}

@MainActor
@Suite("Translation coordinator ownership")
struct CoordinatorTests {
    private func makeWorkspace() throws -> (WorkspaceStore, Int) {
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: "The window is open. It rained today.")
        return (workspace, index)
    }

    @Test func translateCommitsThroughJobLifecycle() async throws {
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        let (workspace, index) = try makeWorkspace()
        try await coordinator.translate(
            tabIndex: index, workspace: workspace,
            snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
            credential: DispatchFixtures.credential()
        )
        let tab = workspace.tabs[index]
        #expect(tab.job.state == .completed)
        #expect(tab.document.translations.count == tab.document.units.count)
        #expect(tab.document.jobSnapshot?.provider == "openai")
        #expect(tab.document.resolvedDirection == .enToZh)
        #expect(tab.contentGeneration >= 1)
        #expect(tab.isDirty) // committed work is unsaved
    }

    @Test func lateResultAfterEditCannotCommit() async throws {
        // The scripted gateway delays its reply; the draft is applied (new
        // revision) while the batch is in flight. The late result must not
        // appear in the new revision's document.
        let gateway = ScriptedGateway()
        let barrier = TestBarrier(); gateway.barrier = barrier
        let coordinator = TranslationCoordinator(gateway: gateway)
        let (workspace, index) = try makeWorkspace()

        let job = Task {
            try await coordinator.translate(
                tabIndex: index, workspace: workspace,
                snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
                credential: DispatchFixtures.credential()
            )
        }
        await barrier.started(1)
        #expect(gateway.dispatchCount == 1)
        workspace.withTab(index) { $0.draftText = "The window is closed. It rained today." }
        try workspace.applyDraft(at: index)
        #expect(workspace.tabs[index].document.sourceRevision == 2)

        await barrier.release(1)
        try await job.value
        // Late result discarded: the new revision has no translations and
        // an idle job; the old revision's work is simply gone (by design).
        #expect(workspace.tabs[index].document.translations.isEmpty)
        #expect(workspace.tabs[index].job.state == .idle)
    }

    @Test func closedTabCannotReceiveLateResults() async throws {
        let gateway = ScriptedGateway()
        let barrier = TestBarrier(); gateway.barrier = barrier
        let coordinator = TranslationCoordinator(gateway: gateway)
        let (workspace, index) = try makeWorkspace()
        let closedSession = workspace.tabs[index].sessionID

        let job = Task {
            try await coordinator.translate(
                tabIndex: index, workspace: workspace,
                snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
                credential: DispatchFixtures.credential()
            )
        }
        await barrier.started(1)
        #expect(gateway.dispatchCount == 1)
        workspace.closeTab(at: index)
        #expect(workspace.isEmpty)

        await barrier.release(1)
        try await job.value
        // No crash, no resurrection: the workspace stays empty and the
        // closed session's identity was never reused.
        #expect(workspace.isEmpty)
        #expect(workspace.tabs.allSatisfy { $0.sessionID != closedSession })
    }

    @Test func emptyAndWhitespaceInputsRejectedWithoutDispatch() async throws {
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        _ = try workspace.newTab(source: "   \n\t")
        await #expect(throws: TranslationCoordinator.CoordinatorError.emptyInput) {
            try await coordinator.translate(
                tabIndex: 0, workspace: workspace,
                snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
                credential: DispatchFixtures.credential()
            )
        }
        #expect(gateway.dispatchCount == 0) // no model call for empty input
    }

    @Test func autoDirectionResolvesLocally() async throws {
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        _ = try workspace.newTab(source: "李明没有确认周五的会议。窗户开着。")
        try await coordinator.translate(
            tabIndex: 0, workspace: workspace,
            snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
            credential: DispatchFixtures.credential()
        )
        #expect(workspace.tabs[0].document.resolvedDirection == .zhToEn)

        let english = WorkspaceStore()
        _ = try english.newTab(source: "Revenue did not rise. It fell.")
        try await coordinator.translate(
            tabIndex: 0, workspace: english,
            snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
            credential: DispatchFixtures.credential()
        )
        #expect(english.tabs[0].document.resolvedDirection == .enToZh)
    }

    @Test func batchesDispatchInParallelWithinWindow() async throws {
        // >64 units so the plan splits into multiple batches.
        let sentences = (0..<200).map { "Sentence number \($0) with distinct content." }
        let gateway = ScriptedGateway()
        let barrier = TestBarrier(); gateway.barrier = barrier
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: sentences.joined(separator: " "))

        let job = Task {
            try await coordinator.translate(
                tabIndex: index, workspace: workspace,
                snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
                credential: DispatchFixtures.credential()
            )
        }
        // Two batches are in flight simultaneously (the old serial loop
        // would block the second behind the first barrier).
        await barrier.started(2)
        #expect(gateway.dispatchCount == 2)
        await barrier.release(1)
        await barrier.started(3)
        #expect(gateway.dispatchCount == 3)
        await barrier.release(2)
        await barrier.started(4)
        #expect(gateway.dispatchCount == 4)
        await barrier.release(3)
        await barrier.release(4)
        try await job.value
        let tab = workspace.tabs[index]
        #expect(tab.job.state == .completed)
        #expect(tab.document.translations.count == tab.document.units.count)
    }

    @Test func batchFailureStopsDispatchAndKeepsCommittedWork() async throws {
        // Four planned batches: commit the first, then fail the second
        // while the third is parked. Observe the failure before releasing
        // that sibling, proving the fourth is withheld and committed work
        // survives without assuming continuation-resumption order.
        let sentences = (0..<200).map { "Sentence number \($0) with distinct content." }
        let gateway = ScriptedGateway()
        gateway.barrier = TestBarrier()
        gateway.failAtDispatch = 2
        let barrier = gateway.barrier!
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: sentences.joined(separator: " "))

        let job = Task {
            try await coordinator.translate(
                tabIndex: index, workspace: workspace,
                snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
                credential: DispatchFixtures.credential()
            )
        }
        await barrier.started(2)
        await barrier.release(1)
        await barrier.started(3)
        #expect(!workspace.tabs[index].document.translations.isEmpty)
        await barrier.release(2)
        try await appWaitUntil { workspace.tabs[index].job.state == .failed }
        await barrier.release(3)
        await #expect(throws: GatewayError.self) { try await job.value }
        let tab = workspace.tabs[index]
        #expect(tab.job.state == .failed)
        // Batch 1's committed units survive; the fourth planned batch was
        // withheld after the failure.
        #expect(!tab.document.translations.isEmpty)
        #expect(gateway.dispatchCount == 3)
    }

    @Test func unitMismatchSplitsOnlyTheFailedBatch() async throws {
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        let source = (0..<80).map { "Sentence number \($0) with distinct content." }.joined(separator: "\n")
        let index = try workspace.newTab(source: source)
        let units = workspace.tabs[index].document.units.map(\.id)
        try #require(units.count == 80)
        let mismatch = GatewayError(code: .invalidOutput, validationFailure: .unitMismatch)
        gateway.failureForRequest = { $0.units.count == 64 ? mismatch : nil }
        let snapshot = DispatchFixtures.snapshot()

        try await coordinator.translate(tabIndex: index, workspace: workspace, snapshot: snapshot,
                                        binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())

        let tab = workspace.tabs[index]
        #expect(tab.job.state == .completed)
        #expect(tab.job.snapshot?.jobID == snapshot.jobID)
        #expect(tab.document.translations.map(\.unitID) == units)
        let requests = gateway.requests
        #expect(requests.count == 4)
        #expect(Set(requests.map { $0.units.map(\.unitID) }) ==
                Set([Array(units[..<64]), Array(units[..<32]), Array(units[32..<64]), Array(units[64...])]))
        let firstHalf = try #require(requests.first { $0.units.map(\.unitID) == Array(units[..<32]) })
        let secondHalf = try #require(requests.first { $0.units.map(\.unitID) == Array(units[32..<64]) })
        #expect(firstHalf.contextAfter.contains("Sentence number 32"))
        #expect(secondHalf.contextBefore.contains("Sentence number 31"))
    }

    @Test func mismatchInASplitHalfStopsWithoutRecursing() async throws {
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        let source = (0..<8).map { "Sentence number \($0) with distinct content." }.joined(separator: "\n")
        let index = try workspace.newTab(source: source)
        let units = workspace.tabs[index].document.units.map(\.id)
        try #require(units.count == 8)
        let mismatch = GatewayError(code: .invalidOutput, validationFailure: .unitMismatch)
        gateway.failureForRequest = { _ in mismatch }
        let snapshot = DispatchFixtures.snapshot()
        let binding = DispatchFixtures.binding()

        await #expect(throws: mismatch) {
            try await coordinator.translate(tabIndex: index, workspace: workspace, snapshot: snapshot,
                                            binding: binding, credential: DispatchFixtures.credential())
        }

        #expect(workspace.tabs[index].job.state == .failed)
        #expect(workspace.tabs[index].document.translations.isEmpty)
        #expect(gateway.requests.map { $0.units.count }.sorted() == [4, 4, 8])
    }

    @Test(arguments: ["1302", "1305"])
    func glmRateLimitReplaysOnlyFailedBatch(_ code: String) async throws {
        let gateway = ScriptedGateway()
        let workspace = WorkspaceStore()
        let source = (0..<80).map { "Sentence number \($0) with distinct content." }.joined(separator: "\n")
        let index = try workspace.newTab(source: source)
        let error = GatewayError(code: .rateLimited, retryAfterMS: 25, httpStatus: 429, providerCode: code)
        gateway.failureForRequest = { request in
            request.units.count == 64 && request.rateLimitReplayDeadline == nil ? error : nil
        }
        let binding = RuntimeModelBinding(configurationID: UUID(), baseURL: WorkerContract.glmStandardBaseURL, provider: "glm")
        let snapshot = DispatchFixtures.snapshot(provider: "glm", model: "glm-5.3-flash", effort: .low)
        var credentialReads = 0
        try await TranslationCoordinator(gateway: gateway).translate(
            tabIndex: index, workspace: workspace, snapshot: snapshot, binding: binding,
            credential: { _ in credentialReads += 1; return "test" }
        )

        let replays = gateway.requests.filter { $0.rateLimitReplayDeadline != nil }
        let replay = try #require(replays.first)
        let failed = try #require(gateway.requests.first { $0.units.count == 64 && $0.rateLimitReplayDeadline == nil })
        #expect(replays.count == 1)
        #expect(replay.units == failed.units)
        #expect(replay.contextBefore == failed.contextBefore)
        #expect(replay.contextAfter == failed.contextAfter)
        #expect(gateway.requests.map { $0.units.count }.sorted() == [16, 64, 64])
        #expect(gateway.configurations.allSatisfy { $0.configurationID == binding.configurationID && $0.effort == .low })
        #expect(credentialReads == 3)
        #expect(workspace.tabs[index].job.state == .completed)
        #expect(workspace.tabs[index].document.translations.count == 80)
    }

    @Test(arguments: ["1302", "1308", "", "long", "local"])
    func glmReplayStopsAfterSecondFailureAndSkipsIneligibleErrors(_ code: String) async throws {
        let gateway = ScriptedGateway()
        let (workspace, index) = try makeWorkspace()
        let isTransient = ["1302", "long", "local"].contains(code)
        let error = GatewayError(code: .rateLimited, retryAfterMS: code == "long" ? 61_000 : nil,
                                 isLocal: code == "local", httpStatus: 429, providerCode: isTransient ? "1302" : code)
        gateway.failureForRequest = { _ in error }
        let binding = RuntimeModelBinding(configurationID: UUID(), baseURL: WorkerContract.glmStandardBaseURL, provider: "glm")
        let snapshot = DispatchFixtures.snapshot(provider: "glm", model: "glm-5.3-flash", effort: .low)
        await #expect(throws: error) {
            try await TranslationCoordinator(gateway: gateway).translate(
                tabIndex: index, workspace: workspace, snapshot: snapshot, binding: binding, credential: DispatchFixtures.credential()
            )
        }
        #expect(gateway.dispatchCount == (code == "1302" ? 2 : 1))
        #expect(workspace.tabs[index].job.state == .failed)
    }
}

@MainActor
@Suite("Coordinator with the real packaged worker")
struct CoordinatorRealWorkerTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var fixtureExecutable: URL {
        repoRoot.appendingPathComponent("build/worker-fixture/BiparaWorkerFixture.app/Contents/MacOS/BiparaWorkerFixture")
    }

    @Test func endToEndTranslationThroughRealProcess() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.fixtureExecutable.path) else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        let coordinator = TranslationCoordinator(gateway: gateway)
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: "李明没有确认周五的会议。")
        try await coordinator.translate(
            tabIndex: index, workspace: workspace,
            snapshot: DispatchFixtures.snapshot(), binding: DispatchFixtures.binding(),
            credential: DispatchFixtures.credential()
        )
        let tab = workspace.tabs[index]
        #expect(tab.job.state == .completed)
        #expect(tab.document.translations.first?.text == "Li Ming has not confirmed Friday's meeting.")
        // Assembled paragraph reading works offline through the real pipes.
        let plan = SourcePlan(source: tab.document.source, paragraphs: tab.document.paragraphs, units: tab.document.units)
        let translations = Dictionary(uniqueKeysWithValues: tab.document.translations.map { ($0.unitID, $0.text) })
        let assembly = ParagraphAssembler.assemble(
            plan, paragraph: tab.document.paragraphs[0], translations: translations, targetLanguage: .en
        )
        #expect(assembly?.text == "Li Ming has not confirmed Friday's meeting.")
    }
}

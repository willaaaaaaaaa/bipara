import BiparaCore
import BiparaWorker
import Foundation

/// Owns cancellable document attempts; persistent identities never depend on tab order.
@MainActor
public final class TranslationCoordinator: ObservableObject {
    private let gateway: any ModelGateway
    private var active: [UUID: (UUID, Task<Void, Error>)] = [:]
    private(set) var waitingCallerCount = 0

    public init(gateway: any ModelGateway) { self.gateway = gateway }

    /// Resolves a frozen runtime binding to a dispatch credential on the
    /// main actor, serialized with Settings persistence. Missing/changed
    /// configurations and missing keys are local typed errors; an already
    /// dispatched request keeps its original key.
    public typealias CredentialResolver = @MainActor (RuntimeModelBinding) throws -> String

    public func translate(
        tabIndex: Int,
        workspace: WorkspaceStore,
        snapshot: JobSnapshot,
        binding: RuntimeModelBinding,
        credential: @escaping CredentialResolver
    ) async throws {
        guard workspace.tabs.indices.contains(tabIndex) else { return }
        let session = workspace.tabs[tabIndex].sessionID
        while let previous = active[session] {
            waitingCallerCount += 1
            if !previous.1.isCancelled {
                defer { waitingCallerCount -= 1 }
                return try await withTaskCancellationHandler { try await previous.1.value } onCancel: { previous.1.cancel() }
            }
            _ = try? await previous.1.value
            waitingCallerCount -= 1
            if active[session]?.0 == previous.0 { active[session] = nil }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard workspace.index(of: session) != nil else { return }
        let token = UUID()
        let task = Task { try await self.run(session: session, workspace: workspace, snapshot: snapshot, binding: binding, credential: credential) }
        active[session] = (token, task)
        defer { if active[session]?.0 == token { active[session] = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func run(
        session: UUID,
        workspace: WorkspaceStore,
        snapshot: JobSnapshot,
        binding: RuntimeModelBinding,
        credential: CredentialResolver
    ) async throws {
        guard let index = workspace.index(of: session) else { return }
        let tab = workspace.tabs[index]
        guard !tab.document.source.isEmpty, !tab.document.source.isWhitespaceOnly else { throw CoordinatorError.emptyInput }
        // Preflight prompt availability per operation: a retained snapshot
        // with a retired prompt version, or one operation's version in the
        // other operation's field, cannot dispatch. Its translations stay
        // readable and exportable; the app offers an explicit Retranslate
        // (D4, N6).
        guard WorkerContract.translationPromptVersions.contains(snapshot.translationPromptVersion),
              WorkerContract.alignmentPromptVersions.contains(snapshot.alignmentPromptVersion) else {
            throw CoordinatorError.retiredPromptVersion
        }
        let original = tab.document
        let direction: (Language, Language)
        switch original.resolvedDirection {
        case .enToZh: direction = (.en, .zh)
        case .zhToEn: direction = (.zh, .en)
        case nil, .auto: direction = try Self.resolveDirection(original.requestedDirection, source: original.source)
        }
        let resolved = JobSnapshot(
            jobID: snapshot.jobID, sourceRevision: original.sourceRevision,
            sourceLanguage: direction.0, targetLanguage: direction.1,
            provider: snapshot.provider, model: snapshot.model, profile: snapshot.profile,
            effort: snapshot.effort,
            // Retained snapshots keep their recorded prompt versions;
            // availability was preflighted above (D4).
            translationPromptVersion: snapshot.translationPromptVersion,
            alignmentPromptVersion: snapshot.alignmentPromptVersion, configurationRevision: snapshot.configurationRevision)
        let finished = Set(original.translations.map(\.unitID))
        let units = original.units.filter { !finished.contains($0.id) }
        let plan = SourcePlan(source: original.source, paragraphs: original.paragraphs, units: units)
        let initialBatches = try SourcePlanner.formBatches(plan)
        guard !initialBatches.isEmpty else { return }
        let originalBatchCount = initialBatches.count
        workspace.withTab(index) { tab in
            if tab.job.snapshot != nil || tab.job.state != .idle {
                tab.job.snapshot = resolved
                tab.job.completedUnitIDs = finished
                tab.job.totalNonblankUnits = original.units.count
                if tab.job.state != .queued {
                    if tab.job.state == .idle { tab.job.state = .paused }
                    _ = tab.job.apply(.resume(batches: Array(initialBatches.indices)))
                }
            } else {
                _ = tab.job.apply(.translate(snapshot: resolved, batches: Array(initialBatches.indices), totalNonblankUnits: original.units.count))
            }
        }
        guard let initialIndex = workspace.index(of: session) else { return }
        let attempt = workspace.tabs[initialIndex].job.attemptGeneration
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        // One child task per in-flight batch; nil `gatewayError` marks a
        // cancellation. Everything mutating shared state happens on this
        // actor when the outcome is consumed.
        enum BatchOutcome: Sendable {
            case success(batchID: Int, unitIDs: [UUID], result: TranslateBatchResult)
            case failure(batchID: Int, gatewayError: GatewayError?)
        }

        let maxInFlight = max(1, WorkerContract.translationBatchesPerSession)
        let (cancelledByUser, firstFailure) = await withTaskGroup(
            of: BatchOutcome.self, returning: (Bool, (any Error)?).self, isolation: #isolation
        ) { @MainActor group in
            var batches = initialBatches
            var firstFailure: Error?
            var cancelledByUser = false
            var abandoned = false
            var inFlight = 0

            @MainActor func canStartMore() -> Bool {
                guard inFlight < maxInFlight, firstFailure == nil, !cancelledByUser, !abandoned,
                      let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) else { return false }
                return !workspace.tabs[i].job.queuedBatchIDs.isEmpty
            }

            // Marks the attempt cancelled once: the reducer drops queued
            // work and bumps the attempt generation, so late sibling
            // outcomes can no longer commit.
            @MainActor func markCancelled() {
                cancelledByUser = true
                if let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) {
                    workspace.withTab(i) { _ = $0.job.apply(.cancel) }
                }
            }

            @MainActor func failBatch(_ batchID: Int, _ error: Error) {
                if let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) {
                    workspace.withTab(i) { _ = $0.job.apply(.batchFailed(batchID: batchID)) }
                }
                if firstFailure == nil { firstFailure = error }
            }

            @MainActor func splitFailedBatch(_ batchID: Int, _ error: GatewayError) -> Bool {
                guard error.code == .invalidOutput, error.validationFailure == .unitMismatch,
                      batchID < originalBatchCount, firstFailure == nil, !Task.isCancelled,
                      let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace),
                      workspace.tabs[i].job.activeBatchIDs.contains(batchID) else { return false }
                let failedUnits = batches[batchID].unitIDs.compactMap { byID[$0] }
                guard failedUnits.count > 1 else { return false }
                let midpoint = failedUnits.count / 2
                let replacements = try? [failedUnits[..<midpoint], failedUnits[midpoint...]].flatMap { half in
                    try SourcePlanner.formBatches(SourcePlan(source: plan.source, paragraphs: plan.paragraphs, units: Array(half)))
                }
                guard let replacements, replacements.count == 2 else { return false }
                let replacementIDs = [batches.count, batches.count + 1]
                batches.append(contentsOf: replacements)
                workspace.withTab(i) { _ = $0.job.apply(.batchSplit(batchID: batchID, replacementIDs: replacementIDs)) }
                return true
            }

            // Prepares and launches the next batch inside the parallelism
            // window. A lost ownership/state guard stops further starts
            // without failing the job; remaining children still drain.
            @MainActor func startNext(group: inout TaskGroup<BatchOutcome>, replayBatchID: Int? = nil) {
                guard let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace),
                      [.queued, .running].contains(workspace.tabs[i].job.state),
                      let batchID = replayBatchID ?? workspace.tabs[i].job.queuedBatchIDs.first else {
                    abandoned = true
                    return
                }
                let batch = batches[batchID]
                workspace.withTab(i) { tab in
                    if !tab.job.activeBatchIDs.contains(batchID) { _ = tab.job.apply(.batchDispatched(batchID: batchID)) }
                }
                guard let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace),
                      workspace.tabs[i].job.activeBatchIDs.contains(batchID) else {
                    abandoned = true
                    return
                }
                var request = TranslateBatchRequest(
                    sourceLanguage: resolved.sourceLanguage, targetLanguage: resolved.targetLanguage,
                    contextBefore: batch.contextBefore, contextAfter: batch.contextAfter,
                    units: batch.unitIDs.compactMap { byID[$0] }.map {
                        .init(unitID: $0.id, kind: $0.kind, text: original.source.substring(utf16: $0.textRange) ?? "")
                    }, ownerSessionID: session, promptVersion: resolved.translationPromptVersion
                )
                if replayBatchID != nil {
                    request.rateLimitReplayDeadline = ContinuousClock.now + WorkerContract.glmAutomaticWaitBudget
                }
                let configuration: ModelConfiguration
                do {
                    let credentials = try ModelCredentials.decode(credential(binding))
                    configuration = .init(
                        provider: resolved.provider, model: resolved.model, profile: resolved.profile,
                        baseURL: binding.baseURL, effort: resolved.effort, apiKey: credentials.apiKey,
                        configurationID: binding.configurationID, requestOptions: binding.requestOptions, secretHeaders: credentials.headers
                    )
                } catch {
                    failBatch(batchID, error)
                    return
                }
                let unitIDs = batch.unitIDs
                inFlight += 1
                group.addTask { [gateway = self.gateway, request] in
                    do {
                        let result = try await gateway.translateBatch(request, configuration: configuration)
                        return .success(batchID: batchID, unitIDs: unitIDs, result: result)
                    } catch let error as GatewayError {
                        return .failure(batchID: batchID, gatewayError: error)
                    } catch {
                        return .failure(batchID: batchID, gatewayError: nil)
                    }
                }
            }

            var replayedBatches: Set<Int> = []

            @MainActor func handle(_ outcome: BatchOutcome, group: inout TaskGroup<BatchOutcome>) async {
                switch outcome {
                case let .success(batchID, unitIDs, result):
                    do {
                        try Task.checkCancellation()
                        try await commitBatch(
                            result, batchID: batchID, requestedUnitIDs: unitIDs,
                            session: session, original: original, attempt: attempt,
                            workspace: workspace, resolved: resolved
                        )
                    } catch is CancellationError {
                        if !cancelledByUser { markCancelled() }
                    } catch {
                        failBatch(batchID, error)
                    }
                case let .failure(batchID, gatewayError):
                    if let gatewayError {
                        if firstFailure == nil, !cancelledByUser, !abandoned, !Task.isCancelled,
                           let delay = gatewayError.glmCooldown(provider: resolved.provider),
                           delay <= WorkerContract.glmAutomaticWaitBudget,
                           replayedBatches.insert(batchID).inserted {
                            startNext(group: &group, replayBatchID: batchID)
                        } else if replayedBatches.contains(batchID) || !splitFailedBatch(batchID, gatewayError) {
                            failBatch(batchID, gatewayError)
                        }
                    } else if firstFailure == nil && !cancelledByUser {
                        // A cancellation with no earlier failure is the
                        // user cancelling the attempt.
                        markCancelled()
                    } else if let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) {
                        // A sibling aborted after a failure or user cancel:
                        // clear its reducer slot (a no-op once the attempt
                        // was cancelled or the job already failed).
                        workspace.withTab(i) { _ = $0.job.apply(.batchFailed(batchID: batchID)) }
                    }
                }
            }

            while canStartMore() { startNext(group: &group) }
            while let outcome = await group.next() {
                inFlight -= 1
                await handle(outcome, group: &group)
                if firstFailure != nil || cancelledByUser {
                    // Stop paying for further batches; in-flight siblings
                    // drain and may still commit if they already finished.
                    group.cancelAll()
                } else {
                    while canStartMore() { startNext(group: &group) }
                }
            }
            return (cancelledByUser, firstFailure)
        }
        if cancelledByUser { throw CancellationError() }
        if let firstFailure { throw firstFailure }
    }

    /// Validates a batch result against its request and commits it
    /// atomically; throws typed errors without mutating document state.
    private func commitBatch(
        _ result: TranslateBatchResult,
        batchID: Int,
        requestedUnitIDs: [UUID],
        session: UUID,
        original: BiparaDocument,
        attempt: Int,
        workspace: WorkspaceStore,
        resolved: JobSnapshot
    ) async throws {
        guard let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) else { return }
        guard result.translations.map(\.unitID) == requestedUnitIDs,
              result.meta.provider == resolved.provider, result.meta.requestedModel == resolved.model,
              result.meta.requestedEffort == resolved.effort,
              result.meta.promptVersion == resolved.translationPromptVersion else { throw CoordinatorError.invalidBatch }
        var candidate = workspace.tabs[i].document
        candidate.translations.append(contentsOf: result.translations.map {
            .init(unitID: $0.unitID, text: $0.text, returnedModel: result.meta.returnedModel, completedAt: Date())
        })
        let order = Dictionary(uniqueKeysWithValues: original.units.enumerated().map { ($0.element.id, $0.offset) })
        candidate.translations.sort { order[$0.unitID, default: 0] < order[$1.unitID, default: 0] }
        candidate.jobSnapshot = resolved
        candidate.resolvedDirection = resolved.sourceLanguage == .en ? .enToZh : .zhToEn
        let snapshotToValidate = candidate
        let encodedSize = try await Task.detached { try DocumentCodec.encode(snapshotToValidate).count }.value
        guard encodedSize <= WorkerContract.documentFileByteLimit else { throw CoordinatorError.documentTooLarge }
        guard let i = currentIndex(session, original: original, attempt: attempt, workspace: workspace) else { return }
        workspace.withTab(i) { tab in
            tab.document = candidate
            tab.contentGeneration += 1
            _ = tab.job.apply(.batchSucceeded(batchID: batchID, unitIDs: result.translations.map(\.unitID)))
        }
    }

    private func currentIndex(_ session: UUID, original: BiparaDocument, attempt: Int, workspace: WorkspaceStore) -> Int? {
        guard let i = workspace.index(of: session), workspace.tabs[i].document.documentID == original.documentID,
              workspace.tabs[i].document.sourceRevision == original.sourceRevision,
              workspace.tabs[i].job.attemptGeneration == attempt else { return nil }
        return i
    }

    public func cancel(tabIndex: Int, workspace: WorkspaceStore) {
        guard workspace.tabs.indices.contains(tabIndex) else { return }
        active[workspace.tabs[tabIndex].sessionID]?.1.cancel()
        workspace.withTab(tabIndex) { _ = $0.job.apply(.cancel) }
    }

    public func resume(tabIndex: Int, workspace: WorkspaceStore) throws {
        guard workspace.tabs.indices.contains(tabIndex) else { return }
        let tab = workspace.tabs[tabIndex]
        let finished = Set(tab.document.translations.map(\.unitID))
        let plan = SourcePlan(source: tab.document.source, paragraphs: tab.document.paragraphs, units: tab.document.units.filter { !finished.contains($0.id) })
        let batches = try SourcePlanner.formBatches(plan)
        workspace.withTab(tabIndex) { _ = $0.job.apply(.resume(batches: Array(batches.indices))) }
    }

    static func resolveDirection(_ requested: Direction, source: String) throws -> (Language, Language) {
        if requested == .enToZh { return (.en, .zh) }
        if requested == .zhToEn { return (.zh, .en) }
        var chinese = 0, english = 0
        for scalar in source.unicodeScalars.lazy.filter({ !$0.isContractWhitespace }).prefix(4000) {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value) { chinese += 1 }
            else if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) { english += 1 }
        }
        if chinese > 0, chinese >= english * 2 { return (.zh, .en) }
        if english > 0, english >= chinese * 2 { return (.en, .zh) }
        throw CoordinatorError.manualDirectionRequired
    }

    public enum CoordinatorError: Error { case emptyInput, manualDirectionRequired, invalidBatch, documentTooLarge, retiredPromptVersion }
}

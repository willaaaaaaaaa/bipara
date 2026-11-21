import BiparaCore
import BiparaWorker
import Foundation

/// Owns cancellable document attempts; persistent identities never depend on tab order.
@MainActor
public final class TranslationCoordinator: ObservableObject {
    private let gateway: any ModelGateway
    private struct AttemptOwner: Equatable {
        let session: UUID
        let documentID: UUID
        let sourceRevision: Int
        let jobID: UUID?
        let attempt: Int

        init(_ tab: TabState) {
            session = tab.sessionID
            documentID = tab.document.documentID
            sourceRevision = tab.document.sourceRevision
            jobID = (tab.job.snapshot ?? tab.document.jobSnapshot)?.jobID
            attempt = tab.job.attemptGeneration
        }

        @MainActor func index(in workspace: WorkspaceStore) -> Int? {
            guard let index = workspace.index(of: session), AttemptOwner(workspace.tabs[index]) == self else { return nil }
            return index
        }
    }

    @MainActor private final class Attempt {
        let requested: AttemptOwner
        let requiredContentGeneration: Int?
        let jobID: UUID
        var running: AttemptOwner?
        var waitingRetries = 0
        private var deferredFailures: [CheckedContinuation<Void, Never>] = []

        init(tab: TabState, jobID: UUID) {
            requested = AttemptOwner(tab)
            requiredContentGeneration = tab.job.state == .failed && requested.jobID != nil ? nil : tab.contentGeneration
            self.jobID = jobID
        }

        func index(in workspace: WorkspaceStore) -> Int? {
            if let running { return running.index(in: workspace) }
            guard let index = requested.index(in: workspace),
                  requiredContentGeneration == nil || workspace.tabs[index].contentGeneration == requiredContentGeneration else { return nil }
            return index
        }

        func result(of task: Task<Void, Error>) async throws {
            do {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            } catch let failure as Failure {
                if waitingRetries > 0 {
                    await withCheckedContinuation { deferredFailures.append($0) }
                }
                throw failure
            }
        }

        func finishedWaitingForRetry() {
            waitingRetries -= 1
            if waitingRetries == 0 {
                for continuation in deferredFailures { continuation.resume() }
                deferredFailures.removeAll()
            }
        }

        func canShare(with other: Attempt) -> Bool {
            guard jobID == other.jobID else { return false }
            return running == other.requested
                || (requested == other.requested && requiredContentGeneration == other.requiredContentGeneration)
        }
    }

    struct Failure: Error {
        let underlying: any Error
        let isCurrent: @MainActor @Sendable () -> Bool
    }

    private var active: [UUID: (attempt: Attempt, task: Task<Void, Error>)] = [:]
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
        do {
            try await translate(tab: workspace.tabs[tabIndex], workspace: workspace, snapshot: snapshot, binding: binding, credential: credential)
        } catch let failure as Failure {
            if failure.isCurrent() { throw failure.underlying }
        }
    }

    func translate(
        tab: TabState,
        workspace: WorkspaceStore,
        snapshot: JobSnapshot,
        binding: RuntimeModelBinding,
        credential: @escaping CredentialResolver
    ) async throws {
        let attempt = Attempt(tab: tab, jobID: snapshot.jobID)
        guard snapshot.sourceRevision == attempt.requested.sourceRevision,
              attempt.requested.jobID == nil || attempt.requested.jobID == snapshot.jobID else { return }
        let session = tab.sessionID
        try Task.checkCancellation()
        while let previous = active[session] {
            let retryingFailure = tab.job.state == .failed && previous.attempt.running == attempt.requested
            if !previous.task.isCancelled && !retryingFailure {
                guard previous.attempt.index(in: workspace) != nil, previous.attempt.canShare(with: attempt) else { return }
                waitingCallerCount += 1
                defer { waitingCallerCount -= 1 }
                return try await previous.attempt.result(of: previous.task)
            }
            waitingCallerCount += 1
            if retryingFailure { previous.attempt.waitingRetries += 1 }
            _ = try? await previous.task.value
            if retryingFailure { previous.attempt.finishedWaitingForRetry() }
            waitingCallerCount -= 1
            if active[session]?.attempt === previous.attempt { active[session] = nil }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard attempt.index(in: workspace) != nil else { return }
        let task = Task {
            do {
                try await self.run(attempt: attempt, workspace: workspace, snapshot: snapshot, binding: binding, credential: credential)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure(underlying: error) {
                    if let active = self.active[session], active.attempt !== attempt { return false }
                    return attempt.index(in: workspace) != nil
                }
            }
        }
        active[session] = (attempt, task)
        defer { if active[session]?.attempt === attempt { active[session] = nil } }
        try await attempt.result(of: task)
    }

    private func run(
        attempt: Attempt,
        workspace: WorkspaceStore,
        snapshot: JobSnapshot,
        binding: RuntimeModelBinding,
        credential: CredentialResolver
    ) async throws {
        try Task.checkCancellation()
        guard let index = attempt.index(in: workspace) else { return }
        let tab = workspace.tabs[index]
        guard !tab.document.source.isEmpty, !tab.document.source.isWhitespaceOnly else { throw CoordinatorError.emptyInput }
        // Preflight prompt availability per operation: a retained snapshot
        // with a retired prompt version, or one operation's version in the
        // other operation's field, cannot dispatch. Its translations stay
        // readable and exportable; the app offers an explicit Retranslate
        // (D4, N6).
        guard tab.document.supportsTranslationPrompt(snapshot.translationPromptVersion),
              WorkerContract.alignmentPromptVersions.contains(snapshot.alignmentPromptVersion) else {
            throw CoordinatorError.retiredPromptVersion
        }
        let original = tab.document
        let direction: (Language, Language)
        switch original.resolvedDirection {
        case .enToZh: direction = (.en, .zh)
        case .zhToEn: direction = (.zh, .en)
        case nil, .auto: direction = try Self.resolveDirection(original.requestedDirection, source: original.markdownPlan?.prose ?? original.source)
        }
        let resolved = JobSnapshot(
            jobID: snapshot.jobID, sourceRevision: snapshot.sourceRevision,
            sourceLanguage: direction.0, targetLanguage: direction.1,
            provider: snapshot.provider, model: snapshot.model, profile: snapshot.profile,
            effort: snapshot.effort,
            // Retained snapshots keep their recorded prompt versions;
            // availability was preflighted above (D4).
            translationPromptVersion: snapshot.translationPromptVersion,
            alignmentPromptVersion: snapshot.alignmentPromptVersion, configurationRevision: snapshot.configurationRevision)
        let finished = Set(original.translations.map(\.unitID))
        let units = original.units.filter { !finished.contains($0.id) }
        let plan = SourcePlan(source: original.source, paragraphs: original.paragraphs, units: units, markdownPlan: original.markdownPlan)
        let initialBatches = try SourcePlanner.formBatches(plan)
        guard !initialBatches.isEmpty else { return }
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
        let owner = AttemptOwner(workspace.tabs[index])
        attempt.running = owner
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        // One child task per in-flight batch; nil `gatewayError` marks a
        // cancellation. Everything mutating shared state happens on this
        // actor when the outcome is consumed.
        enum BatchOutcome: Sendable {
            case success(batchID: Int, unitIDs: [UUID], result: TranslateBatchResult)
            case failure(batchID: Int, gatewayError: GatewayError?)
        }

        // A single actor-isolated owner keeps mutable scheduling state out of
        // the captures shared by the group's nested helpers.
        @MainActor final class BatchSchedule {
            var batches: [TranslationBatch]
            var firstFailure: (any Error)?
            let originalCount: Int

            init(batches: [TranslationBatch]) {
                self.batches = batches
                originalCount = batches.count
            }

            func usesSingleText(_ batchID: Int) -> Bool {
                batchID >= originalCount && batches[batchID].unitIDs.count == 1
            }
        }

        let schedule = BatchSchedule(batches: initialBatches)
        let maxInFlight = max(1, WorkerContract.translationBatchesPerSession)
        var cancelledByUser = false
        var abandoned = false

        await withTaskGroup(of: BatchOutcome.self, isolation: #isolation) { group in
            var inFlight = 0

            @MainActor func canStartMore() -> Bool {
                guard inFlight < maxInFlight, schedule.firstFailure == nil, !cancelledByUser, !abandoned,
                      let i = owner.index(in: workspace) else { return false }
                return !workspace.tabs[i].job.queuedBatchIDs.isEmpty
            }

            // Marks the attempt cancelled once: the reducer drops queued
            // work and bumps the attempt generation, so late sibling
            // outcomes can no longer commit.
            @MainActor func markCancelled() {
                cancelledByUser = true
                if let i = owner.index(in: workspace) {
                    workspace.withTab(i) { _ = $0.job.apply(.cancel) }
                }
            }

            @MainActor func failBatch(_ batchID: Int, _ error: Error) {
                if let i = owner.index(in: workspace) {
                    workspace.withTab(i) { _ = $0.job.apply(.batchFailed(batchID: batchID)) }
                }
                if schedule.firstFailure == nil { schedule.firstFailure = error }
            }

            @MainActor func handleUnitFailure(_ batchID: Int, _ error: GatewayError) -> Bool {
                let batch = schedule.batches[batchID]
                let singleTextRecovery = schedule.usesSingleText(batchID)
                guard error.code == .invalidOutput, error.validationFailure == .unitMismatch || singleTextRecovery,
                      schedule.firstFailure == nil, !Task.isCancelled,
                      let i = owner.index(in: workspace),
                      workspace.tabs[i].job.activeBatchIDs.contains(batchID) else { return false }
                let nextID = schedule.batches.count
                let remaining = WorkerContract.maxUnitRecoveryRequests - (nextID - schedule.originalCount)
                if !singleTextRecovery && batch.unitIDs.count == 1 && remaining >= 1 {
                    schedule.batches.append(batch)
                } else if batch.unitIDs.count > 1 && remaining >= 2 {
                    let failedUnits = batch.unitIDs.compactMap { byID[$0] }
                    let midpoint = failedUnits.count / 2
                    do {
                        let replacements = try [failedUnits[..<midpoint], failedUnits[midpoint...]].flatMap { half in
                            try SourcePlanner.formBatches(SourcePlan(source: plan.source, paragraphs: plan.paragraphs, units: Array(half), markdownPlan: plan.markdownPlan))
                        }
                        if replacements.count <= remaining { schedule.batches.append(contentsOf: replacements) }
                    } catch {
                        failBatch(batchID, error)
                        return true
                    }
                }
                let replacements = Array(nextID..<schedule.batches.count)
                workspace.withTab(i) { _ = $0.job.apply(.batchNeedsRecovery(batchID: batchID, replacementIDs: replacements)) }
                return true
            }

            // Prepares and launches the next batch inside the parallelism
            // window. A lost ownership/state guard stops further starts
            // without failing the job; remaining children still drain.
            @MainActor func startNext(group: inout TaskGroup<BatchOutcome>, replayBatchID: Int? = nil) {
                guard let i = owner.index(in: workspace),
                      [.queued, .running].contains(workspace.tabs[i].job.state),
                      let batchID = replayBatchID ?? workspace.tabs[i].job.queuedBatchIDs.first else {
                    abandoned = true
                    return
                }
                let batch = schedule.batches[batchID]
                workspace.withTab(i) { tab in
                    if !tab.job.activeBatchIDs.contains(batchID) { _ = tab.job.apply(.batchDispatched(batchID: batchID)) }
                }
                guard let i = owner.index(in: workspace),
                      workspace.tabs[i].job.activeBatchIDs.contains(batchID) else {
                    abandoned = true
                    return
                }
                let requestUnits = batch.unitIDs.compactMap { id -> TranslateBatchUnit? in
                    guard let unit = byID[id], let text = original.requestText(for: unit) else { return nil }
                    return .init(unitID: id, kind: unit.kind, text: text)
                }
                guard requestUnits.count == batch.unitIDs.count else {
                    failBatch(batchID, CoordinatorError.invalidBatch)
                    return
                }
                var request = TranslateBatchRequest(
                    sourceLanguage: resolved.sourceLanguage, targetLanguage: resolved.targetLanguage,
                    contextBefore: batch.contextBefore, contextAfter: batch.contextAfter,
                    units: requestUnits, ownerSessionID: owner.session, promptVersion: resolved.translationPromptVersion
                )
                request.singleTextRecovery = schedule.usesSingleText(batchID)
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
                            owner: owner, original: original,
                            workspace: workspace, resolved: resolved
                        )
                    } catch is CancellationError {
                        if !cancelledByUser { markCancelled() }
                    } catch {
                        failBatch(batchID, error)
                    }
                case let .failure(batchID, gatewayError):
                    if Task.isCancelled { markCancelled(); return }
                    guard owner.index(in: workspace) != nil else {
                        abandoned = true
                        return
                    }
                    if let gatewayError {
                        if schedule.firstFailure == nil, !cancelledByUser, !abandoned, !Task.isCancelled,
                           let delay = gatewayError.glmCooldown(provider: resolved.provider),
                           delay <= WorkerContract.glmAutomaticWaitBudget,
                           replayedBatches.insert(batchID).inserted {
                            startNext(group: &group, replayBatchID: batchID)
                        } else if !handleUnitFailure(batchID, gatewayError) {
                            failBatch(batchID, gatewayError)
                        }
                    } else if schedule.firstFailure == nil && !cancelledByUser {
                        // A cancellation with no earlier failure is the
                        // user cancelling the attempt.
                        markCancelled()
                    } else if let i = owner.index(in: workspace) {
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
                if schedule.firstFailure != nil || cancelledByUser {
                    // Stop paying for further batches; in-flight siblings
                    // drain and may still commit if they already finished.
                    group.cancelAll()
                } else {
                    while canStartMore() { startNext(group: &group) }
                }
            }
        }
        if cancelledByUser { throw CancellationError() }
        guard let index = owner.index(in: workspace) else { return }
        if let firstFailure = schedule.firstFailure { throw firstFailure }
        if workspace.tabs[index].job.state == .failed {
            let completed = workspace.tabs[index].job.completedUnitIDs
            let missing = IndexSet(original.units.enumerated().compactMap { completed.contains($0.element.id) ? nil : $0.offset + 1 })
            throw CoordinatorError.incompleteUnits(missing)
        }
    }

    /// Validates a batch result against its request and commits it
    /// atomically; throws typed errors without mutating document state.
    private func commitBatch(
        _ result: TranslateBatchResult,
        batchID: Int,
        requestedUnitIDs: [UUID],
        owner: AttemptOwner,
        original: BiparaDocument,
        workspace: WorkspaceStore,
        resolved: JobSnapshot
    ) async throws {
        guard let i = owner.index(in: workspace) else { return }
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
        let encodedSize = try await Task.detached {
            if let plan = snapshotToValidate.markdownPlan {
                try plan.validateBatch(snapshotToValidate.translations, language: resolved.targetLanguage, newUnitIDs: Set(requestedUnitIDs))
            }
            return try DocumentCodec.encode(snapshotToValidate).count
        }.value
        guard encodedSize <= WorkerContract.documentFileByteLimit else { throw CoordinatorError.documentTooLarge }
        guard let i = owner.index(in: workspace) else { return }
        workspace.withTab(i) { tab in
            tab.document.translations = candidate.translations
            tab.document.jobSnapshot = candidate.jobSnapshot
            tab.document.resolvedDirection = candidate.resolvedDirection
            tab.contentGeneration += 1
            _ = tab.job.apply(.batchSucceeded(batchID: batchID, unitIDs: result.translations.map(\.unitID)))
        }
    }

    public func cancel(tabIndex: Int, workspace: WorkspaceStore) {
        guard workspace.tabs.indices.contains(tabIndex) else { return }
        active[workspace.tabs[tabIndex].sessionID]?.task.cancel()
        workspace.withTab(tabIndex) { _ = $0.job.apply(.cancel) }
    }

    public func resume(tabIndex: Int, workspace: WorkspaceStore) throws {
        guard workspace.tabs.indices.contains(tabIndex) else { return }
        let tab = workspace.tabs[tabIndex]
        let finished = Set(tab.document.translations.map(\.unitID))
        let plan = SourcePlan(source: tab.document.source, paragraphs: tab.document.paragraphs,
                              units: tab.document.units.filter { !finished.contains($0.id) }, markdownPlan: tab.document.markdownPlan)
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

    public enum CoordinatorError: Error, Equatable {
        case emptyInput, manualDirectionRequired, invalidBatch, documentTooLarge, retiredPromptVersion
        case incompleteUnits(IndexSet)
    }
}

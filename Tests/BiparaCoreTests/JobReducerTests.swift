import Foundation
import Testing
@testable import BiparaCore

@Suite("Job reducer")
struct JobReducerTests {
    private func snapshot(revision: Int = 1) -> JobSnapshot {
        JobSnapshot(
            jobID: UUID(), sourceRevision: revision,
            sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "gpt-4.1-mini-2025-04-14",
            profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1",
            alignmentPromptVersion: "alignment.v1"
        )
    }

    @Test func emptyInputCannotQueue() {
        var model = JobModel()
        let effects = model.apply(.translate(snapshot: snapshot(), batches: [], totalNonblankUnits: 0))
        #expect(model.state == .idle)
        #expect(effects.isEmpty)
    }

    @Test func translateQueuesAndDispatchAdvances() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 6))
        #expect(model.state == .queued)
        #expect(model.attemptGeneration == 1)
        model.apply(.batchDispatched(batchID: 0))
        #expect(model.state == .running)
        #expect(model.activeBatchIDs == [0])
        #expect(model.queuedBatchIDs == [1])
    }

    @Test func batchCommitIsAtomicAndCompletes() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0], totalNonblankUnits: 2))
        model.apply(.batchDispatched(batchID: 0))
        let ids = [UUID(), UUID()]
        let effects = model.apply(.batchSucceeded(batchID: 0, unitIDs: ids))
        #expect(model.completedUnitIDs == Set(ids))
        #expect(model.contentGeneration == 1)
        #expect(model.state == .completed)
        #expect(effects.isEmpty)
    }

    @Test func parallelBatchesDispatchWithinWindow() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1, 2], totalNonblankUnits: 6))
        model.apply(.batchDispatched(batchID: 0))
        model.apply(.batchDispatched(batchID: 1))
        #expect(model.activeBatchIDs == [0, 1])
        #expect(model.queuedBatchIDs == [2])
        // Completion frees a window slot but does not auto-dispatch; the
        // coordinator paces batches explicitly.
        let effects = model.apply(.batchSucceeded(batchID: 1, unitIDs: [UUID(), UUID()]))
        #expect(effects.isEmpty)
        #expect(model.state == .running)
        model.apply(.batchDispatched(batchID: 2))
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: [UUID(), UUID()]))
        _ = model.apply(.batchSucceeded(batchID: 2, unitIDs: [UUID(), UUID()]))
        #expect(model.state == .completed)
    }

    @Test func cancelPausesRetainsCompletedAndAdvancesGeneration() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        model.apply(.batchDispatched(batchID: 1))
        let done = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: done))
        // Batch 1 is still in flight; cancel must ask the coordinator to
        // cancel it.
        let effects = model.apply(.cancel)
        #expect(effects == [.cancelActive])
        #expect(model.state == .paused)
        #expect(model.completedUnitIDs == Set(done))
        #expect(model.attemptGeneration == 2)
        #expect(model.queuedBatchIDs.isEmpty)

        // Cancel while a batch is truly active requests transport cancel.
        var model2 = JobModel()
        model2.apply(.translate(snapshot: snapshot(), batches: [0], totalNonblankUnits: 2))
        model2.apply(.batchDispatched(batchID: 0))
        let cancelEffects = model2.apply(.cancel)
        #expect(cancelEffects == [.cancelActive])
        #expect(model2.state == .paused)
    }

    @Test func resumeKeepsCompletedUnitsAndSnapshot() {
        var model = JobModel()
        let original = snapshot()
        model.apply(.translate(snapshot: original, batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        let done = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: done))
        _ = model.apply(.cancel)
        model.apply(.resume(batches: [1]))
        #expect(model.state == .queued)
        #expect(model.completedUnitIDs == Set(done))
        #expect(model.snapshot == original)
        #expect(model.attemptGeneration == 3)
        #expect(model.queuedBatchIDs == [1])
    }

    @Test func batchFailedPreservesCompletedAndStopsDispatch() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1, 2], totalNonblankUnits: 6))
        model.apply(.batchDispatched(batchID: 0))
        model.apply(.batchDispatched(batchID: 1))
        let done = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: done))
        _ = model.apply(.batchFailed(batchID: 1))
        #expect(model.state == .failed)
        #expect(model.completedUnitIDs == Set(done))
        #expect(model.queuedBatchIDs.isEmpty)
        #expect(model.activeBatchIDs.isEmpty)
    }

    @Test func siblingCommitAfterFailurePreservesWork() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        model.apply(.batchDispatched(batchID: 1))
        _ = model.apply(.batchFailed(batchID: 0))
        #expect(model.state == .failed)
        // A sibling that already finished may still commit its paid work.
        let done = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 1, unitIDs: done))
        #expect(model.completedUnitIDs == Set(done))
        #expect(model.state == .failed)
    }

    @Test func staleBatchEventsAreIgnored() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0], totalNonblankUnits: 2))
        // A result for a batch never dispatched cannot commit.
        let effects = model.apply(.batchSucceeded(batchID: 7, unitIDs: [UUID()]))
        #expect(effects.isEmpty)
        #expect(model.completedUnitIDs.isEmpty)
        // Double terminal for the same batch commits once.
        model.apply(.batchDispatched(batchID: 0))
        let ids = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: ids))
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: ids))
        #expect(model.completedUnitIDs.count == 2)
        #expect(model.contentGeneration == 1)
    }

    @Test func sourceEditResetsEverything() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: [UUID(), UUID()]))
        _ = model.apply(.sourceEdited)
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
        #expect(model.completedUnitIDs.isEmpty)
        #expect(model.totalNonblankUnits == 0)
    }

    @Test func workerFailurePausesAndKeepsData() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        let done = [UUID(), UUID()]
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: done))
        _ = model.apply(.workerFailed)
        #expect(model.state == .paused)
        #expect(model.completedUnitIDs == Set(done))
        #expect(model.snapshot != nil)
    }

    @Test func retranslateStartsFreshWithNewSnapshot() {
        var model = JobModel()
        let first = snapshot()
        model.apply(.translate(snapshot: first, batches: [0], totalNonblankUnits: 2))
        model.apply(.batchDispatched(batchID: 0))
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: [UUID(), UUID()]))
        #expect(model.state == .completed)
        let second = snapshot()
        model.apply(.retranslate(snapshot: second, batches: [0]))
        #expect(model.state == .queued)
        #expect(model.snapshot == second)
        #expect(model.completedUnitIDs.isEmpty)
        #expect(model.queuedBatchIDs == [0])
    }

    @Test func missingUnitsWithNoDispatchableWorkFails() {
        // A plan change under the job: the batch committed but fewer units
        // arrived than the job's total, and nothing remains to dispatch.
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        _ = model.apply(.batchSucceeded(batchID: 0, unitIDs: [UUID(), UUID()]))
        #expect(model.state == .failed)
        #expect(model.completedUnitIDs.count == 2)
        #expect(model.queuedBatchIDs.isEmpty && model.activeBatchIDs.isEmpty)
    }

    @Test func sourceEditCancelsActiveBatch() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1], totalNonblankUnits: 4))
        model.apply(.batchDispatched(batchID: 0))
        let effects = model.apply(.sourceEdited)
        #expect(effects == [.cancelActive])
        #expect(model.state == .idle)

        var idleModel = JobModel()
        idleModel.apply(.translate(snapshot: snapshot(), batches: [0], totalNonblankUnits: 2))
        idleModel.apply(.batchDispatched(batchID: 0))
        _ = idleModel.apply(.batchSucceeded(batchID: 0, unitIDs: [UUID(), UUID()]))
        #expect(idleModel.apply(.sourceEdited).isEmpty)
    }

    @Test func dispatchBeyondParallelWindowIsRefused() {
        var model = JobModel()
        model.apply(.translate(snapshot: snapshot(), batches: [0, 1, 2], totalNonblankUnits: 6))
        model.apply(.batchDispatched(batchID: 0))
        model.apply(.batchDispatched(batchID: 1))
        // Two concurrent batches per document session: a third while both
        // are active is a coordinator defect and is refused.
        let effects = model.apply(.batchDispatched(batchID: 2))
        #expect(effects.isEmpty)
        #expect(model.activeBatchIDs == [0, 1])
        #expect(model.queuedBatchIDs == [2])
    }

    @Test func whitespaceOnlyUnitsCountAsHandled() {
        // A document whose only translatable content is blank units: the
        // reducer is configured with totalNonblankUnits 0 and never queues.
        var model = JobModel(totalNonblankUnits: 0)
        model.apply(.translate(snapshot: snapshot(), batches: [], totalNonblankUnits: 0))
        #expect(model.state == .idle)
        #expect(model.isFinished == false)
    }
}

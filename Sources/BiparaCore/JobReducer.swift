import Foundation

/// Lifecycle states of one document translation job.
public enum JobState: String, Codable, Sendable, Equatable {
    case idle
    case queued
    case running
    case paused
    case failed
    case completed
}

/// Effects the coordinator must perform after a transition. Batch pacing
/// itself is coordinator-owned (up to
/// `WorkerContract.translationBatchesPerSession` batches in flight), so the
/// reducer emits no dispatch effects; the app layer cancels in-flight
/// transport directly, and these effects remain the reducer's contract
/// surface, asserted by tests.
public enum JobEffect: Equatable, Sendable {
    /// Cancel the in-flight operations of the invalidated attempt.
    case cancelActive
}

/// Events driving one document session's job, per the lifecycle table.
public enum JobEvent: Equatable, Sendable {
    /// Translate: snapshot configuration and queue unfinished batches.
    case translate(snapshot: JobSnapshot, batches: [Int], totalNonblankUnits: Int)
    /// The coordinator dispatched a queued batch.
    case batchDispatched(batchID: Int)
    /// A batch committed atomically; all its units are now complete.
    case batchSucceeded(batchID: Int, unitIDs: [UUID])
    /// Replace an active batch with its two smaller requests.
    case batchSplit(batchID: Int, replacementIDs: [Int])
    /// A batch failed; completed work is preserved.
    case batchFailed(batchID: Int)
    /// Cancel: invalidate the attempt, drop queued work, cancel active.
    case cancel
    /// Resume or retry with the retained snapshot and completed units.
    case resume(batches: [Int])
    /// Worker/process failure: fail active work, pause the queue.
    case workerFailed
    /// Applied source/direction edit: everything resets to idle.
    case sourceEdited
    /// Explicit retranslate: fresh job with a new snapshot.
    case retranslate(snapshot: JobSnapshot, batches: [Int])
}

/// Pure job lifecycle reducer. The coordinator (app layer) owns dispatch,
/// cancellation transport, and generation guards; this type owns state.
public struct JobModel: Equatable, Sendable {
    public var state: JobState
    public var snapshot: JobSnapshot?
    public var completedUnitIDs: Set<UUID>
    public var totalNonblankUnits: Int
    /// Increments on translate/cancel/resume: results from an older
    /// attempt generation can never commit.
    public var attemptGeneration: Int
    /// Increments on each atomic batch commit.
    public var contentGeneration: Int
    public var queuedBatchIDs: [Int]
    public var activeBatchIDs: Set<Int>
    /// Batches that already committed in this job.
    public var committedBatchIDs: Set<Int>

    public init(totalNonblankUnits: Int = 0) {
        state = .idle
        snapshot = nil
        completedUnitIDs = []
        self.totalNonblankUnits = totalNonblankUnits
        attemptGeneration = 0
        contentGeneration = 0
        queuedBatchIDs = []
        activeBatchIDs = []
        committedBatchIDs = []
    }

    public var isFinished: Bool {
        totalNonblankUnits > 0 && completedUnitIDs.count >= totalNonblankUnits
    }

    public mutating func apply(_ event: JobEvent) -> [JobEffect] {
        switch event {
        case let .translate(snapshot, batches, totalUnits):
            guard state == .idle || state == .completed || state == .paused || state == .failed,
                  totalUnits > 0, !batches.isEmpty else { return [] }
            self.snapshot = snapshot
            totalNonblankUnits = totalUnits
            queuedBatchIDs = batches
            activeBatchIDs = []
            committedBatchIDs = []
            completedUnitIDs = []
            attemptGeneration += 1
            state = .queued
            return []

        case let .batchDispatched(batchID):
            // Up to `translationBatchesPerSession` batches may be active
            // per document session; dispatching beyond that window is a
            // coordinator defect and is refused.
            guard state == .queued || state == .running,
                  activeBatchIDs.count < WorkerContract.translationBatchesPerSession,
                  let index = queuedBatchIDs.firstIndex(of: batchID) else { return [] }
            queuedBatchIDs.remove(at: index)
            activeBatchIDs.insert(batchID)
            state = .running
            return []

        case let .batchSucceeded(batchID, unitIDs):
            guard activeBatchIDs.contains(batchID) else { return [] }
            activeBatchIDs.remove(batchID)
            committedBatchIDs.insert(batchID)
            for id in unitIDs where !completedUnitIDs.contains(id) {
                completedUnitIDs.insert(id)
            }
            contentGeneration += 1
            if isFinished {
                state = .completed
                queuedBatchIDs = []
            } else if queuedBatchIDs.isEmpty && activeBatchIDs.isEmpty {
                // No more dispatchable work although units are missing:
                // the plan changed under the job; treat as failed safely.
                state = .failed
            }
            return []

        case let .batchSplit(batchID, replacementIDs):
            guard state == .running, activeBatchIDs.remove(batchID) != nil else { return [] }
            queuedBatchIDs.insert(contentsOf: replacementIDs, at: 0)
            return []

        case let .batchFailed(batchID):
            guard activeBatchIDs.contains(batchID) else { return [] }
            activeBatchIDs.remove(batchID)
            queuedBatchIDs = []
            state = .failed
            return []

        case .cancel:
            guard state == .queued || state == .running else { return [] }
            queuedBatchIDs = []
            attemptGeneration += 1
            let hadActive = !activeBatchIDs.isEmpty
            activeBatchIDs = []
            state = .paused
            return hadActive ? [.cancelActive] : []

        case let .resume(batches):
            guard state == .paused || state == .failed,
                  let snapshot = snapshot, !batches.isEmpty, !isFinished else {
                return []
            }
            _ = snapshot
            queuedBatchIDs = batches
            activeBatchIDs = []
            attemptGeneration += 1
            state = .queued
            return []

        case .workerFailed:
            guard state == .queued || state == .running else { return [] }
            activeBatchIDs = []
            queuedBatchIDs = []
            state = .paused
            return []

        case .sourceEdited:
            let hadActive = !activeBatchIDs.isEmpty
            state = .idle
            snapshot = nil
            completedUnitIDs = []
            totalNonblankUnits = 0
            attemptGeneration += 1
            queuedBatchIDs = []
            activeBatchIDs = []
            committedBatchIDs = []
            return hadActive ? [.cancelActive] : []

        case let .retranslate(snapshot, batches):
            guard state != .queued, state != .running, !batches.isEmpty else { return [] }
            self.snapshot = snapshot
            // The source revision is unchanged, so the planned unit total
            // is unchanged; retranslation only replaces results.
            queuedBatchIDs = batches
            activeBatchIDs = []
            committedBatchIDs = []
            completedUnitIDs = []
            contentGeneration += 1
            attemptGeneration += 1
            state = .queued
            return []
        }
    }
}

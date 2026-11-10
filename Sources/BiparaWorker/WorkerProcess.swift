import BiparaCore
import Foundation

/// Sendable terminal payload crossing the actor boundary: the strict
/// data/meta objects as preflighted JSON bytes.
public struct WireTerminal: Sendable {
    public var dataJSON: Data
    public var metaJSON: Data
}

/// One live worker child process and its per-request registry. Only the
/// owning `WorkerManager` actor touches instance state; reader callbacks
/// hop into the manager by instance identity so a poisoned or replaced
/// instance's late frames are ignored.
/// `@unchecked Sendable` confinement contract: all mutable registry state
/// (`pending`, `terminalSeen`, `didCompleteHandshake`) is touched only on
/// the owning `WorkerManager` actor; cross-domain uses are the immutable
/// pipes/process/writer handles, which are individually thread-safe.
final class WorkerInstance: @unchecked Sendable {
    let id = UUID()
    let process = Process()
    let writer = FrameWriter()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    var outputTask: Task<Void, Never>?
    var stderrBytes = 0

    private(set) var pending: [String: PendingRequest] = [:]
    private(set) var terminalSeen: Set<String> = []
    private(set) var didCompleteHandshake = false

    let executableURL: URL
    let expectedPromptVersions: [String]
    let expectedMaxInflight: Int
    let timeouts: GatewayTimeouts
    let environment: @Sendable () -> [String: String]

    init(
        executableURL: URL,
        expectedPromptVersions: [String],
        expectedMaxInflight: Int,
        timeouts: GatewayTimeouts,
        environment: @escaping @Sendable () -> [String: String]
    ) {
        self.executableURL = executableURL
        self.expectedPromptVersions = expectedPromptVersions
        self.expectedMaxInflight = expectedMaxInflight
        self.timeouts = timeouts
        self.environment = environment
    }

    /// Configures and launches the child. Throws before spawn on a missing
    /// executable; a spawn failure maps to a local startup error.
    func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GatewayError(code: .executableMissing, isLocal: true)
        }
        process.executableURL = executableURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environment()
        do {
            try process.run()
        } catch {
            throw GatewayError(code: .startupFailed, isLocal: true)
        }
        writer.attach(handle: stdin.fileHandleForWriting)
    }

    // MARK: Frame emission (manager-actor confined)

    func sendHello() {
        writer.write(frame: ["v": 2, "type": "hello"])
    }

    func sendShutdown() {
        writer.write(frame: ["v": 2, "type": "shutdown"])
    }

    func sendCancel(requestID: String) {
        writer.write(frame: ["v": 2, "type": "cancel", "id": requestID])
    }

    /// Serializes the exact translate request envelope. UUIDs are canonical
    /// lowercase; the credential travels only inside the frame.
    private static func wireConfig(_ configuration: ModelConfiguration) -> [String: Any] {
        var config: [String: Any] = ["provider": configuration.provider, "model": configuration.model,
            "profile": configuration.profile, "base_url": configuration.baseURL, "effort": configuration.effort.rawValue]
        if let options = configuration.requestOptions,
           let data = try? JSONEncoder().encode(options), let json = try? JSONSerialization.jsonObject(with: data) {
            config["options"] = json
        }
        return config
    }

    private static func wireCredentials(_ configuration: ModelConfiguration) -> [String: Any] {
        var credentials: [String: Any] = ["api_key": configuration.apiKey]
        if configuration.requestOptions != nil { credentials["headers"] = configuration.secretHeaders }
        return credentials
    }

    func sendTranslate(
        _ request: TranslateBatchRequest,
        configuration: ModelConfiguration,
        requestID: String
    ) {
        writer.write(frame: [
            "v": 2,
            "type": "request",
            "id": requestID,
            "op": "translate",
            "config": Self.wireConfig(configuration),
            "credentials": Self.wireCredentials(configuration),
            "prompt_version": request.promptVersion,
            "input": [
                "source_language": request.sourceLanguage.rawValue,
                "target_language": request.targetLanguage.rawValue,
                "context_before": request.contextBefore,
                "context_after": request.contextAfter,
                "units": request.units.map { unit in
                    [
                        "unit_id": unit.unitID.uuidString.lowercased(),
                        "kind": unit.kind.rawValue,
                        "text": unit.text,
                    ] as [String: Any]
                },
            ] as [String: Any],
        ])
    }

    func sendAlign(
        _ request: AlignSelectionRequest,
        configuration: ModelConfiguration,
        requestID: String
    ) {
        writer.write(frame: [
            "v": 2,
            "type": "request",
            "id": requestID,
            "op": "align",
            "config": Self.wireConfig(configuration),
            "credentials": Self.wireCredentials(configuration),
            "prompt_version": "alignment.v1",
            "input": [
                "reading_text": request.readingText,
                "counterpart_text": request.counterpartText,
                "selection": [
                    "before": request.before,
                    "text": request.selectedText,
                    "after": request.after,
                ],
            ] as [String: Any],
        ])
    }

    // MARK: Registry (manager-actor confined)

    /// The physical in-flight count includes draining (cancelled) entries:
    /// a slot is released only at the terminal event.
    var physicalSlotsInUse: Int { pending.count }

    func register(entry: PendingRequest) {
        pending[entry.requestID] = entry
    }

    func entry(for requestID: String) -> PendingRequest? { pending[requestID] }

    func removeEntry(requestID: String) -> PendingRequest? { pending.removeValue(forKey: requestID) }

    func markTerminalSeen(requestID: String) { terminalSeen.insert(requestID) }

    func hasSeenTerminal(requestID: String) -> Bool { terminalSeen.contains(requestID) }

    var pendingEntries: [PendingRequest] { Array(pending.values) }

    func completeHandshake() { didCompleteHandshake = true }

    // MARK: Teardown

    /// Close stdin behind queued frames; permit cooperative shutdown before
    /// escalating. A poisoned worker skips only the cooperative stage.
    func terminateWithEscalation(graceful: Bool = false) async {
        writer.close()
        if graceful { await waitForExit(seconds: timeouts.shutdownTerm) }
        if process.isRunning {
            process.terminate()
            await waitForExit(seconds: timeouts.shutdownKill)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.processIdentifier > 0 {
            await Task.detached { [process] in process.waitUntilExit() }.value
        }
        outputTask?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private func waitForExit(seconds: TimeInterval) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Outcome of one accepted request. Exactly-once delivery to the caller is
/// guaranteed by the entry lock: a terminal that wins stores the outcome;
/// a caller cancellation that wins stores `.cancelledByCaller`. An
/// already-emitted terminal always wins over a later cancellation.
enum PendingOutcome {
    case payload(WireTerminal)
    case failure(GatewayError)
    case cancelledByCaller
}

/// In-memory identity of an independently scheduled GLM connection.
struct GLMRoute: Hashable, Sendable {
    let configurationID: UUID?
    let baseURL: String
    let model: String

    init?(_ configuration: ModelConfiguration) {
        guard configuration.provider == "glm" else { return nil }
        configurationID = configuration.configurationID
        baseURL = configuration.baseURL
        model = configuration.model
    }
}

/// A pending (or cancelled-and-draining) request.
final class PendingRequest: @unchecked Sendable {
    let requestID: String
    let owner: UUID?
    let route: GLMRoute?
    let isTranslation: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WireTerminal, Error>?
    private var outcome: PendingOutcome?

    init(requestID: String, owner: UUID?, route: GLMRoute?, isTranslation: Bool) {
        self.owner = owner
        self.route = route
        self.isTranslation = isTranslation
        self.requestID = requestID
    }

    func dispatchIfActive(_ dispatch: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if outcome == nil { dispatch() }
    }

    func awaitTerminal() async throws -> WireTerminal {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WireTerminal, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if let outcome {
                continuation.resume(with: Self.deliver(outcome))
            } else {
                self.continuation = continuation
            }
        }
    }

    /// A terminal event arrived. If the caller already cancelled, the
    /// outcome is recorded for bookkeeping only; the registry entry was
    /// already removed, releasing the physical slot.
    func finish(terminal: PendingOutcome) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = terminal
        if let continuation {
            self.continuation = nil
            continuation.resume(with: Self.deliver(terminal))
        }
    }

    /// The calling Swift task cancelled: resume the caller with
    /// CancellationError; the entry stays registered until its terminal.
    func cancelFromCaller() {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return } // terminal already won
        outcome = .cancelledByCaller
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private static func deliver(_ outcome: PendingOutcome) -> Result<WireTerminal, Error> {
        switch outcome {
        case .payload(let payload): return .success(payload)
        case .failure(let error): return .failure(error)
        case .cancelledByCaller: return .failure(CancellationError())
        }
    }
}

/// Single serialized frame writer on a dedicated serial queue; each frame
/// is one compact LF-terminated line written whole.
final class FrameWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bipara.worker-writer")
    private var handle: FileHandle?

    func attach(handle newHandle: FileHandle) {
        queue.sync { handle = newHandle }
    }

    func write(frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        if line.count > WorkerContract.maxFrameBytes { return }
        queue.async { [handle = handle, line] in
            try? handle?.write(contentsOf: line)
        }
    }

    func close() {
        queue.async { [handle = handle] in
            try? handle?.close()
        }
    }
}

/// Owns the single worker instance, its lifecycle states, and frame
/// ingestion. States: stopped / starting / ready / stopping, with one
/// shared startup task and lazy relaunch after poisoning.
actor WorkerManager {
    private enum State {
        case stopped
        case starting
        case ready(WorkerInstance)
        case stopping(WorkerInstance)
    }

    private var state: State = .stopped
    private var shuttingDown = false
    private var handshakeWaiters: [String: (UUID?, CheckedContinuation<Void, Error>)] = [:]
    private var teardownTask: Task<Void, Never>?
    /// Queued entries hold no physical slot or transport watchdog.
    private struct AdmissionWaiter {
        let entry: PendingRequest
        let waitDeadline: ContinuousClock.Instant
        let isReplay: Bool
        let dispatch: @Sendable (WorkerInstance, String) -> Void
    }
    private var admissionWaiters: [AdmissionWaiter] = []
    private struct RateLimit {
        let cooldownEnds: ContinuousClock.Instant
        let serializedUntil: ContinuousClock.Instant
        let error: GatewayError
        let wakeup: Task<Void, Never>
    }
    private var rateLimits: [GLMRoute: RateLimit] = [:]
    /// Which request class was admitted last, so translation and alignment
    /// alternate when both queues are nonempty and neither can starve.
    private var lastAdmissionWasTranslation = false
    private var handshakeFailure: (UUID, GatewayError)?

    private let executableURL: URL
    private let expectedPromptVersions: [String]
    private let expectedMaxInflight: Int
    private let maxRequestsPerOwner: Int
    private let timeouts: GatewayTimeouts
    private let environment: @Sendable () -> [String: String]
    private var handshakeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var watchdogTasks: [String: Task<Void, Never>] = [:]

    init(
        executableURL: URL,
        expectedPromptVersions: [String],
        expectedMaxInflight: Int,
        maxRequestsPerOwner: Int = WorkerContract.translationBatchesPerSession,
        timeouts: GatewayTimeouts,
        environment: @escaping @Sendable () -> [String: String]
    ) {
        self.executableURL = executableURL
        self.expectedPromptVersions = expectedPromptVersions
        self.expectedMaxInflight = expectedMaxInflight
        self.maxRequestsPerOwner = maxRequestsPerOwner
        self.timeouts = timeouts
        self.environment = environment
    }

    // MARK: Operations

    /// Runs `dispatch` against a ready instance and awaits one terminal
    /// event, honoring Swift-task cancellation: the cancel frame is sent,
    /// the caller resumes immediately, and the registry entry drains until
    /// its terminal releases the physical slot.
    func perform(
        owner: UUID? = nil,
        route: GLMRoute? = nil,
        isTranslation: Bool = false,
        replayDeadline: ContinuousClock.Instant? = nil,
        _ dispatch: @escaping @Sendable (WorkerInstance, String) -> Void
    ) async throws -> WireTerminal {
        let requestID = UUID().uuidString.lowercased()
        let entry = PendingRequest(requestID: requestID, owner: owner, route: route, isTranslation: isTranslation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let instance = try await ensureReady(requestID: requestID)
            try Task.checkCancellation()
            if shuttingDown { throw GatewayError(code: .shuttingDown, isLocal: true) }
            guard case .ready(let current) = state, current.id == instance.id else {
                throw GatewayError(code: .workerDied, isLocal: true)
            }
            admissionWaiters.append(AdmissionWaiter(
                entry: entry, waitDeadline: replayDeadline ?? (ContinuousClock.now + WorkerContract.glmAutomaticWaitBudget),
                isReplay: replayDeadline != nil, dispatch: dispatch
            ))
            admitWaiting(instance: instance)
            return try await entry.awaitTerminal()
        } onCancel: {
            entry.cancelFromCaller()
            Task { await self.cancelOperation(requestID: requestID) }
        }
    }

    private func routeBlocks(_ entry: PendingRequest, in instance: WorkerInstance, now: ContinuousClock.Instant) -> Bool {
        guard let route = entry.route, let limit = rateLimits[route], now < limit.serializedUntil else { return false }
        return now < limit.cooldownEnds || instance.pendingEntries.contains { $0.route == route }
    }

    private func canAdmit(_ entry: PendingRequest, in instance: WorkerInstance, now: ContinuousClock.Instant) -> Bool {
        guard !routeBlocks(entry, in: instance, now: now) else { return false }
        guard let owner = entry.owner else { return true }
        return instance.pendingEntries.lazy.filter { $0.owner == owner }.count < maxRequestsPerOwner
    }

    /// Select and register each operation atomically, skipping cooled routes.
    private func admitWaiting(instance: WorkerInstance) {
        let now = ContinuousClock.now
        admissionWaiters.removeAll { waiter in
            let entry = waiter.entry
            guard let route = entry.route, let limit = rateLimits[route],
                  (now < limit.cooldownEnds && limit.cooldownEnds > waiter.waitDeadline) ||
                  (!entry.isTranslation && routeBlocks(entry, in: instance, now: now)) else { return false }
            var error = limit.error
            error.isLocal = true
            entry.finish(terminal: .failure(error))
            return true
        }
        while instance.physicalSlotsInUse < expectedMaxInflight {
            let translation = admissionWaiters.firstIndex {
                $0.entry.owner != nil && canAdmit($0.entry, in: instance, now: now)
            }
            let alignment = admissionWaiters.firstIndex {
                $0.entry.owner == nil && canAdmit($0.entry, in: instance, now: now)
            }
            guard var chosen = lastAdmissionWasTranslation ? (alignment ?? translation) : (translation ?? alignment) else { return }
            if admissionWaiters[chosen].entry.isTranslation, let route = admissionWaiters[chosen].entry.route,
               let replay = admissionWaiters.firstIndex(where: {
                   $0.isReplay && $0.entry.route == route && canAdmit($0.entry, in: instance, now: now)
               }) {
                chosen = replay
            }
            let waiter = admissionWaiters.remove(at: chosen)
            let entry = waiter.entry
            entry.dispatchIfActive {
                instance.register(entry: entry)
                lastAdmissionWasTranslation = entry.owner != nil
                waiter.dispatch(instance, entry.requestID)
                startWatchdog(instance: instance, requestID: entry.requestID)
            }
        }
    }

    private func recordRateLimit(for entry: PendingRequest, error: GatewayError) {
        guard entry.isTranslation, let route = entry.route, let delay = error.glmCooldown(provider: "glm") else { return }
        let now = ContinuousClock.now
        let cooldownEnds = max(rateLimits[route]?.cooldownEnds ?? now, now + delay)
        let serializedUntil = cooldownEnds + WorkerContract.glmSerializedWindow
        rateLimits[route]?.wakeup.cancel()
        let wakeup = Task { [weak self] in
            do {
                try await Task.sleep(until: cooldownEnds, clock: .continuous)
                try Task.checkCancellation()
                await self?.admitAfterRateLimitChange()
                try await Task.sleep(until: serializedUntil, clock: .continuous)
                try Task.checkCancellation()
                await self?.restoreRateLimit(for: route)
            } catch {
                // A later limit or shutdown replaced this wakeup.
            }
        }
        rateLimits[route] = RateLimit(cooldownEnds: cooldownEnds, serializedUntil: serializedUntil,
                                     error: error, wakeup: wakeup)
    }

    private func admitAfterRateLimitChange() {
        if case .ready(let instance) = state { admitWaiting(instance: instance) }
    }

    private func restoreRateLimit(for route: GLMRoute) {
        guard let limit = rateLimits[route], ContinuousClock.now >= limit.serializedUntil else { return }
        rateLimits[route] = nil
        admitAfterRateLimitChange()
    }

    private func cancelOperation(requestID: String) {
        if let index = admissionWaiters.firstIndex(where: { $0.entry.requestID == requestID }) {
            admissionWaiters.remove(at: index).entry.cancelFromCaller()
        }
        if let (_, waiter) = handshakeWaiters.removeValue(forKey: requestID) {
            waiter.resume(throwing: CancellationError())
        }
        if case .ready(let instance) = state {
            cancelRequest(instanceID: instance.id, requestID: requestID)
        }
    }

    func cancelRequest(instanceID: UUID, requestID: String) {
        guard case .ready(let instance) = state, instance.id == instanceID,
              let entry = instance.entry(for: requestID) else {
            return // unknown or already-terminal: do nothing
        }
        entry.cancelFromCaller()
        instance.sendCancel(requestID: requestID)
    }

    func shutdown() async {
        shuttingDown = true
        for limit in rateLimits.values { limit.wakeup.cancel() }
        rateLimits.removeAll()
        if case .ready(let instance) = state {
            await stop(instance, error: GatewayError(code: .shuttingDown, isLocal: true), graceful: true)
        } else if let teardownTask {
            await teardownTask.value
        }
        resumeHandshakeWaiters(instanceID: nil, error: GatewayError(code: .shuttingDown, isLocal: true))
    }

    // MARK: Lifecycle

    /// Brings the single instance up and waits for a VALIDATED handshake:
    /// no request — and therefore no credential — is sent before the
    /// `ready` frame's versions and max_inflight match the contract.
    private func ensureReady(requestID: String) async throws -> WorkerInstance {
        try Task.checkCancellation()
        if shuttingDown { throw GatewayError(code: .shuttingDown, isLocal: true) }
        if case .ready(let instance) = state {
            try await waitForHandshake(instance, requestID: requestID)
            return instance
        }
        if case .stopping = state {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handshakeWaiters[requestID] = (nil, continuation)
            }
            return try await ensureReady(requestID: requestID)
        }
        // The launch path contains no suspension points before state
        // becomes .ready, so concurrent first callers serialize here and
        // exactly one instance is launched (the shared startup task).
        let instance = WorkerInstance(
            executableURL: executableURL,
            expectedPromptVersions: expectedPromptVersions,
            expectedMaxInflight: expectedMaxInflight,
            timeouts: timeouts,
            environment: environment
        )
        state = .starting
        do {
            try instance.launch() // executableMissing / startupFailed
        } catch {
            state = .stopped
            throw error
        }
        state = .ready(instance)
        attachReaders(instance)
        instance.sendHello()

        // Startup deadline: ready must validate before it passes.
        handshakeTimeoutTasks[instance.id] = Task { [instanceID = instance.id, timeouts] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.startup * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.poisonInstance(
                instanceID,
                error: GatewayError(code: .startupFailed, isLocal: true)
            )
        }
        try await waitForHandshake(instance, requestID: requestID)
        return instance
    }

    /// Suspends until this instance's handshake validates or fails.
    private func waitForHandshake(_ instance: WorkerInstance, requestID: String) async throws {
        try Task.checkCancellation()
        if instance.didCompleteHandshake { return }
        if let failure = handshakeFailure, failure.0 == instance.id {
            throw failure.1
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            handshakeWaiters[requestID] = (instance.id, continuation)
        }
    }

    private func resumeHandshakeWaiters(instanceID: UUID?, error: GatewayError?) {
        let matching = handshakeWaiters.filter { $0.value.0 == instanceID }
        for (key, (_, continuation)) in matching {
            handshakeWaiters[key] = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    private func attachReaders(_ instance: WorkerInstance) {
        let instanceID = instance.id
        let framer = FrameAccumulator()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(16))
        instance.stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
            else {
                guard let frames = framer.append(chunk) else {
                    handle.readabilityHandler = nil; continuation.finish()
                    if let self { Task { await self.stdoutClosed(instanceID: instanceID) } }
                    return
                }
                for frame in frames {
                    if case .dropped = continuation.yield(frame) {
                        handle.readabilityHandler = nil; continuation.finish()
                        if let self { Task { await self.stdoutClosed(instanceID: instanceID) } }
                        return
                    }
                }
            }
        }
        instance.outputTask = Task { [weak self] in
            for await chunk in stream {
                guard let self, !Task.isCancelled else { break }
                await self.ingest(chunk: chunk, instanceID: instanceID)
            }
            if let self { await self.stdoutClosed(instanceID: instanceID) }
        }
        instance.stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Content is discarded; byte counts are kept on the instance.
            guard let self else { return }
            Task { await self.noteStderr(instanceID: instanceID, bytes: chunk.count) }
        }
        instance.process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleProcessExit(instanceID: instanceID) }
        }
    }

    private func noteStderr(instanceID: UUID, bytes: Int) {
        guard case .ready(let instance) = state, instance.id == instanceID else { return }
        instance.stderrBytes += bytes
    }

    // MARK: Ingestion

    private func ingest(chunk: Data, instanceID: UUID) async {
        guard case .ready(let instance) = state, instance.id == instanceID else { return }
        await handleFrame(chunk, instance: instance)
    }

    private func handleFrame(_ data: Data, instance: WorkerInstance) async {
        // Shared strict preflight: UTF-8, size, duplicate decoded keys,
        // non-finite numbers — before any structural interpretation.
        guard (try? StrictJSON.preflight(data, maxBytes: WorkerContract.maxFrameBytes)) != nil,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = try? asInt(object["v"]), let type = object["type"] as? String
        else {
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
            return
        }
        if version != WorkerContract.protocolVersion {
            // A protocol-1 peer is rejected at handshake before any
            // credential-bearing request is transmitted.
            await poisonInstance(instance.id, error: GatewayError(code: .incompatibleWorker, isLocal: true))
            return
        }
        switch type {
        case "ready":
            await handleReady(object, instance: instance)
        case "result":
            await handleTerminal(object, instance: instance) { frame in
                guard let dataJSON = try? JSONSerialization.data(withJSONObject: asObject(frame["data"])),
                      let metaJSON = try? JSONSerialization.data(withJSONObject: asObject(frame["meta"]))
                else {
                    throw GatewayError(code: .invalidOutput)
                }
                return .payload(WireTerminal(dataJSON: dataJSON, metaJSON: metaJSON))
            }
        case "error":
            guard (try? WorkerManager.mapError(object)) != nil else {
                await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
                return
            }
            await handleTerminal(object, instance: instance) { frame in
                .failure(try WorkerManager.mapError(frame))
            }
        case "cancelled":
            // Normal only for an entry the caller cancelled (its
            // continuation already resumed; this releases the slot).
            await handleTerminal(object, instance: instance) { _ in
                .failure(GatewayError(code: .workerFailed, isLocal: true))
            }
        case "stopped":
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
        case "fatal":
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
        default:
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
        }
    }

    private func handleReady(_ object: [String: Any], instance: WorkerInstance) async {
        guard !instance.didCompleteHandshake else {
            let error = GatewayError(code: .incompatibleWorker, isLocal: true)
            resumeHandshakeWaiters(instanceID: instance.id, error: error)
            await poisonInstance(instance.id, error: error)
            return
        }
        let compatible: Bool
        do {
            let version = try jsonKey(object, "worker_version") { try asString($0) }
            let maxInflight = try jsonKey(object, "max_inflight") { try asInt($0) }
            let prompts = try jsonKey(object, "prompt_versions") { value in
                try asArray(value).map { try asString($0) }
            }
            compatible = !version.isEmpty
                && maxInflight == instance.expectedMaxInflight
                && prompts.count == instance.expectedPromptVersions.count
                && Set(prompts) == Set(instance.expectedPromptVersions)
        } catch {
            compatible = false
        }
        handshakeTimeoutTasks[instance.id]?.cancel()
        handshakeTimeoutTasks[instance.id] = nil
        guard compatible else {
            let error = GatewayError(code: .incompatibleWorker, isLocal: true)
            handshakeFailure = (instance.id, error)
            resumeHandshakeWaiters(instanceID: instance.id, error: error)
            await poisonInstance(instance.id, error: error)
            return
        }
        instance.completeHandshake()
        resumeHandshakeWaiters(instanceID: instance.id, error: nil)
    }

    /// Terminal-event guard: unknown or duplicate terminal IDs from the
    /// current live worker are protocol failures. One terminal per entry.
    private func handleTerminal(
        _ object: [String: Any],
        instance: WorkerInstance,
        map: @Sendable ([String: Any]) throws -> PendingOutcome
    ) async {
        guard let requestID = object["id"] as? String else {
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
            return
        }
        guard !instance.hasSeenTerminal(requestID: requestID) else {
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
            return
        }
        guard instance.entry(for: requestID) != nil else {
            await poisonInstance(instance.id, error: GatewayError(code: .workerDied, isLocal: true))
            return
        }
        instance.markTerminalSeen(requestID: requestID)
        let entry = instance.removeEntry(requestID: requestID)!
        watchdogTasks[requestID]?.cancel()
        watchdogTasks[requestID] = nil
        let outcome: PendingOutcome
        do {
            outcome = try map(object)
        } catch {
            outcome = .failure(GatewayError(code: .invalidOutput))
        }
        if case .failure(let error) = outcome { recordRateLimit(for: entry, error: error) }
        entry.finish(terminal: outcome)
        admitWaiting(instance: instance)
    }

    nonisolated static func mapError(_ object: [String: Any]) throws -> GatewayError {
        let raw = try jsonKey(object, "code") { try asString($0) }
        let allowed: Set<String> = ["invalid_request", "unsupported_capability", "missing_credential", "authentication", "model_unavailable", "quota_exceeded", "rate_limited", "network", "timeout", "context_limit", "output_limit", "refused", "invalid_output", "busy", "worker_failed"]
        guard allowed.contains(raw), let code = GatewayError.Code(rawValue: raw) else { throw GatewayError(code: .invalidOutput) }
        let retry = try jsonKey(object, "retry_after_ms") { try asOptionalInt($0) }
        guard retry == nil || (0...3_600_000).contains(retry!) else { throw GatewayError(code: .invalidOutput) }
        let status = try? asInt(object["http_status"])
        let providerCode = object["provider_code"] as? String
        let reason = (object["validation_reason"] as? String).flatMap(GatewayError.ValidationFailure.init(rawValue:))
        return GatewayError(
            code: code, retryAfterMS: retry, httpStatus: status,
            providerCode: providerCode, validationFailure: reason
        )
    }

    func diagnostics() -> (slots: Int, waiting: Int) {
        if case .ready(let instance) = state { return (instance.physicalSlotsInUse, admissionWaiters.count) }
        return (0, admissionWaiters.count)
    }

    // MARK: Watchdog

    private func startWatchdog(instance: WorkerInstance, requestID: String) {
        watchdogTasks[requestID] = Task { [instanceID = instance.id, timeouts] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.watchdog * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.watchdogExpired(instanceID: instanceID, requestID: requestID)
        }
    }

    private func watchdogExpired(instanceID: UUID, requestID: String) async {
        guard case .ready(let instance) = state, instance.id == instanceID,
              instance.entry(for: requestID) != nil else { return }
        await poisonInstance(instanceID, error: GatewayError(code: .watchdogExpired, isLocal: true))
    }

    // MARK: Failure paths

    private func stdoutClosed(instanceID: UUID) async {
        await poisonInstance(instanceID, error: GatewayError(code: .workerDied, isLocal: true))
    }

    private func handleProcessExit(instanceID: UUID) async {
        guard case .ready(let instance) = state, instance.id == instanceID else { return }
        // Consume every stdout byte before treating process exit as EOF.
        if let reader = instance.outputTask { await reader.value }
    }

    private func poisonInstance(_ instanceID: UUID, error: GatewayError) async {
        guard case .ready(let instance) = state, instance.id == instanceID else { return }
        await stop(instance, error: error, graceful: false)
    }

    private func stop(_ instance: WorkerInstance, error: GatewayError, graceful: Bool) async {
        state = .stopping(instance)
        handshakeTimeoutTasks[instance.id]?.cancel()
        handshakeTimeoutTasks[instance.id] = nil
        handshakeFailure = (instance.id, error)
        for entry in instance.pendingEntries {
            watchdogTasks.removeValue(forKey: entry.requestID)?.cancel()
            entry.finish(terminal: .failure(error))
        }
        resumeHandshakeWaiters(instanceID: instance.id, error: error)
        let waiting = admissionWaiters
        admissionWaiters = []
        for waiter in waiting { waiter.entry.finish(terminal: .failure(error)) }
        if graceful { instance.sendShutdown() }
        let task = Task { await instance.terminateWithEscalation(graceful: graceful) }
        teardownTask = task
        await task.value
        state = .stopped
        teardownTask = nil
        resumeHandshakeWaiters(instanceID: nil, error: shuttingDown ? GatewayError(code: .shuttingDown, isLocal: true) : nil)
    }

}

/// Byte-to-line accumulator with the contract's 1 MiB frame bound; nil
/// means the stream violated the bound.
final class FrameAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Returns complete LF-terminated frames (without the LF), or nil on
    /// an oversized accumulation.
    func append(_ chunk: Data) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if line.count + 1 > WorkerContract.maxFrameBytes {
                return nil
            }
            frames.append(Data(line))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count >= WorkerContract.maxFrameBytes {
            return nil
        }
        return frames
    }
}

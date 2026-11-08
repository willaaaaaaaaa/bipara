import BiparaCore
@testable import BiparaWorker
import Foundation
import Testing

/// Real Swift-to-packaged-Python process integration for the worker
/// adapter: the fixture bundle (built by script/build_worker.sh) runs as
/// an actual child process over pipes for fixture-backed cases; controlled
/// Python doubles cover lifecycle paths the fixture cannot produce
/// (crash-after-ready, hung worker, bad handshake, fragmented writes).
@Suite("PythonModelGateway process integration", .serialized)
struct PythonModelGatewayTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var fixtureExecutable: URL {
        repoRoot.appendingPathComponent("build/worker-fixture/BiparaWorkerFixture.app/Contents/MacOS/BiparaWorkerFixture")
    }

    /// T01 from the canonical corpus, executed through the real adapter.
    static let t01Request = TranslateBatchRequest(
        sourceLanguage: .zh,
        targetLanguage: .en,
        contextBefore: "",
        contextAfter: "",
        units: [.init(unitID: UUID(), kind: .sentence, text: "李明没有确认周五的会议。")]
    )

    static let a01Request = AlignSelectionRequest(
        readingText: "I can can fruit.",
        counterpartText: "我会把水果装罐。",
        before: "I can ",
        selectedText: "can",
        after: " fruit."
    )

    static func configuration(provider: String = "openai") -> ModelConfiguration {
        ModelConfiguration(
            provider: provider,
            model: provider == "openai" ? "gpt-4.1-mini-2025-04-14" : "glm-4.7-flash",
            profile: provider == "openai" ? "openai-json-schema-v1" : "glm-json-v1",
            baseURL: provider == "openai" ? WorkerContract.openAIStandardBaseURL : WorkerContract.glmStandardBaseURL,
            effort: provider == "openai" ? .auto : .off,
            apiKey: "SYNTHETIC_TEST_CREDENTIAL"
        )
    }

    static func v2Configuration(provider: String = "openai", model: String? = nil, effort: ModelEffort = .auto,
                                 baseURL: String? = nil) -> ModelConfiguration {
        ModelConfiguration(
            provider: provider,
            model: model ?? (provider == "openai" ? "gpt-6-luna" : "glm-5.3-flash"),
            profile: provider == "openai" ? "openai-json-schema-v2" : "glm-json-v2",
            baseURL: baseURL ?? (provider == "openai" ? WorkerContract.openAIStandardBaseURL : WorkerContract.glmStandardBaseURL),
            effort: effort,
            apiKey: "SYNTHETIC_TEST_CREDENTIAL"
        )
    }

    /// Fixture-backed tests skip with an explicit reason until the bundle
    /// is built (same policy as the Python packaged suite).
    private func skipUnlessFixtureBuilt() -> Bool {
        FileManager.default.isExecutableFile(atPath: Self.fixtureExecutable.path)
    }

    @Test(arguments: ["translation.v1", "translation.v2"])
    func fixtureTranslateRoundTrip(promptVersion: String) async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        let unitID = Self.t01Request.units[0].unitID
        var request = Self.t01Request
        request.promptVersion = promptVersion
        let result = try await gateway.translateBatch(request, configuration: Self.configuration())
        #expect(result.translations.count == 1)
        #expect(result.translations[0].unitID == unitID)
        #expect(result.translations[0].text == "Li Ming has not confirmed Friday's meeting.")
        #expect(result.meta.provider == "openai")
        #expect(result.meta.requestedModel == "gpt-4.1-mini-2025-04-14")
        #expect(result.meta.promptVersion == promptVersion)
        #expect(result.meta.inputTokens == nil && result.meta.outputTokens == nil)
    }

    @Test func fixtureAlignRoundTrip() async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        let result = try await gateway.alignSelection(Self.a01Request, configuration: Self.configuration(provider: "glm"))
        guard case .matched(let matches) = result.match else {
            Issue.record("expected matched")
            return
        }
        #expect(matches.count == 1)
        #expect(matches[0].quote == "装罐")
        #expect(matches[0].occurrence == 1)
    }

    @Test func secondOperationReusesTheSameWorker() async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        _ = try await gateway.alignSelection(Self.a01Request, configuration: Self.configuration(provider: "glm"))
        // A third op still succeeds on the same long-lived instance.
        _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
    }

    @Test func swiftTaskCancelResumesCallerAndDrainsSlot() async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        // Fixture doubles answer unknown inputs instantly; to hold the
        // operation open this test uses the slowEcho double instead.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "slowEcho", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 20, shutdownTerm: 1, shutdownKill: 1)
        )
        defer { Task { await gateway.shutdown() } }

        let task = Task {
            try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        }
        try await WorkerDoubles.waitForRequests(1, directory: directory)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(started) < 1.4) // resumed without waiting for the op
        }
        // A replacement admitted after the drain terminal succeeds.
        let replacement = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        #expect(!replacement.translations.isEmpty)
    }

    @Test func operationBeyondPhysicalCapacityWaits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bipara-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = PythonModelGateway(executableURL: WorkerDoubles.write(mode: "slowEcho", directory: directory))
        let capacity = WorkerContract.maxInflightOperations
        let active = (0..<capacity).map { _ in
            Task { try await gateway.alignSelection(Self.a01Request, configuration: Self.configuration()) }
        }
        try await WorkerDoubles.waitForRequests(capacity, directory: directory)
        let waiting = Task { try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration()) }
        try await WorkerDoubles.waitUntil { await gateway.diagnostics().waiting == 1 }
        #expect(await gateway.diagnostics().slots == capacity)
        for task in active { _ = try await task.value }
        _ = try await waiting.value
        await gateway.shutdown()
    }

    @Test func workerCrashFailsPendingAndRelaunches() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Launch 1: dies right after ready. Launch 2+: normal echo.
        let double = WorkerDoubles.write(mode: "dieAfterReady", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 15, shutdownTerm: 1, shutdownKill: 1)
        )
        defer { Task { await gateway.shutdown() } }

        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected workerDied")
        } catch let error as GatewayError {
            #expect(error.code == .workerDied)
        }
        #expect(WorkerDoubles.launches(directory: directory) == 1)
        // The next explicit operation lazily launches a fresh instance.
        let after = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        #expect(!after.translations.isEmpty)
        #expect(WorkerDoubles.launches(directory: directory) == 2)
    }

    @Test func watchdogPoisonsUnresponsiveWorkerThenRelaunchServes() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "hang", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 0.8, shutdownTerm: 0.5, shutdownKill: 0.5)
        )
        defer { Task { await gateway.shutdown() } }

        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected watchdogExpired")
        } catch let error as GatewayError {
            #expect(error.code == .watchdogExpired)
        }
        // After poisoning, the same double still hangs on launch 2 —
        // a fresh gateway against the REAL fixture proves isolation.
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let fresh = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await fresh.shutdown() } }
        let result = try await fresh.translateBatch(Self.t01Request, configuration: Self.configuration())
        #expect(!result.translations.isEmpty)
    }

    @Test func incompatibleHandshakeFailsLocally() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "badHandshake", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 15, shutdownTerm: 1, shutdownKill: 1)
        )
        defer { Task { await gateway.shutdown() } }
        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected incompatibleWorker")
        } catch let error as GatewayError {
            #expect(error.code == .incompatibleWorker)
            #expect(error.isLocal)
        }
    }

    @Test func missingExecutableFailsWithoutSpawning() async throws {
        let gateway = PythonModelGateway(
            executableURL: URL(fileURLWithPath: "/nonexistent/BiparaWorker")
        )
        defer { Task { await gateway.shutdown() } }
        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected executableMissing")
        } catch let error as GatewayError {
            #expect(error.code == .executableMissing)
            #expect(error.isLocal)
        }
    }

    @Test func fragmentedResultWriteReassembles() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "fragmented", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 10, shutdownTerm: 1, shutdownKill: 1)
        )
        defer { Task { await gateway.shutdown() } }
        let result = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        #expect(result.translations.count == 1)
        #expect(result.translations[0].text.hasPrefix("你好，世界。"))
    }

    @Test func childEnvironmentIsSanitized() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "envEcho", directory: directory)
        // Pollute the parent environment view the sanitizer sees: the
        // builder reads ProcessInfo, so setenv first.
        setenv("PYTHONPATH", "/canary/pythonpath", 1)
        setenv("OPENAI_API_KEY", "SYNTHETIC_CANARY_KEY", 1)
        setenv("HTTP_PROXY", "http://canaryproxy.invalid", 1)
        defer {
            unsetenv("PYTHONPATH")
            unsetenv("OPENAI_API_KEY")
            unsetenv("HTTP_PROXY")
        }
        let gateway = PythonModelGateway(executableURL: double)
        defer { Task { await gateway.shutdown() } }
        let result = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        #expect(result.translations[0].text.hasPrefix("ENVKEYS:"))
        let keys = result.translations[0].text
            .dropFirst("ENVKEYS:".count).split(separator: ",").map(String.init)
        #expect(!keys.contains("PYTHONPATH"))
        #expect(!keys.contains("OPENAI_API_KEY"))
        #expect(!keys.contains("HTTP_PROXY"))
        #expect(!keys.contains("HOME")) // inherited Python path/home cleared
    }

    @Test func shutdownEscalationReapsIgnoringWorker() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // neverExit ignores stdin EOF AND SIGTERM: only the SIGKILL rung of
        // the documented escalation reaps it.
        let double = WorkerDoubles.write(mode: "neverExit", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 30, shutdownTerm: 0.5, shutdownKill: 0.5)
        )
        // Launch the instance and free the caller without touching the
        // child: cancel the Swift task (cancel frame ignored by the double;
        // the caller resumes while the entry drains on the live worker).
        let op = Task {
            try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        }
        try await WorkerDoubles.waitForRequests(1,directory:directory)
        #expect(WorkerDoubles.launches(directory: directory) == 1)

        let started = Date()
        await gateway.shutdown() // shutdown ignored -> TERM ignored -> KILL
        do { _ = try await op.value; Issue.record("expected shutdown failure") }
        catch let error as GatewayError { #expect(error.code == .shuttingDown) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 4.0) // 0.5 term grace + 0.5 kill grace + slack
        #expect(WorkerDoubles.launches(directory: directory) == 1) // no extra launches
        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected shuttingDown")
        } catch let error as GatewayError {
            #expect(error.code == .shuttingDown)
        }
    }

    @Test func afterShutdownNewOperationsAreRejected() async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
        await gateway.shutdown()
        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.configuration())
            Issue.record("expected shuttingDown")
        } catch let error as GatewayError {
            #expect(error.code == .shuttingDown)
        }
    }

    // MARK: - Protocol v2 (IPC-06)

    @Test func protocolOneWorkerIsRejectedBeforeCredentials() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bipara-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let double = WorkerDoubles.write(mode: "protocolOne", directory: directory)
        let gateway = PythonModelGateway(
            executableURL: double,
            timeouts: GatewayTimeouts(startup: 5, watchdog: 10, shutdownTerm: 1, shutdownKill: 1)
        )
        defer { Task { await gateway.shutdown() } }
        do {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: Self.v2Configuration())
            Issue.record("expected incompatibleWorker")
        } catch let error as GatewayError {
            #expect(error.code == .incompatibleWorker)
            #expect(error.isLocal)
        }
        // No request frame — and therefore no credential — reached the
        // protocol-1 worker.
        try await Task.sleep(for: .milliseconds(200))
        #expect(WorkerDoubles.requestsReceived(directory: directory) == 0)
    }

    @Test func v2ConfigCarriesBaseURLAndEffortAndEchoesRequestedEffort() async throws {
        guard skipUnlessFixtureBuilt() else {
            Issue.record("fixture bundle not built; run script/build_worker.sh")
            return
        }
        let gateway = PythonModelGateway(executableURL: Self.fixtureExecutable)
        defer { Task { await gateway.shutdown() } }
        let result = try await gateway.translateBatch(
            Self.t01Request,
            configuration: Self.v2Configuration(provider: "glm", model: "glm-5.3-flash", effort: .low,
                                                 baseURL: WorkerContract.glmCodingPlanBaseURL))
        #expect(result.meta.requestedEffort == .low)
        #expect(result.meta.provider == "glm")
        #expect(result.meta.requestedModel == "glm-5.3-flash")
    }

    @Test func invalidConfigRejectedLocallyWithoutWorker() async throws {
        let gateway = PythonModelGateway(
            executableURL: URL(fileURLWithPath: "/nonexistent/BiparaWorker")
        )
        defer { Task { await gateway.shutdown() } }
        // Legacy profile with a non-standard URL or wrong effort.
        let legacy = ModelConfiguration(
            provider: "openai", model: "gpt-4.1-mini-2025-04-14", profile: "openai-json-schema-v1",
            baseURL: WorkerContract.glmStandardBaseURL, effort: .auto, apiKey: "K")
        await #expect(throws: GatewayError.self) {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: legacy)
        }
        // Non-HTTPS base URL on a v2 profile.
        let insecure = ModelConfiguration(
            provider: "openai", model: "gpt-6-luna", profile: "openai-json-schema-v2",
            baseURL: "http://api.openai.com/v1/", effort: .low, apiKey: "K")
        await #expect(throws: GatewayError.self) {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: insecure)
        }
        // Unknown provider profile combination.
        let mismatched = ModelConfiguration(
            provider: "glm", model: "glm-5.3", profile: "openai-json-schema-v2",
            baseURL: WorkerContract.glmStandardBaseURL, effort: .low, apiKey: "K")
        await #expect(throws: GatewayError.self) {
            _ = try await gateway.translateBatch(Self.t01Request, configuration: mismatched)
        }
    }

    @Test func effortEchoMismatchFailsValidation() throws {
        // A terminal result whose requested_effort differs from the
        // dispatched configuration is rejected by the meta guard.
        let data = ["translations": []]
        let payload = PythonModelGateway.WirePayload(
            data: data,
            meta: [
                "provider": "openai", "requested_model": "gpt-6-luna", "requested_effort": "low",
                "returned_model": NSNull(), "prompt_version": "translation.v1",
                "input_tokens": NSNull(), "output_tokens": NSNull(),
            ])
        #expect(throws: GatewayError.self) {
            _ = try PythonModelGateway.mapTranslate(
                payload, requestedUnits: [],
                configuration: Self.v2Configuration(effort: .auto), promptVersion: "translation.v1")
        }
    }
}

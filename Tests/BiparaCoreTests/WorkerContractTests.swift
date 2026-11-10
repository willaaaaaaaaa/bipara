import Testing
@testable import BiparaCore

/// Verifies the Swift contract constants against the reviewed design values.
/// The Python suite exercises the same values over the real pipe protocol.
@Suite("Worker contract constants")
struct WorkerContractTests {
    @Test func protocolBasics() {
        #expect(WorkerContract.protocolVersion == 2)
        #expect(WorkerContract.workerVersion == "0.1.0")
        #expect(WorkerContract.maxInflightOperations == 4)
        #expect(WorkerContract.translationBatchesPerSession == 2)
        #expect(WorkerContract.promptVersions == ["translation.v1", "translation.v2", "alignment.v1"])
        #expect(WorkerContract.maxFrameBytes == 1_048_576)
    }

    @Test func deadlinesAreOrdered() {
        // The transport watchdog must be strictly later than the provider
        // deadline so a normal timeout frame is not misread as a hung worker.
        #expect(WorkerContract.invocationTimeoutSeconds < WorkerContract.transportWatchdogSeconds)
        #expect(WorkerContract.transportWatchdogSeconds - WorkerContract.invocationTimeoutSeconds == 10)
    }

    @Test func planningBounds() {
        #expect(WorkerContract.maxUnitsPerBatch == 64)
        #expect(WorkerContract.maxBatchTextBytes == 8192)
        #expect(WorkerContract.maxContextBytes == 512)
        #expect(WorkerContract.maxInputJSONBytes == 32_768)
        #expect(WorkerContract.maxSourceUTF8Bytes == 1_048_576)
        #expect(WorkerContract.documentFileByteLimit == 20_971_520)
        #expect(WorkerContract.maxSentenceUTF8Bytes == 1024)
    }

    @Test func modelOutputBounds() {
        #expect(WorkerContract.maxTranslationBytes == 8192)
        #expect(WorkerContract.maxDecodedContentBytes == 131_072)
        #expect(WorkerContract.maxAlignSelectionBytes == 512)
        #expect(WorkerContract.maxAlignTextBytes == 8192)
        #expect(WorkerContract.maxMatches == 8)
    }

    @Test func providerProfiles() {
        #expect(WorkerContract.providers == ["openai", "kimi", "glm", "deepseek", "anthropic"])
        #expect(WorkerContract.profilesByProvider["openai"] == ["openai-json-schema-v1", "openai-json-schema-v2", "openai-responses-v3"])
        #expect(WorkerContract.profilesByProvider["anthropic"] == ["anthropic-messages-v3"])
        #expect(WorkerContract.profilesByProvider["glm"] == ["glm-json-v1", "glm-json-v2"])
        #expect(WorkerContract.legacyProfiles["openai"] == "openai-json-schema-v1")
        #expect(WorkerContract.currentProfiles["glm"] == "glm-json-v2")
        #expect(WorkerContract.legacyEffort(profile: "openai-json-schema-v1") == .auto)
        #expect(WorkerContract.legacyEffort(profile: "glm-json-v1") == .off)
        #expect(WorkerContract.legacyEffort(profile: "glm-json-v2") == nil)
        #expect(WorkerContract.defaultModels["openai"] == "gpt-4.1-mini-2025-04-14")
        #expect(WorkerContract.defaultModels["glm"] == "glm-4.7-flash")
        #expect(WorkerContract.openAIStandardBaseURL == "https://api.openai.com/v1/")
        #expect(WorkerContract.glmStandardBaseURL == "https://open.bigmodel.cn/api/paas/v4/")
        #expect(WorkerContract.glmCodingPlanBaseURL == "https://open.bigmodel.cn/api/coding/paas/v4/")
        #expect(WorkerContract.legacyStandardBaseURL(provider: "openai") == WorkerContract.openAIStandardBaseURL)
    }
}

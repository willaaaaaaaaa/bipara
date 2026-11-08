@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@Suite("Document file service")
struct DocumentFileServiceTests {
    private func makeDocument(source: String = "The window is open.\nIt rained today.") throws -> BiparaDocument {
        let plan = try SourcePlanner.plan(source)
        return BiparaDocument(
            documentID: UUID(), title: DocumentTitle.derive(from: source), source: source,
            sourceRevision: 1, requestedDirection: .enToZh, resolvedDirection: .enToZh,
            paragraphs: plan.paragraphs, units: plan.units, translations: [],
            jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil
        )
    }

    @Test func saveOpenRoundTripOffline() async throws {
        let service = DocumentFileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bipara-\(UUID().uuidString).bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        var document = try makeDocument()
        document.jobSnapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "gpt-4.1-mini-2025-04-14", profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1"
        )
        document.translations = document.units.map {
            UnitTranslation(unitID: $0.id, text: "译\($0.sourceRange.location)", completedAt: Date(timeIntervalSince1970: 0))
        }
        try await service.save(document, to: url, ownerSessionID: UUID())
        let opened = try await service.open(url)
        #expect(opened.documentID == document.documentID)
        #expect(TextIdentity.equal(opened.source, document.source))
        #expect(opened.translations.count == document.translations.count)
        // Save/Open work without any worker, credential, or network.
    }

    @Test func destinationOwnershipIsEnforced() async throws {
        let service = DocumentFileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bipara-\(UUID().uuidString).bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = UUID()
        let document = try makeDocument()
        try await service.save(document, to: url, ownerSessionID: first)
        await #expect(throws: DocumentFileService.FileError.destinationOwnedByAnotherTab) {
            try await service.save(document, to: url, ownerSessionID: UUID())
        }
        // The owner may save again; release frees the destination.
        try await service.save(document, to: url, ownerSessionID: first)
        await service.releaseDestination(url, ownerSessionID: first)
        try await service.save(document, to: url, ownerSessionID: UUID())
    }

    @Test func concurrentSavesSerializeAndNewerSnapshotWins() async throws {
        let barrier = TestBarrier()
        let writes = WriteCounter()
        let service = DocumentFileService { data, url in
            let n = await writes.next()
            try await barrier.arrive(n)
            try await DocumentFileService.atomicWrite(data, to: url)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bipara-\(UUID()).bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        var older = try makeDocument(); older.title = "older"
        let old = older
        let first = Task { try await service.save(old,to:url,ownerSessionID:session) }
        await barrier.started(1)
        var newer = old; newer.title = "newer"
        let next = newer
        let second = Task { try await service.save(next,to:url,ownerSessionID:session) }
        try await appWaitUntil { await service.queuedSaves(to:url) == 1 }
        #expect(await writes.count == 1)
        await barrier.release(1); await barrier.started(2)
        await barrier.release(2); try await first.value; try await second.value
        #expect(try await service.open(url).title == "newer")
    }

    @Test func oversizedFileRejectedBeforeRead() async throws {
        let service = DocumentFileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bipara-\(UUID().uuidString).bipara")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: WorkerContract.documentFileByteLimit + 1).write(to: url)
        await #expect(throws: DocumentFileService.FileError.self) {
            _ = try await service.open(url)
        }
    }

    @Test func importTextHandlesBOMAndRejectsNonUTF8() throws {
        let service = DocumentFileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bipara-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("你好 bipara".utf8))
        try bom.write(to: url)
        let imported = try service.importText(url)
        #expect(imported == "你好 bipara")

        let binary = FileManager.default.temporaryDirectory
            .appendingPathComponent("bipara-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: binary) }
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: binary)
        #expect(throws: DocumentFileService.FileError.self) { _ = try service.importText(binary) }
    }

    @Test func bilingualExportMarksUntranslatedParagraphs() throws {
        let service = DocumentFileService()
        var document = try makeDocument(source: "One full sentence.\n\nTwo full sentence.")
        let units = document.units
        document.translations = [
            UnitTranslation(unitID: units[0].id, text: "第一句。", completedAt: Date(timeIntervalSince1970: 0)),
        ]
        document.jobSnapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "m", profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1"
        )
        let export = try service.exportBilingual(document)
        #expect(export.contains("第一句。"))
        #expect(export.contains("[untranslated]"))
        #expect(export.contains("Two full sentence."))
    }
}

import BiparaCore
import Foundation

/// Explicit local `.bipara` save/open with atomic writes, serialized
/// per-destination operations, and destination-ownership checks. Draft
/// application is the caller's (WorkspaceStore) job under the same rules
/// as Apply; this service never mutates document content.
public actor DocumentFileService {
    public enum FileError: Error, Equatable {
        case oversized(actualBytes: Int)
        case writeFailed(String)
        case destinationOwnedByAnotherTab
        case readFailed(String)
        case incompleteTranslation
        case noCompletedParagraphs
    }

    private var activeSavesByDestination: [URL: UUID] = [:]
    private var saveOwners: [URL: UUID] = [:] // tab session identity

    private let write: @Sendable (Data, URL) async throws -> Void

    public init(write: @escaping @Sendable (Data, URL) async throws -> Void = DocumentFileService.atomicWrite) {
        self.write = write
    }

    public static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    public func reserveDestination(_ url: URL, ownerSessionID: UUID) throws {
        let url = Self.canonicalURL(url)
        let identity = Self.fileIdentity(url)
        for (owned, owner) in saveOwners where owner != ownerSessionID {
            if owned == url || (identity != nil && identity == Self.fileIdentity(owned)) {
                throw FileError.destinationOwnedByAnotherTab
            }
        }
        saveOwners[url] = ownerSessionID
    }

    private static func fileIdentity(_ url: URL) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }

    public nonisolated static func atomicWrite(_ data: Data, to url: URL) async throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).bipara.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    // MARK: Save

    /// Serializes the save for its destination: a queued save captures its
    /// snapshot when it begins, so an older write can never finish after a
    /// newer one. The write is a sibling temporary file followed by an
    /// atomic replace.
    public func save(
        _ document: BiparaDocument,
        to url: URL,
        ownerSessionID: UUID
    ) async throws {
        let url = Self.canonicalURL(url)
        try reserveDestination(url, ownerSessionID: ownerSessionID)
        if activeSavesByDestination[url] != nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waitersByDestination[url, default: []].append(continuation)
            }
        } else { activeSavesByDestination[url] = UUID() }
        defer { resumeNextWaiter(url: url) }
        try Task.checkCancellation()

        let data: Data
        do {
            data = try DocumentCodec.encode(document)
        } catch {
            throw FileError.writeFailed("encoding failed")
        }
        guard data.count <= WorkerContract.documentFileByteLimit else { throw FileError.oversized(actualBytes:data.count) }
        do { try await write(data, url) }
        catch { throw FileError.writeFailed("write failed") }
    }

    private var waitersByDestination: [URL: [CheckedContinuation<Void, Error>]] = [:]

    private func resumeNextWaiter(url: URL) {
        if var waiters = waitersByDestination[url], !waiters.isEmpty {
            let next = waiters.removeFirst()
            waitersByDestination[url] = waiters
            next.resume()
        } else { activeSavesByDestination[url] = nil }
    }

    public func releaseDestination(_ url: URL, ownerSessionID: UUID) {
        let url = Self.canonicalURL(url)
        if saveOwners[url] == ownerSessionID {
            saveOwners[url] = nil
        }
    }

    func queuedSaves(to url: URL) -> Int { waitersByDestination[Self.canonicalURL(url)]?.count ?? 0 }

    // MARK: Open

    public func open(_ url: URL) async throws -> BiparaDocument {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > WorkerContract.documentFileByteLimit {
                throw FileError.oversized(actualBytes: size)
            }
            data = try Data(contentsOf: url)
        } catch let error as FileError {
            throw error
        } catch {
            throw FileError.readFailed("invalid or unreadable document")
        }
        do {
            return try DocumentCodec.decode(data)
        } catch is CoreError {
            throw FileError.readFailed("invalid or unreadable document")
        }
    }

    /// Plain-text import: local UTF-8 `.txt` with optional BOM; a wrong
    /// encoding is an error, never a silent replacement.
    public nonisolated func importText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readLimit = WorkerContract.maxSourceUTF8Bytes + 4 // BOM plus one overflow byte.
        var data = Data()
        while data.count < readLimit {
            let chunk = try handle.read(upToCount: readLimit - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var bytes = data
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes = bytes.dropFirst(3)
        }
        guard bytes.count <= WorkerContract.maxSourceUTF8Bytes else {
            throw CoreError.inputTooLarge(actualBytes: bytes.count, maxBytes: WorkerContract.maxSourceUTF8Bytes)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw FileError.readFailed("not UTF-8 text")
        }
        return text
    }

    /// Bilingual export: every paragraph; missing translations are marked
    /// as untranslated.
    public nonisolated func exportBilingual(_ document: BiparaDocument) throws -> String {
        let plan = SourcePlan(source: document.source, paragraphs: document.paragraphs, units: document.units)
        let translated = Dictionary(uniqueKeysWithValues: document.translations.map { ($0.unitID, $0.text) })
        return document.paragraphs.map { paragraph in
            let original = document.source.substring(utf16: paragraph.sourceRange) ?? ""
            let target = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translated,
                                                    targetLanguage: document.jobSnapshot?.targetLanguage ?? .zh)?.text ?? "[untranslated]"
            return original + "\n" + target
        }.joined(separator: "\n\n")
    }
    public nonisolated func exportTranslation(_ document:BiparaDocument,allowPartial:Bool = false) throws -> String {
        let plan=SourcePlan(source:document.source,paragraphs:document.paragraphs,units:document.units)
        let translations=Dictionary(uniqueKeysWithValues:document.translations.map{($0.unitID,$0.text)})
        let language=document.jobSnapshot?.targetLanguage ?? .zh
        if let full=ParagraphAssembler.assembleDocument(plan,translations:translations,targetLanguage:language) { return full }
        guard allowPartial else { throw FileError.incompleteTranslation }
        let completed=document.paragraphs.compactMap{paragraph -> String? in
            guard !paragraph.unitIDs.isEmpty,let assembly=ParagraphAssembler.assemble(plan,paragraph:paragraph,translations:translations,targetLanguage:language) else { return nil }
            return assembly.text + (document.source.substring(utf16:paragraph.separatorRange) ?? "")
        }
        guard !completed.isEmpty else { throw FileError.noCompletedParagraphs }
        return completed.joined()
    }
}

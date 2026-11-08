import BiparaCore
import Foundation

/// Session-local analysis results; neither credentials nor transient errors are cached.
struct SelectionCache {
    struct Key: Hashable {
        let sourceRevision: Int
        let unit: UUID
        let source: Data
        let target: Data
        let targetCompletedAt: Date
        let side: String
        let location: Int
        let length: Int
        let provider: String
        let model: String
        let profile: String
        let effort: String
        let bindingID: UUID
        let promptVersion: String
    }
    private var values: [Key: [BiparaCore.TextRange]] = [:]
    private var recent: [Key] = []
    var count: Int { values.count }

    mutating func value(for key: Key) -> [BiparaCore.TextRange]? {
        guard let result = values[key] else { return nil }
        touch(key)
        return result
    }
    mutating func insert(_ result: [BiparaCore.TextRange], for key: Key) {
        values[key] = result
        touch(key)
        if recent.count > 128 { values[recent.removeFirst()] = nil }
    }
    private mutating func touch(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }
}

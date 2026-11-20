import Foundation
import XCTest
@testable import BiparaAppKit

final class InstallVersionTests: XCTestCase {
    private func version(_ marketing: String, _ build: String, commits: [String]? = nil,
                         modified: Bool = false) throws -> AppInstaller.Version {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "dev.bipara.Bipara", "CFBundleShortVersionString": marketing,
                    "CFBundleVersion": build]
        try PropertyListEncoder().encode(info).write(to: url.appendingPathComponent("Contents/Info.plist"))
        if let commits {
            try JSONSerialization.data(withJSONObject: ["commits": commits, "modified": modified])
                .write(to: resources.appendingPathComponent("BuildSource.json"))
        }
        return try AppInstaller.Version(app: url)
    }

    func testNumericVersionsAndLegacyMigration() throws {
        let old = try version("0.1.3", "4")
        let new = try version("0.1.3", "10", commits: ["new"])
        try new.checkUpgrade(from: old, localRebuild: false)
        XCTAssertThrowsError(try old.checkUpgrade(from: new, localRebuild: true))
        let next = try version("0.1.10", "1")
        try next.checkUpgrade(from: new, localRebuild: false)
        XCTAssertThrowsError(try old.checkUpgrade(from: old, localRebuild: false))
    }

    func testEqualNumbersRequireAncestryAndPreserveLocalEdits() throws {
        let base = try version("0.1.3", "5", commits: ["base"])
        let local = try version("0.1.3", "5", commits: ["base"], modified: true)
        let next = try version("0.1.3", "5", commits: ["next", "base"])
        let branch = try version("0.1.3", "5", commits: ["other", "base"])
        try next.checkUpgrade(from: local, localRebuild: false)
        XCTAssertThrowsError(try base.checkUpgrade(from: next, localRebuild: false))
        XCTAssertThrowsError(try branch.checkUpgrade(from: next, localRebuild: true))
        XCTAssertThrowsError(try base.checkUpgrade(from: local, localRebuild: false))
        XCTAssertThrowsError(try local.checkUpgrade(from: local, localRebuild: false))
        try local.checkUpgrade(from: local, localRebuild: true)
    }
}

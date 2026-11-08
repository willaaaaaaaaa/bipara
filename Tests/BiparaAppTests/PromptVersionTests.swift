import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor
@Suite("Translation prompt snapshots")
struct PromptVersionTests {
    @Test(arguments: ["translation.v1", "translation.v2"])
    func resumeDispatchesTheRecordedVersionWithoutResendingCompletedUnits(version: String) async throws {
        let workspace = WorkspaceStore()
        let index = try workspace.newTab(source: String(repeating: "The window is open. ", count: 80))
        var snapshot = DispatchFixtures.snapshot()
        snapshot.translationPromptVersion = version
        let completed = try #require(workspace.tabs[index].document.units.first)
        workspace.withTab(index) { tab in
            tab.document.jobSnapshot = snapshot
            tab.document.resolvedDirection = .enToZh
            tab.document.translations = [.init(unitID: completed.id, text: "已有译文。", completedAt: Date())]
            tab.job.snapshot = snapshot
            tab.job.state = .paused
        }
        let gateway = ScriptedGateway()
        let coordinator = TranslationCoordinator(gateway: gateway)
        try await coordinator.translate(tabIndex: index, workspace: workspace, snapshot: snapshot,
            binding: DispatchFixtures.binding(), credential: DispatchFixtures.credential())
        #expect(workspace.tabs[index].job.state == .completed)
        #expect(workspace.tabs[index].document.jobSnapshot?.translationPromptVersion == version)
        #expect(gateway.requests.count > 1)
        #expect(gateway.requests.allSatisfy { $0.promptVersion == version })
        #expect(!gateway.requests.flatMap(\.units).contains { $0.unitID == completed.id })
        #expect(workspace.tabs[index].document.translations.first?.text == "已有译文。")
        #expect(workspace.tabs[index].document.translations.count == workspace.tabs[index].document.units.count)
    }
}

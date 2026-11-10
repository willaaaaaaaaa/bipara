import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing
import SwiftUI

actor TestBarrier {
    var count=0
    private var arrival:[(Int,CheckedContinuation<Void,Never>)]=[]
    private var replies:[Int:CheckedContinuation<Void,Error>]=[:]
    private var cancelled:[Int]=[]

    /// Parks the caller's ordinal until `release`. Cancellation-safe: a
    /// cancelled or already-released ordinal resumes immediately instead of
    /// parking forever, so a cancelled task can never deadlock the barrier.
    func arrive(_ n:Int)async throws{
        count=max(count,n)
        for (expected,c) in arrival where expected<=count{c.resume()}
        arrival.removeAll{$0.0<=count}
        guard !cancelled.contains(n) else { throw CancellationError() }
        try await withTaskCancellationHandler{
            try await withCheckedThrowingContinuation{(cont:CheckedContinuation<Void,Error>) in
                if cancelled.contains(n){cont.resume(throwing:CancellationError())}
                else{replies[n]=cont}
            }
        } onCancel:{
            Task{await self.cancelArrive(n)}
        }
    }
    private func cancelArrive(_ n:Int){
        cancelled.append(n)
        replies.removeValue(forKey:n)?.resume(throwing:CancellationError())
    }
    func started(_ n:Int)async{if count>=n{return};await withCheckedContinuation{arrival.append((n,$0))}}
    /// Releasing an ordinal that has not parked yet cancels its future
    /// arrival, so release order can never lose a wakeup.
    func release(_ n:Int){
        guard let c=replies.removeValue(forKey:n) else{cancelled.append(n);return}
        c.resume()
    }
}
actor WriteCounter {var count=0;func next()->Int{count+=1;return count}}
@MainActor func appWaitUntil(_ test:@MainActor ()async->Bool)async throws{
    let deadline=ContinuousClock.now.advanced(by:.seconds(8))
    while await !test(){if ContinuousClock.now>=deadline{throw NSError(domain:"app barrier timeout",code:1)};try await Task.sleep(for:.milliseconds(5))}
}

@MainActor final class FaultCredentials:CredentialStore {
    var keys:[UUID:String]=[:]
    var legacy=["openai":"OLD_OPENAI","glm":"OLD_GLM"]
    var writes=0
    var failAt:Int?
    var failLegacyReadProvider:String?
    var failLegacyDeleteProvider:String?
    func hasKey(configurationID:UUID)->Bool{keys[configurationID] != nil}
    func credential(configurationID:UUID)throws->String?{keys[configurationID]}
    func setKey(_ key:String,configurationID:UUID)throws{writes+=1;if writes==failAt{throw NSError(domain:"synthetic key failure",code:1)};keys[configurationID]=key}
    func deleteKey(configurationID:UUID)throws{writes+=1;if writes==failAt{throw NSError(domain:"synthetic key failure",code:1)};keys[configurationID]=nil}
    func legacyCredential(provider:String)throws->String?{
        if provider == failLegacyReadProvider {throw NSError(domain:"synthetic legacy read failure",code:2)}
        return legacy[provider]
    }
    func deleteLegacyKey(provider:String)throws{
        if provider == failLegacyDeleteProvider {throw NSError(domain:"synthetic legacy cleanup failure",code:3)}
        legacy[provider]=nil
    }
    /// Test convenience: key the runtime's current default configuration.
    func prepareDefault(_ settings:SettingsStore,key:String="SYNTHETIC_TEST_CREDENTIAL",origin:String="https://api.openai.com",defaults:UserDefaults? = nil){
        if let id=settings.record.defaultConfiguration?.id{keys[id]=key}
        if let defaults{defaults.set(true,forKey:"dev.bipara.disclosure.openai|\(origin)")}
    }
}

@MainActor @Suite("Native state repair regressions")
struct RepairTests {
    private func defaults()->UserDefaults{UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!}
    @Test func keyOnlyDraftCanSaveCancelAndCompensate()throws{
        let keys=FaultCredentials(),settings=SettingsStore(defaults:defaults(),keychain:FaultCredentials())
        let openai=try #require(settings.record.modelConfigurations.first{ $0.provider == "openai" })
        let glm=try #require(settings.record.modelConfigurations.first{ $0.vendorLabel == "GLM" })
        keys.keys[openai.id]="OLD_OPENAI";keys.keys[glm.id]="OLD_GLM"
        settings.setKeyDraft(.set("NEW_KEY"),configurationID:openai.id);#expect(settings.hasDraftChanges)
        settings.cancelDraft();#expect(!settings.hasDraftChanges);#expect(settings.keyDrafts.isEmpty)
        let transaction=SettingsStore(defaults:defaults(),keychain:keys,record:settings.record)
        transaction.setKeyDraft(.set("NEW_OPENAI"),configurationID:openai.id);transaction.setKeyDraft(.set("NEW_GLM"),configurationID:glm.id)
        transaction.updateDraft{$0.appearance = .dark};keys.failAt=2
        #expect(throws:SettingsStore.SettingsError.self){try transaction.saveDraft()}
        #expect(keys.keys[openai.id]=="OLD_OPENAI");#expect(keys.keys[glm.id]=="OLD_GLM")
        #expect(transaction.record.appearance == .system);#expect(transaction.hasDraftChanges)
        keys.failAt=nil;try transaction.saveDraft()
        #expect(keys.keys[openai.id]=="NEW_OPENAI");#expect(transaction.record.appearance == .dark)
    }
    @Test func closingEarlierTabKeepsOtherJobOwner()async throws{
        let w=WorkspaceStore();try w.newTab(source:"First.");try w.newTab(source:"The window is open.")
        let g=ScriptedGateway(),barrier=TestBarrier();g.barrier=barrier
        let c=TranslationCoordinator(gateway:g)
        let task=Task{try await c.translate(tabIndex:1,workspace:w,snapshot:DispatchFixtures.snapshot(),binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())}
        await barrier.started(1);let owner=w.tabs[1].sessionID;w.closeTab(at:0);await barrier.release(1);try await task.value
        #expect(w.tabs[0].sessionID==owner);#expect(w.tabs[0].job.state == .completed);#expect(!w.tabs[0].document.translations.isEmpty)
    }
    @Test func resumeKeepsSnapshotAndNeverResendsCompletedUnits()async throws{
        let w=WorkspaceStore();try w.newTab(source:String(repeating:"Hello there. ",count:100),direction:.enToZh)
        let g=ScriptedGateway();g.failAtDispatch=2;let c=TranslationCoordinator(gateway:g)
        let original=DispatchFixtures.snapshot(model:"original")
        do{try await c.translate(tabIndex:0,workspace:w,snapshot:original,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential());Issue.record("expected partial failure")}
        catch let e as GatewayError{#expect(e.code == .network)}
        let completed=Set(w.tabs[0].document.translations.map(\.unitID));#expect(!completed.isEmpty)
        try c.resume(tabIndex:0,workspace:w)
        // Resume reuses the frozen snapshot; a rotated key at the same URL
        // applies to later dispatches without changing model/effort.
        try await c.translate(tabIndex:0,workspace:w,snapshot:original,binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential("ROTATED_SYNTHETIC"))
        #expect(g.requests.dropFirst(2).flatMap(\.units).allSatisfy{!completed.contains($0.unitID)})
        #expect(g.configurations.allSatisfy{$0.provider=="openai" && $0.model=="original"})
        #expect(g.configurations.dropFirst(2).allSatisfy{$0.apiKey=="ROTATED_SYNTHETIC"})
        #expect(w.tabs[0].job.state == .completed)
    }
    @Test func aliasesCannotOverwriteOtherTabs()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-alias-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent("real"),alias=root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:directory)
        let w=WorkspaceStore();try w.newTab(source:"Original.")
        let service=DocumentFileService(),url=directory.appendingPathComponent("test.bipara"),owner=UUID()
        try await service.save(w.tabs[0].document,to:url,ownerSessionID:owner)
        await #expect(throws:DocumentFileService.FileError.destinationOwnedByAnotherTab){try await service.save(w.tabs[0].document,to:alias.appendingPathComponent("test.bipara"),ownerSessionID:UUID())}
        let hard=root.appendingPathComponent("hard.bipara");try FileManager.default.linkItem(at:url,to:hard)
        await #expect(throws:DocumentFileService.FileError.destinationOwnedByAnotherTab){try await service.save(w.tabs[0].document,to:hard,ownerSessionID:UUID())}
    }
    @Test func saveCapturesGenerationAndLeavesLaterResultDirty()async throws{
        let barrier=TestBarrier()
        let service=DocumentFileService{data,url in try await barrier.arrive(1);try await DocumentFileService.atomicWrite(data,to:url)}
        let keys=FaultCredentials(),defaults=UserDefaults(suiteName:"dev.bipara.test.\(UUID())")!
        let runtime=AppRuntime(gateway:ScriptedGateway(),keychain:keys,defaults:defaults,files:service)
        keys.prepareDefault(runtime.settings,defaults:defaults)
        runtime.newTab();let session=runtime.workspace.activeTab!.sessionID
        runtime.workspace.withTab(0){$0.draftText="The window is open."}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-save-\(UUID()).bipara")
        defer{try? FileManager.default.removeItem(at:url)}
        let save=Task{await runtime.save(session,to:url)}
        await barrier.started(1)
        try await runtime.coordinator.translate(tabIndex:0,workspace:runtime.workspace,snapshot:DispatchFixtures.snapshot(),binding:DispatchFixtures.binding(),credential:DispatchFixtures.credential())
        await barrier.release(1);#expect(await save.value)
        #expect(runtime.workspace.tabs[0].isDirty)
        #expect(try await service.open(url).translations.isEmpty)
        #expect(!runtime.workspace.tabs[0].document.translations.isEmpty)
    }
    @Test func localizationAndNativeIMEBridge()throws{
        #expect(AppLocalization.text("Save",language:.simplifiedChinese)=="保存")
        #expect(AppLocalization.text("Save",language:.english)=="Save")
        var content="",composing=false
        let representable=SourceEditorView(text:Binding(get:{content},set:{content=$0}),isComposing:Binding(get:{composing},set:{composing=$0}))
        let coordinator=representable.makeCoordinator()
        let view=NSTextView(usingTextLayoutManager:true);view.delegate=coordinator
        view.setMarkedText("拼",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:view))
        #expect(composing);#expect(content=="拼")
        view.unmarkText();coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:view))
        #expect(!composing)
    }
}

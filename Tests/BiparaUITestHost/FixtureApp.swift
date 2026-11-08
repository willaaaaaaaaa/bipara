import AppKit
import BiparaAppKit
import BiparaCore
import SwiftUI
import QuartzCore

/// Separate native fixture product; this file is never a source of the release app.
@MainActor
final class FixtureKeys: CredentialStore {
    var keys: [UUID:String] = [:]
    func hasKey(configurationID:UUID)->Bool{keys[configurationID] != nil}
    func credential(configurationID:UUID)throws->String?{keys[configurationID]}
    func setKey(_ key:String,configurationID:UUID)throws{keys[configurationID]=key}
    func deleteKey(configurationID:UUID)throws{keys[configurationID]=nil}
    func legacyCredential(provider:String)throws->String?{nil}
    func deleteLegacyKey(provider:String)throws{}
}
actor FixtureGateway:ModelGateway {
    let translationDelay:Duration
    private var translationFailures: [GatewayError]
    init(translationDelay: Duration = .milliseconds(80), translationFailures: [GatewayError] = []) {
        self.translationDelay = translationDelay
        self.translationFailures = translationFailures
    }
    func translateBatch(_ request:TranslateBatchRequest,configuration:ModelConfiguration)async throws->TranslateBatchResult {
        try await Task.sleep(for:translationDelay)
        if !translationFailures.isEmpty { throw translationFailures.removeFirst() }
        return .init(translations:request.units.map{unit in
            .init(unitID:unit.unitID,text:request.targetLanguage == .zh ? (unit.text.contains("window") ? "窗户开着。" : "这是一段用于界面验证的译文。") : "This is an example translation.")
        },meta:meta(configuration,prompt:request.promptVersion))
    }
    func alignSelection(_ request:AlignSelectionRequest,configuration:ModelConfiguration)async throws->AlignSelectionResult {
        try await Task.sleep(for:.milliseconds(40))
        let quote = request.counterpartText.contains("窗户") ? "窗户" : request.counterpartText.contains("window") ? "window" : String(request.counterpartText.prefix(2))
        return .init(match:.matched(matches:[.init(quote:quote,occurrence:1)]),meta:meta(configuration,prompt:"alignment.v1"))
    }
    func shutdown()async{}
    private func meta(_ config:ModelConfiguration,prompt:String)->GatewayMeta {
        .init(provider:config.provider,requestedModel:config.model,requestedEffort:config.effort,returnedModel:"offline-fixture",promptVersion:prompt,inputTokens:nil,outputTokens:nil)
    }
}
@main struct FixtureApp:App {
    @NSApplicationDelegateAdaptor(FixtureDelegate.self) private var delegate
    @StateObject private var runtime:AppRuntime
    @State private var benchmarkStarted=false
    init(){
        let defaults=UserDefaults(suiteName:"dev.bipara.ui-tests")!
        defaults.removePersistentDomain(forName:"dev.bipara.ui-tests")
        let args=ProcessInfo.processInfo.arguments
        let keys=FixtureKeys()
        let testsDiagnostics = args.contains("--translation-diagnostics")
        let gateway = FixtureGateway(
            translationDelay: args.contains("--slow-translation") ? .seconds(90) : .milliseconds(80),
            translationFailures: testsDiagnostics ? [
                .init(code: .authentication, httpStatus: 401, providerCode: "1001"),
                .init(code: .invalidOutput, validationFailure: .invalidJSON),
            ] : []
        )
        let value = AppRuntime(gateway: gateway, keychain: keys, defaults: defaults)
        if let id=value.settings.record.defaultConfiguration?.id{keys.keys[id]="SYNTHETIC_UI_FIXTURE"}
        for configuration in value.settings.record.modelConfigurations{keys.keys[configuration.id]="SYNTHETIC_UI_FIXTURE"}
        defaults.set(true,forKey:"dev.bipara.disclosure.openai|https://api.openai.com")
        defaults.set(true,forKey:"dev.bipara.disclosure.glm|https://open.bigmodel.cn")
        func argument(_ key:String)->String?{guard let i=args.firstIndex(of:key),i+1<args.count else{return nil};return args[i+1]}
        value.settings.updateDraft{
            $0.appearance=AppearanceMode(rawValue:argument("--appearance") ?? "system") ?? .system
            $0.typography.size=Double(argument("--font") ?? "17") ?? 17
            $0.interfaceLanguage=InterfaceLanguage(rawValue:argument("--language") ?? "en") ?? .english
        }
        try! value.settings.saveDraft();value.appearance.apply(value.settings.record.appearance)
        if testsDiagnostics {
            _ = try! value.workspace.newTab(source: "The window is open. It rained today.", direction: .enToZh)
        }
        if args.contains("--corpus") {
            for i in 1...5 {
                let source=(1...220).map{"Paragraph \($0): The window is open. It rained today. This synthetic paragraph is used to measure native reading and tab responsiveness. " + String(repeating:"A useful example sentence. ",count:15)}.joined(separator:"\n\n")
                let index=try! value.workspace.newTab(source:source,direction:.enToZh)
                value.workspace.withTab(index){$0.document.title="Fixture \(i)"}
            }
        }
        if args.contains("--reading-refinements"), let configuration=value.settings.record.defaultConfiguration {
            let source="""
            Good translation preserves both meaning and rhythm. Each paragraph belongs to the same document, even when the two languages use different sentence structures.

            A wider reading area gives long passages more room. The text stays at a comfortable size, while the original and translation remain easy to compare.

            Completed passages remain available while the rest of the translation is in progress. You can pause the task and return to it later.
            """
            let index=try! value.workspace.newTab(source:source,direction:.enToZh)
            value.workspace.withTab(index) { tab in
                tab.document.title="Reading notes";tab.automaticTitle=false
                let snapshot=JobSnapshot(jobID:UUID(),sourceRevision:tab.document.sourceRevision,sourceLanguage:.en,targetLanguage:.zh,
                    provider:configuration.provider,model:configuration.modelID,profile:configuration.profile,effort:configuration.effort,
                    translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1")
                let translations=["好的翻译既保留含义，也保留行文节奏。", "即使两种语言使用不同的句式，每一段仍属于同一份文档。", "更宽的阅读区域能让长文舒展一些。", "文字保持舒适的字号，原文与译文也依然方便对照。", "后续内容翻译期间，已完成的段落仍然可读。", "你可以暂停任务，稍后继续。"]
                let completed=args.contains("--reading-complete") ? tab.document.units.count : 4
                tab.document.translations=tab.document.units.prefix(completed).enumerated().map { .init(unitID:$0.element.id,text:translations[$0.offset % translations.count],completedAt:Date()) }
                tab.document.jobSnapshot=snapshot;tab.document.resolvedDirection = .enToZh
                tab.job.snapshot=snapshot;tab.job.totalNonblankUnits=tab.document.units.count
                tab.job.completedUnitIDs=Set(tab.document.translations.map(\.unitID));tab.job.state=tab.job.isFinished ? .completed : .paused
                tab.runtimeBinding = .init(configurationID:configuration.id,baseURL:configuration.baseURL,provider:configuration.provider)
                if args.contains("--paragraphs") { tab.layout = .paragraphs }
            }
        }
        _runtime=StateObject(wrappedValue:value)
    }
    var body:some Scene{
        Window("Bipara — UI Fixture",id:"main"){
            WorkspaceView(runtime:runtime).onAppear{
                delegate.runtime=runtime;NSApp.activate(ignoringOtherApps:true)
                // Keep fixture coordinates on the primary display, including multi-display hosts.
                if let window=runtime.mainWindow,let screen=NSScreen.screens.first {
                    window.setFrameOrigin(NSPoint(x:screen.visibleFrame.midX-window.frame.width/2,y:screen.visibleFrame.midY-window.frame.height/2))
                    window.makeKeyAndOrderFront(nil)
                }
                if ProcessInfo.processInfo.arguments.contains("--compact") {
                    NSApp.windows.first(where:{$0.isVisible})?.setContentSize(NSSize(width:900,height:650))
                }
                let args=ProcessInfo.processInfo.arguments
                if let i=args.firstIndex(of:"--menu-report"),i+1<args.count {
                    Task{
                        if let s=args.firstIndex(of:"--menu-report-start"),s+1<args.count {
                            let deadline=ContinuousClock.now.advanced(by:.seconds(60))
                            while !FileManager.default.fileExists(atPath:args[s+1]) {
                                guard ContinuousClock.now<deadline else {return}
                                try? await Task.sleep(for:.milliseconds(5))
                            }
                        }
                        await MainActor.run{
                            func menuTree(_ menu:NSMenu)->[[String:Any]]{
                                menu.items.map{item->[[String:Any]] in
                                    var row:[String:Any]=["title":item.title,"key":item.keyEquivalent]
                                    if let submenu=item.submenu{row["submenu"]=menuTree(submenu)}
                                    return [row]
                                }.flatMap{$0}
                            }
                            var report:[String:Any]=[:]
                            if let appMenu=NSApp.mainMenu{
                                // Top-level items are the menu bar itself;
                                // the app menu is the first submenu.
                                report["menuBarTitles"]=appMenu.items.map(\.title)
                                if let appItems=appMenu.items.first?.submenu?.items{
                                    report["appMenuItems"]=appItems.map{["title":$0.title,"key":$0.keyEquivalent,"enabled":$0.isEnabled]}
                                }
                                report["fullMenu"]=menuTree(appMenu)
                            }
                            report["settingsWindowTitles"]=NSApp.windows.filter{$0.isVisible}.map(\.title)
                            if let data=try?JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]){
                                try? data.write(to:URL(fileURLWithPath:args[i+1]))
                            }
                        }
                    }
                }
                if !benchmarkStarted,let i=args.firstIndex(of:"--benchmark-output"),i+1<args.count {
                    benchmarkStarted=true
                    Task{
                        if let start=args.firstIndex(of:"--benchmark-start"),start+1<args.count {
                            let deadline=ContinuousClock.now.advanced(by:.seconds(90))
                            while !FileManager.default.fileExists(atPath:args[start+1]) {
                                guard ContinuousClock.now < deadline else {return}
                                try? await Task.sleep(for:.milliseconds(5))
                            }
                        }
                        await measureFixture(runtime:runtime,output:URL(fileURLWithPath:args[i+1]))
                    }
                }
            }
        }.defaultSize(width:1000,height:720).commands{AppCommands(runtime:runtime)}
        Window("Settings",id:"settings"){
            SettingsContent(runtime:runtime)
        }.defaultSize(width:560,height:700).windowResizability(.contentSize)
    }
}

/// Test-product-only, event-to-render timings on the real SwiftUI/AppKit window.
@MainActor private func measureFixture(runtime:AppRuntime,output:URL) async {
    let activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Measure foreground native interactions")
    defer{ProcessInfo.processInfo.endActivity(activity)}
    func contrastRatios() throws -> [String:Double] {
        func luminance(_ values:[Double]) -> Double {
            let linear=values.map{$0 <= 0.04045 ? $0/12.92:pow(($0+0.055)/1.055,2.4)}
            return 0.2126*linear[0]+0.7152*linear[1]+0.0722*linear[2]
        }
        var result:[String:Double]=[:]
        for name:NSAppearance.Name in [.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua] {
            guard let appearance=NSAppearance(named:name) else {throw NSError(domain:"appearance unavailable",code:8)}
            appearance.performAsCurrentDrawingAppearance {
                guard let fg=NSColor.labelColor.usingColorSpace(.sRGB),let bg=NSColor(named:"CorrespondenceBackground")?.usingColorSpace(.sRGB) else {return}
                let background=[bg.redComponent,bg.greenComponent,bg.blueComponent].map(Double.init)
                let foreground=[fg.redComponent,fg.greenComponent,fg.blueComponent].enumerated().map{Double($0.element*fg.alphaComponent)+background[$0.offset]*Double(1-fg.alphaComponent)}
                let a=luminance(foreground),b=luminance(background)
                result[name.rawValue]=(max(a,b)+0.05)/(min(a,b)+0.05)
            }
        }
        guard result.count == 4 else {throw NSError(domain:"compiled correspondence color unavailable",code:9)}
        return result
    }
    func sourceView(_ view:NSView?) -> NSTextView? {
        guard let view else{return nil}
        if let text=view as? NSTextView,text.accessibilityIdentifier()=="reader.source"{return text}
        for child in view.subviews {if let result=sourceView(child){return result}}
        return nil
    }
    func render() async throws {
        func surfaceIsCurrent() -> Bool {
            guard let tab=runtime.workspace.activeTab else { return false }
            let expected="reader.surface.\(tab.sessionID).\(tab.document.sourceRevision).\(tab.layout.rawValue).\(runtime.reading[tab.sessionID]?.selectionGeneration ?? 0)"
            func contains(_ view:NSView?) -> Bool {
                guard let view else { return false }
                return (view as? any NativeReadingRenderState)?.renderedIdentity == expected || view.subviews.contains(where:{contains($0)})
            }
            return contains(runtime.mainWindow?.contentView)
        }
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while !surfaceIsCurrent() {
            guard ContinuousClock.now < deadline else { throw NSError(domain:"native surface did not acknowledge state",code:4) }
            try await Task.sleep(for:.milliseconds(1))
        }
        // Native owner/layout/selection acknowledgement precedes one display interval and completed drawing.
        try await Task.sleep(for:.milliseconds(16))
        runtime.mainWindow?.contentView?.layoutSubtreeIfNeeded()
        runtime.mainWindow?.displayIfNeeded();CATransaction.flush()
        guard surfaceIsCurrent() else { throw NSError(domain:"native surface changed during drawing",code:5) }
    }
    do {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while runtime.mainWindow == nil || sourceView(runtime.mainWindow?.contentView)==nil {
            guard ContinuousClock.now < deadline else {throw NSError(domain:"fixture window unavailable",code:1)}
            try await Task.sleep(for:.milliseconds(10))
        }
        try await render()
        var samples:[[String:Any]]=[]
        for n in 0..<30 {
            let start=ContinuousClock.now
            let kind:String
            if n < 10 {kind="tab";runtime.workspace.switchTab(to:n%5)}
            else if n < 20 {kind="layout";runtime.setLayout(n%2 == 0 ? .paragraphs:.sideBySide)}
            else {
                kind="selection"
                guard let text=sourceView(runtime.mainWindow?.contentView) else {throw NSError(domain:"fixture reader unavailable",code:2)}
                text.setSelectedRange(NSRange(location:(n-20)*12,length:5))
            }
            try await render()
            let elapsed=start.duration(to:.now)
            samples.append(["kind":kind,"milliseconds":Double(elapsed.components.attoseconds)/1e15 + Double(elapsed.components.seconds)*1000,
                            "foreground":NSApp.isActive,"key_window":runtime.mainWindow?.isKeyWindow ?? false])
        }
        let session=runtime.workspace.activeTab!.sessionID
        let job=Task{await runtime.translate(session)}
        while runtime.workspace.activeTab?.job.state != .running {
            guard ContinuousClock.now < deadline else {throw NSError(domain:"fixture job did not start",code:3)}
            try await Task.sleep(for:.milliseconds(2))
        }
        let cancelStart=ContinuousClock.now
        runtime.coordinator.cancel(tabIndex:runtime.workspace.activeTabIndex!,workspace:runtime.workspace)
        guard runtime.workspace.activeTab?.job.state == .paused else { throw NSError(domain:"cancel was not acknowledged",code:6) }
        try await render()
        let cancelDuration=cancelStart.duration(to:.now)
        await job.value
        guard runtime.workspace.activeTab?.job.state == .paused else { throw NSError(domain:"cancelled job resumed unexpectedly",code:7) }
        let timings=samples.compactMap{$0["milliseconds"] as? Double}.sorted()
        #if DEBUG
        let configuration="Debug"
        #else
        let configuration="Release"
        #endif
        let report:[String:Any]=[
            "interaction_count":samples.count,"p95_ms":timings[Int(ceil(Double(timings.count)*0.95))-1],
            "samples":samples,"local_cancel_ms":Double(cancelDuration.components.seconds)*1000+Double(cancelDuration.components.attoseconds)/1e15,
            "tabs":runtime.workspace.tabs.count,"source_bytes":runtime.workspace.tabs.map{$0.document.source.utf8.count},
            "frame_wait_ms":16,"configuration":configuration,
            "cancelled_state":"paused",
            "contrast_ratios":try contrastRatios(),
        ]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
    } catch {
        let data=try? JSONSerialization.data(withJSONObject:["error":"fixture benchmark failed"])
        try? data?.write(to:output,options:.atomic)
    }
}
@MainActor final class FixtureDelegate:NSObject,NSApplicationDelegate {
    weak var runtime:AppRuntime?
    private var terminating=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        guard !terminating else{return .terminateLater}
        guard let runtime else{return .terminateNow}
        terminating=true
        Task{let result=await runtime.prepareToQuit();if result{await runtime.gateway.shutdown()};terminating=false;sender.reply(toApplicationShouldTerminate:result)}
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}

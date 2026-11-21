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
private enum SampleArticle {
    static let excerpt = """
        ```diff
        @@ -8,3 +8,3 @@
         Cover the dough with a damp towel.
        -Let it rest for 10 minutes.
        +Let it rest for 20 minutes.
         Divide it into four equal pieces.
        ```
        """
    static let passages = [
        ("# ", "Reading a Git diff", "读懂 Git 差异"),
        ("", "A recipe and its introduction changed in the same edit. You want to know whether the ingredients changed or whether dinner just takes longer. Start with the lines that Git marks as changed, then read the instructions around them.", "一份食谱的做法和前言一起改了。是换了配料，还是这顿饭得晚点上桌？先看 Git 标出的改动，再读一读前后两步，就能找到答案。"),
        ("## ", "Start with one file", "从一个文件开始"),
        ("", "Run `git diff -- notes.md` to compare the edits in your working copy with the staged version of the recipe. The two file headers name the versions being compared. Each block below them shows one stretch of the file.", "运行 `git diff -- notes.md`，把工作区里的食谱和暂存区的版本做对比。开头两行写着参与对比的文件名，下面的每一块都对应文件里的一段连续内容。"),
        ("", excerpt, excerpt),
        ("## ", "Read the change in context", "把改动放回上下文"),
        ("", "The line starting with `-` gives the old resting time. The line starting with `+` gives the new one. The unchanged instructions tell you which wait got longer: the dough rests under a towel for ten extra minutes before you divide it.", "以 `-` 开头的一行写的是原来的静置时间，以 `+` 开头的一行写的是新的时间。前后两行说明了到底哪一步要多等：面团盖上湿毛巾以后，要多放十分钟才能分成四份。"),
        ("", "To review what will go into your next commit, use `git diff --staged`. The [Git reference](https://git-scm.com/docs/git-diff) describes both comparisons.", "想确认下次提交会包含哪些改动，可以运行 `git diff --staged`。两种对比方式都可以在 [Git 参考手册](https://git-scm.com/docs/git-diff)里查到。")
    ]
    static let source = passages.map { $0.0 + $0.1 }.joined(separator: "\n\n")
    static let translations = Dictionary(uniqueKeysWithValues: passages.map { ($0.1, $0.2) })
}

actor FixtureGateway:ModelGateway {
    let translationDelay:Duration
    private var translationFailures: [GatewayError]
    let failureGate: URL?
    init(translationDelay: Duration = .milliseconds(80), failureGate: URL? = nil, translationFailures: [GatewayError] = []) {
        self.failureGate = failureGate
        self.translationDelay = translationDelay
        self.translationFailures = translationFailures
    }
    func translateBatch(_ request:TranslateBatchRequest,configuration:ModelConfiguration)async throws->TranslateBatchResult {
        try await Task.sleep(for:translationDelay)
        if let failureGate {
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !FileManager.default.fileExists(atPath: failureGate.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        if !translationFailures.isEmpty { throw translationFailures.removeFirst() }
        return .init(translations: request.units.map { unit in
            let text: String
            if WorkerContract.markdownTranslationPromptVersions.contains(request.promptVersion) {
                text = SampleArticle.translations[unit.text] ?? unit.text
                    .replacingOccurrences(of: "Setup", with: "准备")
                    .replacingOccurrences(of: "Open the", with: "打开")
                    .replacingOccurrences(of: "window", with: "窗户")
            } else {
                text = request.targetLanguage == .zh
                    ? (unit.text.contains("window") ? "窗户开着。" : "这是一段用于界面验证的译文。")
                    : "This is an example translation."
            }
            return .init(unitID: unit.unitID, text: text)
        }, meta: meta(configuration, prompt: request.promptVersion))
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
        func argument(_ key:String)->String?{guard let i=args.firstIndex(of:key),i+1<args.count else{return nil};return args[i+1]}
        let keys=FixtureKeys()
        let testsDiagnostics = args.contains("--translation-diagnostics") || args.contains("--background-failure")
        let gateway = FixtureGateway(
            translationDelay: args.contains("--slow-translation") ? .seconds(90) : .milliseconds(80),
            failureGate: argument("--failure-gate").map { URL(fileURLWithPath: $0) },
            translationFailures: testsDiagnostics ? [
                .init(code: .authentication, httpStatus: 401, providerCode: "1001"),
                .init(code: .invalidOutput, validationFailure: .invalidJSON),
            ] : []
        )
        let pasteboard = argument("--pasteboard").map { NSPasteboard(name: .init($0)) } ?? .general
        let configurations: [ModelConfigurationRecord]
        if args.contains("--legacy-models") {
            configurations = [.init(displayName: "OpenAI", provider: "openai", profile: ModelProfileID.openaiV2,
                modelID: "gpt-4.1-mini-2025-04-14", effort: .auto, baseURL: WorkerContract.openAIStandardBaseURL)]
        } else if args.contains("--configured-models") {
            configurations = [
                .init(displayName: "OpenAI", provider: "openai", profile: ModelAPIProtocol.openai.profile,
                      modelID: "gpt-6-luna", effort: .low, baseURL: WorkerContract.openAIStandardBaseURL,
                      vendorLabel: "OpenAI", requestOptions: ModelRequestOptions(), revision: UUID()),
                .init(displayName: "GLM", provider: "openai", profile: ModelAPIProtocol.openai.profile,
                      modelID: "glm-5.3-flash", effort: .low, baseURL: WorkerContract.glmStandardBaseURL,
                      vendorLabel: "GLM", requestOptions: ModelRequestOptions(), revision: UUID()),
            ]
        } else {
            configurations = []
        }
        if !configurations.isEmpty {
            let preferences = PreferencesRecord(modelConfigurations: configurations)
            defaults.set(try! JSONEncoder().encode(preferences), forKey: SettingsStore.defaultsKey)
        }
        let value = AppRuntime(gateway: gateway, keychain: keys, defaults: defaults, pasteboard: pasteboard)
        for configuration in value.settings.record.modelConfigurations{keys.keys[configuration.id]="SYNTHETIC_UI_FIXTURE"}
        defaults.set(true,forKey:"dev.bipara.disclosure.openai|https://api.openai.com")
        defaults.set(true,forKey:"dev.bipara.disclosure.openai|https://open.bigmodel.cn")
        defaults.set(true,forKey:"dev.bipara.disclosure.glm|https://open.bigmodel.cn")
        value.settings.updateDraft{
            $0.appearance=AppearanceMode(rawValue:argument("--appearance") ?? "system") ?? .system
            $0.typography.size=Double(argument("--font") ?? "17") ?? 17
            $0.interfaceLanguage=InterfaceLanguage(rawValue:argument("--language") ?? "en") ?? .english
        }
        try! value.settings.saveDraft();value.appearance.apply(value.settings.record.appearance)
        if args.contains("--reading-article") {
            value.settings.updateDraft {
                $0.typography.family = .system
                $0.typography.lineHeight = .compact
            }
            try! value.settings.saveDraft()
            _ = try! value.workspace.newTab(source: SampleArticle.source, direction: .enToZh)
        }
        if testsDiagnostics {
            _ = try! value.workspace.newTab(source: "The window is open. It rained today.", direction: .enToZh)
        }
        if args.contains("--overflow-tabs") {
            for _ in 0..<11 { _ = try! value.workspace.newTab() }
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
                    translationPromptVersion:"translation.v1",alignmentPromptVersion:"alignment.v1",configurationRevision:configuration.revision)
                let translations=["好的翻译既保留含义，也保留行文节奏。", "即使两种语言使用不同的句式，每一段仍属于同一份文档。", "更宽的阅读区域能让长文舒展一些。", "文字保持舒适的字号，原文与译文也依然方便对照。", "后续内容翻译期间，已完成的段落仍然可读。", "你可以暂停任务，稍后继续。"]
                let completed=args.contains("--reading-complete") ? tab.document.units.count : 4
                tab.document.translations=tab.document.units.prefix(completed).enumerated().map { .init(unitID:$0.element.id,text:translations[$0.offset % translations.count],completedAt:Date()) }
                tab.document.jobSnapshot=snapshot;tab.document.resolvedDirection = .enToZh
                tab.job.snapshot=snapshot;tab.job.totalNonblankUnits=tab.document.units.count
                tab.job.completedUnitIDs=Set(tab.document.translations.map(\.unitID));tab.job.state=tab.job.isFinished ? .completed : .paused
                tab.runtimeBinding = configuration.runtimeBinding
                if args.contains("--paragraphs") { tab.layout = .paragraphs }
            }
        }
        _runtime=StateObject(wrappedValue:value)
    }
    var body:some Scene{
        Window(ProcessInfo.processInfo.arguments.contains("--reading-article") ? "Bipara" : "Bipara — UI Fixture",id:"main"){
            WorkspaceView(runtime:runtime).onAppear{
                delegate.runtime=runtime;NSApp.activate(ignoringOtherApps:true)
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
            .task {
                // SwiftUI attaches the window delegate after the view can appear.
                while runtime.mainWindow == nil {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
                guard let window = runtime.mainWindow, let screen = NSScreen.screens.first else { return }
                let args = ProcessInfo.processInfo.arguments
                let visible = screen.visibleFrame
                let requested: NSSize
                if args.contains("--wide-window") {
                    requested = NSSize(width: 1860, height: 770)
                } else if args.contains("--compact") {
                    requested = NSSize(width: 900, height: 650)
                } else if args.contains("--reading-article") {
                    requested = NSSize(width: 1080, height: 880)
                } else {
                    requested = NSSize(width: 1000, height: 720)
                }
                window.setContentSize(NSSize(width: min(requested.width, visible.width), height: min(requested.height, visible.height - 60)))
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
                window.makeKeyAndOrderFront(nil)
            }
        }.defaultSize(width:1000,height:720).commands{AppCommands(runtime:runtime)}
        Window("Settings",id:"settings"){
            SettingsContent(runtime:runtime)
                .task {
                    while !Task.isCancelled {
                        if let window = NSApp.windows.first(where: { $0.accessibilityIdentifier() == "Bipara.Settings" }),
                           let screen = NSScreen.screens.first {
                            let visible = screen.visibleFrame
                            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
                            window.makeKeyAndOrderFront(nil)
                            return
                        }
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                }
        }.defaultSize(width:560,height:700).windowResizability(.contentSize)
    }
}

/// Test-product-only, event-to-render timings on the real SwiftUI/AppKit window.
@MainActor private func measureFixture(runtime:AppRuntime,output:URL) async {
    let activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Measure foreground native interactions")
    defer{ProcessInfo.processInfo.endActivity(activity)}
    func sourceView(_ view:NSView?) -> NSTextView? {
        guard let view else{return nil}
        if let text=view as? NSTextView,text.accessibilityIdentifier()=="reader.source"{return text}
        for child in view.subviews {if let result=sourceView(child){return result}}
        return nil
    }
    func render() async throws {
        func surfaceIsCurrent() -> Bool {
            guard let tab=runtime.workspace.activeTab else { return false }
            let expected="reader.surface.\(tab.sessionID).\(tab.document.sourceRevision).\(tab.layout.rawValue)"
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
        // Native owner and layout acknowledgement precedes one display interval and completed drawing.
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

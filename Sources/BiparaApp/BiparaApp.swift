import AppKit
import BiparaAppKit
import SwiftUI

@main
enum BiparaEntry {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let bundle = Bundle.main.bundleURL
        if args == ["--install-local-build"] || args.first == "--install-from" {
            do {
                let local = args == ["--install-local-build"]
                guard local || args.count == 2 else {
                    FileHandle.standardError.write(Data("Usage: Bipara --install-from /path/to/Bipara.app\n".utf8))
                    exit(2)
                }
                try AppInstaller.install(local ? bundle : URL(fileURLWithPath: args[1]), localRebuild: local)
                print("Installed \(AppInstaller.destination.path)")
            } catch {
                FileHandle.standardError.write(Data("Install failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            let prompt = NSAlert()
            prompt.messageText = "Install Bipara in Applications?"
            prompt.informativeText = "Save your documents and quit any installed copy before continuing."
            prompt.addButton(withTitle: "Install")
            prompt.addButton(withTitle: "Cancel")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }
            do {
                try AppInstaller.install(bundle)
                NSWorkspace.shared.activateFileViewerSelecting([AppInstaller.destination])
            } catch {
                NSAlert(error: error).runModal()
            }
            return
        }
        BiparaApp.main()
    }
}

struct BiparaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var runtime = AppRuntime.production()
    var body:some Scene {
        Window("Bipara",id:"main"){
            WorkspaceView(runtime:runtime)
                .onAppear{delegate.runtime=runtime;NSApp.activate(ignoringOtherApps:true)}
                .onOpenURL{url in Task{await runtime.open(url)}}
        }.defaultSize(width:1000,height:720).commands{AppCommands(runtime:runtime)}
        // The settings surface is a dedicated native window (not the
        // automatic `Settings` scene): on this OS the scene installs its
        // own app-menu item in addition to any localized replacement
        // command, producing two Settings entries. One explicit window +
        // one localized command keeps the single-entry contract.
        Window("Settings",id:"settings"){
            SettingsContent(runtime:runtime)
        }.defaultSize(width:560,height:700).windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate:NSObject, NSApplicationDelegate {
    weak var runtime:AppRuntime?
    private var terminating=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard !terminating else{return .terminateLater}
        guard let runtime else{return .terminateNow}
        terminating=true
        Task{
            let approved=await runtime.prepareToQuit()
            if approved{await runtime.gateway.shutdown()}
            terminating=false;sender.reply(toApplicationShouldTerminate:approved)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}

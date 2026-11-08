import AppKit
import BiparaAppKit
import SwiftUI

@main
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

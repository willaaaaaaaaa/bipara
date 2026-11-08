import AppKit
import SwiftUI

struct WindowLifecycle: NSViewRepresentable {
    let runtime:AppRuntime
    let settings:Bool
    final class Host: NSView {
        var connect: ((NSWindow)->Void)?
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let window{connect?(window)}}
    }
    final class Coordinator:NSObject, NSWindowDelegate {
        let runtime:AppRuntime
        let settings:Bool
        weak var original:(any NSWindowDelegate)?
        var approved=false, reviewing=false
        init(_ parent:WindowLifecycle){runtime=parent.runtime;settings=parent.settings}
        override func responds(to selector:Selector!)->Bool {super.responds(to:selector) || (original?.responds(to:selector) ?? false)}
        override func forwardingTarget(for selector:Selector!)->Any? {original}
        func windowDidBecomeKey(_ notification:Notification) {
            runtime.focusedWindowRole = settings ? "settings" : "reader"
            original?.windowDidBecomeKey?(notification)
        }
        func windowDidResignKey(_ notification:Notification) {
            if runtime.focusedWindowRole == (settings ? "settings" : "reader") { runtime.focusedWindowRole = nil }
            original?.windowDidResignKey?(notification)
        }
        func windowShouldClose(_ sender:NSWindow)->Bool {
            if approved {approved=false;return original?.windowShouldClose?(sender) ?? true}
            guard !reviewing else{return false}
            reviewing=true
            Task {
                let canClose = settings ? await runtime.closeSettings() : await runtime.closeAll()
                reviewing=false
                if canClose{approved=true;sender.performClose(nil)}
            }
            return false
        }
    }
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->Host{
        let host=Host()
        host.connect={ [weak coordinator=context.coordinator] window in
            guard let coordinator, window.delegate !== coordinator else{return}
            coordinator.original=window.delegate;window.delegate=coordinator
            if window.isKeyWindow { coordinator.runtime.focusedWindowRole = coordinator.settings ? "settings" : "reader" }
            func removeDuplicateCloseShortcut(_ menu: NSMenu?) {
                for item in menu?.items ?? [] {
                    if item.action == #selector(NSWindow.performClose(_:)), item.keyEquivalent == "w" { item.keyEquivalent = "" }
                    removeDuplicateCloseShortcut(item.submenu)
                }
            }
            removeDuplicateCloseShortcut(NSApp.mainMenu)
            window.setAccessibilityIdentifier(settings ? "Bipara.Settings" : "Bipara.Main")
            if settings { runtime.applyLocalizedChrome() }
        }
        return host
    }
    func updateNSView(_ view:Host,context:Context){}
}

import AppKit
import BiparaCore
import SwiftUI

public struct AppCommands: Commands {
    @ObservedObject var runtime:AppRuntime
    @ObservedObject var workspace:WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    public init(runtime:AppRuntime){self.runtime=runtime;workspace=runtime.workspace}
    private func t(_ key:String)->String{runtime.text(key)}
    private var readerFocused:Bool{runtime.focusedWindowRole == "reader"}
    private var readingFocused:Bool{readerFocused && runtime.activeSession.map{!runtime.editing.contains($0)} == true}
    public var body:some Commands {
        CommandGroup(replacing:.newItem){
            Button(t("New Translation")){openWindow(id:"main");runtime.newTab()}.keyboardShortcut("t")
            Button(t("Open…"),action:runtime.openPanel).keyboardShortcut("o")
        }
        CommandGroup(after:.newItem) {
            Button(t(readerFocused ? "Close Tab" : "Close Window")) {
                if readerFocused, let session = runtime.activeSession { Task { _ = await runtime.close(session) } }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
        }
        CommandGroup(replacing:.saveItem){
            Button(t("Save")){if readerFocused, let session=runtime.activeSession{Task{_ = await runtime.save(session)}}}.keyboardShortcut("s")
                .disabled(workspace.activeTab==nil || !readerFocused || runtime.activeSession.map{runtime.composing.contains($0)}==true)
            Button(t("Export Translation…")) { runtime.export(bilingual: false) }
                .disabled(workspace.activeTab?.document.canUseMarkdownPlan != true || !readerFocused)
            Button(t("Export Bilingual…")) { runtime.export(bilingual: true) }
                .disabled(workspace.activeTab?.document.canUseMarkdownPlan != true || !readerFocused)
            if workspace.activeTab?.document.isMarkdown == true {
                Button(t("Export Translation as Markdown…")) { runtime.export(bilingual: false, markdown: true) }
                    .disabled(workspace.activeTab?.document.canUseMarkdownPlan != true || !readerFocused)
                Button(t("Export Bilingual as Markdown…")) { runtime.export(bilingual: true, markdown: true) }
                    .disabled(workspace.activeTab?.document.canUseMarkdownPlan != true || !readerFocused)
            }
        }
        // Exactly one localized app-menu Settings command with
        // Command-comma, opening or focusing the single settings window
        // whether the reader or the settings window is key. A plain
        // button keeps the label in the app's explicit interface language
        // (the automatic Settings-scene item would follow the system
        // locale and duplicate this command).
        CommandGroup(replacing:.appSettings){Button(t("Settings…")){openWindow(id:"settings")}.keyboardShortcut(",")}
        CommandGroup(replacing:.windowArrangement){Button("Bipara"){openWindow(id:"main")}}
        CommandMenu(t("Translation")){
            Button(t("Translate / Resume")){
                if readerFocused, let tab=workspace.activeTab, ![.running,.queued].contains(tab.job.state){runtime.primaryAction()}
            }.keyboardShortcut(.return,modifiers:.command).disabled(!readerFocused || workspace.activeTab==nil || workspace.activeTab.map{[.running,.queued].contains($0.job.state) || (readingFocused && $0.hasNoProseToTranslate) || $0.draftText.isEmpty || $0.draftText.isWhitespaceOnly || runtime.composing.contains($0.sessionID) || runtime.closing.contains($0.sessionID)}==true)
            Button(t("Side by side")){runtime.setLayout(.sideBySide)}.keyboardShortcut("1").disabled(!readingFocused)
            Button(t(workspace.activeTab?.document.isMarkdown == true ? "Sections" : "Paragraphs")){runtime.setLayout(.paragraphs)}.keyboardShortcut("2").disabled(!readingFocused)
            Divider()
            Button(t("Reveal counterpart"),action:runtime.reveal).disabled(!readerFocused || workspace.activeTab==nil)
            Button(t("Clear pin"),action:runtime.clearPin).disabled(!readerFocused || workspace.activeTab==nil)
        }
    }
}

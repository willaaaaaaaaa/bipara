import XCTest
import AppKit

@MainActor
final class BiparaUITests: XCTestCase {
    var app:XCUIApplication!
    override func setUp()async throws{await MainActor.run{continueAfterFailure=false;app=XCUIApplication()}}
    override func tearDown()async throws{await MainActor.run{app.terminate()}}
    private func launch(_ arguments:[String]=[]){
        // Isolate fixture launches from saved window state left by earlier cases/manual QA.
        app.launchArguments=["-ApplePersistenceIgnoreState","YES"]+arguments;app.launch();app.activate()
        if !app.windows["Bipara.Main"].waitForExistence(timeout:3) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Bipara"].firstMatch.click()
            XCTAssertTrue(app.windows["Bipara.Main"].waitForExistence(timeout:5))
        }
    }
    private func capture(_ name:String){
        app.activate()
        let window = name.contains("settings") ? app.windows.containing(.button,identifier:"settings.save").firstMatch : app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name=name;shot.lifetime = .keepAlways;add(shot)
    }
    private func enterExample(){
        app.buttons["new.tab"].click()
        let editor=app.textViews["source.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout:5));settleInputContext();editor.click();editor.typeText("The window is open. It rained today.")
        XCTAssertEqual(editor.value as? String,"The window is open. It rained today.")
    }
    private func settleInputContext(){
        // macOS may briefly show its document-input-source HUD when a new editor gains focus.
        let gone=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.dialogs.buttons["InputSource"])
        XCTAssertEqual(XCTWaiter.wait(for:[gone],timeout:5),.completed)
    }
    private func translate(){
        app.buttons["translation.primary"].click()
        XCTAssertTrue(app.textViews["reader.source"].waitForExistence(timeout:5))
        let done=NSPredicate(format:"value CONTAINS %@","窗户开着")
        expectation(for:done,evaluatedWith:app.textViews["reader.translation"])
        waitForExpectations(timeout:10)
    }
    func testTranslationFailureDiagnostics() {
        launch(["--translation-diagnostics", "--language", "zh-Hans"])
        if !app.windows["Bipara.Main"].waitForExistence(timeout: 3) {
            let menu = app.menuBars.menuBarItems["Window"]
            menu.click()
            menu.menuItems["Bipara — UI Fixture"].click()
        }
        let translate = app.buttons["translation.primary"]
        XCTAssertTrue(translate.waitForExistence(timeout: 8))
        for expected in [
            ["HTTP 401", "服务商错误码：1001"],
            ["模型返回的内容不是有效的 JSON。"],
        ] {
            translate.click()
            let detail = NSPredicate(format: "value CONTAINS %@", expected[0])
            let sheet = app.sheets.firstMatch
            let message = sheet.staticTexts.matching(detail).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 8))
            let value = message.value as? String ?? ""
            for line in expected { XCTAssertTrue(value.contains(line)) }
            XCTAssertFalse(value.contains("The window is open."))
            XCTAssertFalse(value.contains("SYNTHETIC_UI_FIXTURE"))
            sheet.buttons["action-button-1"].click()
        }
    }

    func testInputTranslationBothLayoutsAndSettings(){
        launch();enterExample();translate()
        app.typeKey("2",modifierFlags:.command)
        XCTAssertFalse(app.textViews["reader.translation"].exists)
        XCTAssertTrue(app.textViews["reader.source"].value as? String != nil)
        app.typeKey("1",modifierFlags:.command)
        XCTAssertTrue(app.textViews["reader.translation"].exists)
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        capture("settings-light")
    }
    func testMarkdownDetectionTranslationAndReadingModes() throws {
        launch()
        app.buttons["new.tab"].click()
        let editor = app.textViews["source.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        settleInputContext()
        editor.click()
        editor.typeText("# Setup\n\nOpen the **window**.\n\n## Finish\n\nRead the guide.")
        let detection = app.staticTexts["document.detectedFormat"]
        let detected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Markdown", "Markdown"),
            object: detection
        )
        XCTAssertEqual(XCTWaiter.wait(for: [detected], timeout: 5), .completed)
        app.buttons["translation.primary"].click()

        let source = app.textViews["reader.source"]
        let target = app.textViews["reader.translation"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "准备"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 8), .completed)
        XCTAssertTrue((source.value as? String ?? "").contains("Open the"))
        XCTAssertFalse((source.value as? String ?? "").contains("# Setup"))
        capture("markdown-rendered")

        app.radioButtons["Source"].click()
        let markup = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "**window**"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [markup], timeout: 5), .completed)
        app.radioButtons["Rendered"].click()
        app.typeKey("2", modifierFlags: .command)
        let section = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "准备"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [section], timeout: 5), .completed)
        XCTAssertFalse(target.exists)
        let sections = source.value as? String ?? ""
        let firstOriginal = try XCTUnwrap(sections.range(of: "Setup"))
        let firstTranslation = try XCTUnwrap(sections.range(of: "准备"))
        let nextOriginal = try XCTUnwrap(sections.range(of: "Finish"))
        XCTAssertLessThan(firstOriginal.lowerBound, firstTranslation.lowerBound)
        XCTAssertLessThan(firstTranslation.lowerBound, nextOriginal.lowerBound)
    }

    func testLocalizedNativeTextAccessibility() {
        launch(["--reading-refinements", "--reading-complete", "--language", "zh-Hans"])
        let source = app.textViews["reader.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(source.label, "原文")
        XCTAssertEqual(app.textViews["reader.translation"].label, "译文")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertEqual(source.label, "原文与译文")
        XCTAssertFalse(app.textViews["reader.translation"].exists)
        app.typeKey(",", modifierFlags: .command)
        app.popUpButtons["settings.language"].click()
        app.menuItems["English"].firstMatch.click()
        app.buttons["settings.save"].click()
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(source.label, "Original and translation")
        app.terminate()
        launch(["--language", "zh-Hans"])
        app.typeKey("t", modifierFlags: .command)
        let editor = app.textViews["source.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.label, "原文")
    }

    func testReadingSizeAccessibilityTracksChanges() {
        launch()
        app.typeKey(",", modifierFlags: .command)
        let size = app.sliders["settings.reading.size"]
        let save = app.buttons["settings.save"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.label, "Reading size")
        focusWithTab(size)
        for _ in 0..<14 { app.typeKey(.rightArrow, modifierFlags: []) }
        XCTAssertEqual((size.value as? NSNumber)?.intValue, 28)
        XCTAssertFalse(app.staticTexts["17 pt"].exists)
        focusWithTab(save)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual((size.value as? NSNumber)?.intValue, 28)
        focusWithTab(size)
        for _ in 0..<14 { app.typeKey(.leftArrow, modifierFlags: []) }
        XCTAssertEqual((size.value as? NSNumber)?.intValue, 14)
        app.windows["Bipara.Settings"].scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        app.popUpButtons["settings.language"].click()
        app.menuItems["简体中文"].firstMatch.click()
        app.buttons["settings.save"].click()
        XCTAssertEqual(size.label, "字号")
        XCTAssertEqual((size.value as? NSNumber)?.intValue, 14)
    }
    private func focusWithTab(_ element: XCUIElement) {
        // macOS XCTest exposes keyboard focus in the element snapshot.
        func isFocused() -> Bool {
            element.debugDescription.split(separator: "\n").first?.contains("Keyboard Focused") == true
        }
        for _ in 0..<24 {
            if isFocused() { return }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(isFocused(), "Tab navigation did not reach \(element)")
    }
    func testAccessibilityAuditOfReadingAndSettings() throws {
        continueAfterFailure = true
        launch(["--reading-refinements", "--reading-complete"])
        XCTAssertTrue(app.textViews["reader.source"].waitForExistence(timeout: 5))
        try audit("Side by side")
        app.typeKey("2", modifierFlags: .command)
        try audit("Paragraphs")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout: 5))
        try audit("Settings")
        app.buttons["settings.models.add"].click()
        XCTAssertTrue(app.textFields["settings.model.name"].waitForExistence(timeout: 5))
        try audit("Model editor")
    }
    private func audit(_ screen:String) throws {
        try XCTContext.runActivity(named: "Accessibility audit: " + screen) { _ in
            try app.performAccessibilityAudit { issue in
                let detail = XCTAttachment(string: issue.element?.debugDescription ?? "No element supplied by the audit.")
                detail.name = screen + " audit element"; detail.lifetime = .keepAlways; self.add(detail)
                return false
            }
        }
    }
    func testReadingRefinementPreferencesAndClose() {
        launch(["--appearance","light"])
        enterExample()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","tab.")).firstMatch.label.contains("Untitled 1"))
        translate()
        app.typeKey("2",modifierFlags:.command)
        let text=app.textViews["reader.source"].value as? String ?? ""
        XCTAssertTrue(text.contains("The window is open."));XCTAssertTrue(text.contains("窗户开着"))
        XCTAssertFalse(text.contains("Not translated yet"));XCTAssertFalse(text.contains("Original\n"));XCTAssertFalse(text.contains("Translation\n"))
        let status=app.staticTexts["translation.jobStatus"]
        XCTAssertTrue(status.waitForExistence(timeout:5))
        capture("reading-refinement-light-paragraphs")
        app.typeKey(",",modifierFlags:.command)
        let width=app.popUpButtons["settings.reading.width"]
        XCTAssertTrue(width.waitForExistence(timeout:5))
        width.click();app.menuItems["Window"].firstMatch.click()
        let highlight=app.popUpButtons["settings.reading.highlight"]
        XCTAssertEqual(highlight.value as? String,"Amber")
        highlight.click();app.menuItems["Purple"].firstMatch.click()
        XCTAssertEqual(highlight.value as? String,"Purple")
        app.buttons["settings.save"].click()
        capture("reading-refinement-settings")
        let skip=app.switches["settings.close.skipSave"]
        if !skip.isHittable { app.windows["Bipara.Settings"].scrollViews.firstMatch.scroll(byDeltaX:0,deltaY:600) }
        skip.click();app.buttons["settings.save"].click()
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey("w",modifierFlags:.command)
        XCTAssertTrue(app.buttons["New Translation"].firstMatch.waitForExistence(timeout:5))
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testReadingRefinementProgressAndDarkLayout() {
        launch(["--slow-translation","--appearance","dark"])
        enterExample();app.buttons["translation.primary"].click()
        XCTAssertTrue(app.textViews["reader.source"].waitForExistence(timeout:5))
        XCTAssertFalse((app.textViews["reader.translation"].value as? String ?? "").contains("Not translated yet"))
        app.typeKey("2",modifierFlags:.command)
        XCTAssertFalse((app.textViews["reader.source"].value as? String ?? "").contains("Not translated yet"))
        app.buttons["translation.primary"].click()
        XCTAssertEqual(app.buttons["translation.primary"].label,"Resume")
        capture("reading-refinement-dark-paused")
        app.typeKey("1",modifierFlags:.command)
        capture("reading-refinement-dark-columns")
    }
    func testSkipSaveAllowsQuitWithoutDocumentReview() {
        launch();enterExample();translate()
        app.typeKey(",",modifierFlags:.command)
        let skip=app.switches["settings.close.skipSave"]
        XCTAssertTrue(skip.waitForExistence(timeout:5));skip.click()
        app.buttons["settings.save"].click()
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey("q",modifierFlags:.command)
        XCTAssertTrue(app.wait(for:.notRunning,timeout:8))
    }
    func testDirtyCloseCancelPreservesDraft(){
        launch();enterExample();app.typeKey("w",modifierFlags:.command)
        let cancel=app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.click()
        XCTAssertTrue(app.textViews["source.editor"].exists)
        XCTAssertTrue((app.textViews["source.editor"].value as? String)?.contains("window") == true)
    }
    func testIndependentTabs(){
        launch();enterExample();app.buttons["new.tab"].click()
        let editor=app.textViews["source.editor"];XCTAssertTrue(editor.waitForExistence(timeout:5));XCTAssertEqual(editor.value as? String,"")
        settleInputContext()
        editor.click();app.textViews["source.editor"].typeText("Second document.")
        XCTAssertEqual(app.textViews["source.editor"].value as? String,"Second document.")
        XCTAssertTrue(app.scrollViews["workspace.tabs"].exists)
        let tabs=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","tab."))
        XCTAssertEqual(tabs.count,2);tabs.element(boundBy:0).click();settleInputContext()
        XCTAssertEqual(app.textViews["source.editor"].value as? String,"The window is open. It rained today.")
        tabs.element(boundBy:1).click();settleInputContext()
        XCTAssertEqual(app.textViews["source.editor"].value as? String,"Second document.")
    }
    func testNativeSelectionAndReveal(){
        launch();enterExample();translate()
        let original=app.textViews["reader.source"]
        original.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:90,dy:35)).hover()
        XCTAssertTrue(app.staticTexts["Sentence match"].waitForExistence(timeout:5))
        original.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:90,dy:35)).doubleClick()
        XCTAssertTrue(app.staticTexts["Suggested phrase correspondence"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout:5));app.buttons["Pin"].click()
        XCTAssertTrue(app.buttons["Reveal counterpart"].exists);app.buttons["Reveal counterpart"].click()
        capture("native-selection")
    }
    func testAppearanceAndLayoutScreenshots(){
        for mode in ["system","light","dark"]{
            launch(["--appearance",mode,"--language",mode == "dark" ? "zh-Hans":"en"])
            enterExample();translate()
            for layout in ["1","2"]{
                app.typeKey(layout,modifierFlags:.command)
                capture("\(mode)-layout-\(layout)")
            }
            app.typeKey(",",modifierFlags:.command)
            XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
            capture("\(mode)-settings")
            app.terminate()
        }
    }
    func testLargeFiveTabFixture(){
        launch(["--corpus"])
        XCTAssertTrue(app.textViews["reader.source"].waitForExistence(timeout:10))
        capture("five-tab-large-fixture")
        app.typeKey("2",modifierFlags:.command);app.typeKey("1",modifierFlags:.command)
        XCTAssertTrue(app.textViews["reader.translation"].exists)
    }
    func testThirtyNativeInteractionsAtFiveTabScale() throws {
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-benchmark-\(UUID()).json")
        let start=output.appendingPathExtension("start")
        defer{try? FileManager.default.removeItem(at:output);try? FileManager.default.removeItem(at:start)}
        launch(["--corpus","--benchmark-output",output.path,"--benchmark-start",start.path])
        XCTAssertTrue(app.textViews["reader.source"].firstMatch.waitForExistence(timeout:15))
        try Data().write(to:start,options:.atomic)
        let done=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in FileManager.default.fileExists(atPath:output.path)},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:40),.completed)
        let data=try Data(contentsOf:output),report=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="native-responsiveness";attachment.lifetime = .keepAlways;add(attachment)
        print("Bipara benchmark: p95_ms=\(report["p95_ms"] ?? "missing") local_cancel_ms=\(report["local_cancel_ms"] ?? "missing")");fflush(nil)
        XCTAssertNil(report["error"]);XCTAssertEqual(report["interaction_count"] as? Int,30)
        XCTAssertEqual(report["tabs"] as? Int,5)
        XCTAssertTrue(try XCTUnwrap(report["source_bytes"] as? [Int]).allSatisfy{$0 >= 100 << 10})
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["p95_ms"] as? Double),150)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["local_cancel_ms"] as? Double),200)
        XCTAssertEqual(report["cancelled_state"] as? String,"paused")
        let contrasts=try XCTUnwrap(report["contrast_ratios"] as? [String:Double])
        XCTAssertEqual(contrasts.count,4);XCTAssertTrue(contrasts.values.allSatisfy{$0 >= 4.5})
        print("Bipara benchmark: checking the native Resume control");fflush(nil)
        XCTAssertEqual(app.toolbars.buttons["translation.primary"].firstMatch.label,"Resume")
    }
    func testTypographyInCompactWindow(){
        for font in ["14","17","28"]{
            launch(["--font",font,"--compact"]);enterExample();translate()
            for layout in ["1","2"]{
                app.typeKey(layout,modifierFlags:.command)
                capture("compact-font-\(font)-layout-\(layout)")
            }
            app.terminate()
        }
    }
    func testThemeChangesWhileTranslationRemainsRunning(){
        launch(["--slow-translation"]);enterExample()
        app.buttons["translation.primary"].click()
        XCTAssertTrue(app.textViews["reader.source"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons["translation.primary"].label,"Cancel")
        app.typeKey(",",modifierFlags:.command)
        let appearance=app.popUpButtons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout:5));appearance.click()
        app.menuItems["Dark"].firstMatch.click()
        XCTAssertEqual(appearance.value as? String,"Dark")
        XCTAssertTrue(app.buttons["settings.save"].isHittable)
        app.buttons["settings.save"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        XCTAssertEqual(app.buttons["translation.primary"].label,"Cancel")
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["translation.primary"].click()
        let paused=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Resume"),object:app.buttons["translation.primary"])
        XCTAssertEqual(XCTWaiter.wait(for:[paused],timeout:5),.completed)
    }
    func testWorkspaceReopensAndFixtureLaunchIsIsolated(){
        launch()
        let workspace=app.windows["Bipara.Main"]
        XCTAssertTrue(workspace.waitForExistence(timeout:5))
        workspace.buttons[XCUIIdentifierCloseWindow].click()
        let closed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:workspace)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:5),.completed)
        app.typeKey("t",modifierFlags:.command)
        XCTAssertTrue(app.textViews["source.editor"].waitForExistence(timeout:5))
        XCTAssertTrue(app.windows["Bipara.Main"].exists)
        app.terminate()
        launch()
        XCTAssertTrue(app.buttons["new.tab"].waitForExistence(timeout:5))
        XCTAssertTrue(app.windows["Bipara.Main"].exists)
    }
    func testSettingsCredentialDraftAndWindowFocus(){
        launch();enterExample();translate();app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        // Edit the default configuration's key through the editor sheet.
        app.buttons["settings.model.row"].firstMatch.click()
        app.buttons["settings.models.edit"].click()
        let replace=app.buttons["settings.model.key.replace"]
        XCTAssertTrue(replace.waitForExistence(timeout:5))
        if !replace.exists { // no committed key in this fixture run: enter one
            app.buttons["Enter key"].firstMatch.click()
        } else { replace.click() }
        let key=app.secureTextFields["settings.model.key.field"]
        XCTAssertTrue(key.waitForExistence(timeout:3));key.click();key.typeText("SYNTHETIC_UI_REPLACEMENT")
        app.buttons["settings.model.confirm"].click()
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)
        // Canceling the settings draft discards the staged credential edit.
        app.buttons["settings.cancel"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        app.typeKey("w",modifierFlags:.command)
        XCTAssertTrue(app.textViews["reader.source"].exists)
        XCTAssertFalse(app.buttons["settings.save"].exists)
    }
    func testQuitReviewsSettingsDraftBeforeDocuments(){
        launch();app.typeKey(",",modifierFlags:.command)
        selectFirstRowAndOpenEditor()
        let model=app.textFields["settings.model.id"]
        XCTAssertTrue(model.waitForExistence(timeout:5))
        model.click()
        model.typeKey("a",modifierFlags:.command)
        model.typeText("gpt-6-luna-edited")
        app.buttons["settings.model.confirm"].click()
        app.typeKey("q",modifierFlags:.command)
        let cancel=app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.click()
        app.buttons["settings.models.edit"].click()
        let reopened=app.textFields["settings.model.id"]
        XCTAssertTrue(reopened.waitForExistence(timeout:5))
        XCTAssertTrue((reopened.value as? String)?.contains("gpt-6-luna-edited") == true)
        app.buttons["settings.model.cancel"].click()
        app.buttons["settings.cancel"].click()
    }

    func testCustomModelDirectionAndSharedActiveSelection() {
        launch()
        let newTab = app.buttons["new.tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.click()
        app.typeKey(",", modifierFlags: .command)
        let direction = app.popUpButtons["settings.translation.direction"]
        XCTAssertTrue(direction.waitForExistence(timeout: 5))
        XCTAssertTrue((direction.value as? String)?.contains("Automatic") == true)
        direction.click()
        app.menuItems["Chinese → English"].firstMatch.click()
        app.buttons["settings.models.add"].click()
        let model = app.textFields["settings.model.id"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.click(); model.typeText("deepseek-flash")
        let url = app.textFields["settings.model.url"]
        url.click(); url.typeText("https://api.deepseek.com/")
        let name = app.textFields["settings.model.name"]
        name.click()
        name.typeText("Fast DeepSeek")
        app.buttons["settings.model.confirm"].click()
        app.buttons["settings.save"].click()
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        let toolbar = app.descendants(matching: .any)["translation.activeModel"].firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        toolbar.click()
        // The SwiftUI toolbar menu exposes its items below the menu button.
        // DeepSeek is the third item after the two seeded configurations.
        toolbar.menus.firstMatch.children(matching: .any).element(boundBy: 2).click()
        app.typeKey(",", modifierFlags: .command)
        let active = app.popUpButtons["settings.model.default"]
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertEqual(active.value as? String, "Fast DeepSeek")
        XCTAssertTrue((direction.value as? String)?.contains("Chinese → English") == true)
    }

    // MARK: - Model configuration management (SET-03 / SET-04)

    func testModelConfigurationCRUDAndDefaultSelection(){
        launch();app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        let rows=app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout:5))
        XCTAssertEqual(rows.count,2) // seeded OpenAI + GLM
        let defaultPicker=app.popUpButtons["settings.model.default"]
        XCTAssertTrue(defaultPicker.exists)
        XCTAssertTrue((defaultPicker.value as? String)?.contains("OpenAI") == true)

        // Add: connection fields are entered manually; adding to a
        // nonempty draft preserves the selected default.
        app.buttons["settings.models.add"].click()
        let name=app.textFields["settings.model.name"]
        XCTAssertTrue(name.waitForExistence(timeout:5));name.click();name.typeText("Coding Plan trial")
        let model=app.textFields["settings.model.id"]
        model.click();model.typeText("glm-5.3-flash")
        let url=app.textFields["settings.model.url"]
        url.click();url.typeKey("a",modifierFlags:.command)
        url.typeText("https://open.bigmodel.cn/api/coding/paas/v4/")
        app.buttons["settings.model.confirm"].click()
        XCTAssertEqual(rows.count,3)
        XCTAssertTrue((defaultPicker.value as? String)?.contains("OpenAI") == true) // default unchanged

        // Delete the nondefault entry: the default is preserved.
        app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row")).element(boundBy:2).click()
        app.buttons["settings.models.delete"].click()
        XCTAssertEqual(rows.count,2)
        XCTAssertTrue((defaultPicker.value as? String)?.contains("OpenAI") == true)

        // Deleting the default of a nonempty list requires a replacement.
        app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row")).element(boundBy:0).click()
        app.buttons["settings.models.delete"].click()
        let cancel=app.buttons["settings.models.delete.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout:5))
        cancel.click() // cancellation leaves the draft unchanged
        XCTAssertEqual(rows.count,2)
        app.buttons["settings.models.delete"].click()
        let confirm=app.buttons["settings.models.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout:5));confirm.click()
        XCTAssertEqual(rows.count,1) // replacement chosen, list nonempty
        XCTAssertTrue((defaultPicker.value as? String)?.contains("GLM") == true)

        // Deleting the last entry clears the default; empty list is valid.
        app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row")).element(boundBy:0).click()
        app.buttons["settings.models.delete"].click()
        XCTAssertEqual(rows.count,0)
        XCTAssertTrue(app.staticTexts["Add a model configuration to translate."].exists)

        // Cancel discards everything, restoring the seeded draft.
        app.buttons["settings.cancel"].click()
        XCTAssertEqual(rows.count,2)
    }

    func testEditorValidatesURLsAliasesAndCapabilities(){
        launch();app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.models.add"].waitForExistence(timeout:5))
        app.buttons["settings.models.add"].click()
        let url=app.textFields["settings.model.url"]
        XCTAssertTrue(url.waitForExistence(timeout:5))
        let model=app.textFields["settings.model.id"]
        model.click();model.typeText("custom-model")
        // Operation-suffix URL is rejected locally; no call is made.
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText("https://api.openai.com/v1/chat/completions")
        app.buttons["settings.model.confirm"].click()
        let urlError=app.staticTexts["settings.model.sheet.error"]
        XCTAssertTrue(urlError.waitForExistence(timeout:5))
        XCTAssertTrue((urlError.value as? String ?? urlError.label).contains("HTTPS API Base URL"))
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText("https://api.openai.com/v1/")
        // Duplicate resolved name/effort requires a distinct alias.
        XCTAssertTrue(model.waitForExistence(timeout:3))
        let name=app.textFields["settings.model.name"]
        name.click();name.typeText("Duplicate trial")
        app.buttons["settings.model.confirm"].click()
        let rows=app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row"))
        // Poll on the test thread: background NSPredicate evaluation of
        // XCUI queries is unreliable in this environment.
        let rowDeadline=Date().addingTimeInterval(6)
        while rows.count < 3 && Date() < rowDeadline { Thread.sleep(forTimeInterval:0.15) }
        XCTAssertEqual(rows.count,3)
        app.buttons["settings.models.add"].click()
        let secondName=app.textFields["settings.model.name"]
        XCTAssertTrue(secondName.waitForExistence(timeout:5));secondName.click();secondName.typeText("duplicate TRIAL")
        model.click();model.typeText("custom-model")
        url.click();url.typeText("https://api.openai.com/v1/")
        app.buttons["settings.model.confirm"].click()
        let duplicateError=app.staticTexts["settings.model.sheet.error"]
        XCTAssertTrue(duplicateError.waitForExistence(timeout:5))
        XCTAssertTrue((duplicateError.value as? String ?? duplicateError.label).contains("same name and effort"))
        app.buttons["settings.model.cancel"].click()
        app.buttons["settings.cancel"].click()
    }

    // MARK: - Settings entry localization (SET-06)

    func testSingleLocalizedSettingsCommandAndShortcut() throws {
        let report=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-menu-\(UUID()).json")
        let start=report.appendingPathExtension("start")
        defer{try?FileManager.default.removeItem(at:report);try?FileManager.default.removeItem(at:start)}
        launch(["--menu-report",report.path,"--menu-report-start",start.path])
        XCTAssertTrue(app.buttons["new.tab"].waitForExistence(timeout:5))
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        try Data().write(to:start,options:.atomic)
        let done=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in FileManager.default.fileExists(atPath:report.path)},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:10),.completed)
        let data=try Data(contentsOf:report)
        let reportJSON=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        // The native app menu contains exactly one Settings command with
        // Command-comma, in both reader- and Settings-focus states.
        let items=try XCTUnwrap(reportJSON["appMenuItems"] as? [[String:Any]])
        let settingsItems=items.filter{($0["title"] as? String ?? "").hasPrefix("Settings")}
        XCTAssertEqual(settingsItems.count,1)
        XCTAssertEqual(settingsItems.first?["key"] as? String,",")
        // The open settings window's title is localized consistently.
        let titles=try XCTUnwrap(reportJSON["settingsWindowTitles"] as? [String])
        XCTAssertTrue(titles.contains("Settings"))
        // ⌘, focuses the same single Settings window.
        XCTAssertEqual(app.windows.matching(NSPredicate(format:"identifier == %@","Bipara.Settings")).count,1)
        app.typeKey(",",modifierFlags:.command)
        XCTAssertEqual(app.windows.matching(NSPredicate(format:"identifier == %@","Bipara.Settings")).count,1)
        XCTAssertTrue(app.buttons["settings.save"].exists)
        capture("settings-entry-en")
    }

    func testLanguageSwitchUpdatesMenuAndTitleInPlaceBothDirections() throws {
        // English → Simplified Chinese through the running app's picker,
        // saving, and verifying the actual native menu label and window
        // title update in place; an edited settings draft survives the
        // language change.
        let report1=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-menu-sw1-\(UUID()).json")
        let start1=report1.appendingPathExtension("start")
        defer{try?FileManager.default.removeItem(at:report1);try?FileManager.default.removeItem(at:start1)}
        launch(["--menu-report",report1.path,"--menu-report-start",start1.path])
        XCTAssertTrue(app.buttons["new.tab"].waitForExistence(timeout:5))
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        // An edited draft value must survive the language change and Save.
        app.buttons["settings.model.row"].firstMatch.click()
        app.buttons["settings.models.edit"].click()
        let model=app.textFields["settings.model.id"]
        XCTAssertTrue(model.waitForExistence(timeout:5));model.click()
        model.typeKey("a",modifierFlags:.command);model.typeText("gpt-6-luna-edited")
        app.buttons["settings.model.confirm"].click()
        let language=app.popUpButtons["settings.language"]
        XCTAssertTrue(language.waitForExistence(timeout:5));language.click()
        app.menuItems["简体中文"].firstMatch.click()
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)
        app.buttons["settings.save"].click()
        XCTAssertTrue(app.buttons["settings.model.row"].firstMatch.waitForExistence(timeout:5))
        try Data().write(to:start1,options:.atomic)
        let done1=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in FileManager.default.fileExists(atPath:report1.path)},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[done1],timeout:10),.completed)
        let json1=try XCTUnwrap(JSONSerialization.jsonObject(with:try Data(contentsOf:report1)) as? [String:Any])
        let items1=try XCTUnwrap(json1["appMenuItems"] as? [[String:Any]])
        XCTAssertEqual(items1.filter{($0["title"] as? String ?? "").hasPrefix("设置")}.count,1)
        XCTAssertEqual(items1.filter{($0["title"] as? String ?? "").hasPrefix("Settings")}.count,0)
        XCTAssertEqual(try XCTUnwrap(json1["settingsWindowTitles"] as? [String]).filter{$0 == "设置"}.count,1)
        // The edited draft value survived the switch and the save.
        app.buttons["settings.model.row"].firstMatch.click()
        app.buttons["settings.models.edit"].click()
        let reopened=app.textFields["settings.model.id"]
        XCTAssertTrue(reopened.waitForExistence(timeout:5))
        XCTAssertTrue((reopened.value as? String)?.contains("gpt-6-luna-edited") == true)
        app.buttons["settings.model.cancel"].click()
        app.windows["Bipara.Settings"].buttons[XCUIIdentifierCloseWindow].click()
        app.terminate()

        // Simplified Chinese → English: the same native surfaces update
        // in the opposite direction.
        let report2=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-menu-sw2-\(UUID()).json")
        let start2=report2.appendingPathExtension("start")
        defer{try?FileManager.default.removeItem(at:report2);try?FileManager.default.removeItem(at:start2)}
        launch(["--language","zh-Hans","--menu-report",report2.path,"--menu-report-start",start2.path])
        XCTAssertTrue(app.buttons["new.tab"].waitForExistence(timeout:5))
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout:5))
        let picker=app.popUpButtons["settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout:5));picker.click()
        app.menuItems["English"].firstMatch.click()
        app.buttons["settings.save"].click()
        XCTAssertTrue(app.buttons["settings.model.row"].firstMatch.waitForExistence(timeout:5))
        try Data().write(to:start2,options:.atomic)
        let done2=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in FileManager.default.fileExists(atPath:report2.path)},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[done2],timeout:10),.completed)
        let json2=try XCTUnwrap(JSONSerialization.jsonObject(with:try Data(contentsOf:report2)) as? [String:Any])
        let items2=try XCTUnwrap(json2["appMenuItems"] as? [[String:Any]])
        XCTAssertEqual(items2.filter{($0["title"] as? String ?? "").hasPrefix("Settings")}.count,1)
        XCTAssertEqual(items2.filter{($0["title"] as? String ?? "").hasPrefix("设置")}.count,0)
        XCTAssertEqual(try XCTUnwrap(json2["settingsWindowTitles"] as? [String]).filter{$0 == "Settings"}.count,1)
    }


    /// Selects the first configured-model row and opens Edit. Early clicks
    /// occasionally land before SwiftUI registers the row button; the
    /// selection is verified through the Edit button's enabled state and
    /// retried.
    private func selectFirstRowAndOpenEditor() {
        let row = app.buttons["settings.model.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let edit = app.buttons["settings.models.edit"]
        for _ in 0..<3 {
            let hitDeadline = Date().addingTimeInterval(3)
            while !row.isHittable && Date() < hitDeadline { Thread.sleep(forTimeInterval: 0.15) }
            row.click()
            let enableDeadline = Date().addingTimeInterval(2)
            while !edit.isEnabled && Date() < enableDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if edit.isEnabled { break }
        }
        XCTAssertTrue(edit.isEnabled)
        edit.click()
    }

    // MARK: - Native correspondence and selection regressions

    func testReopenedEditorCancelKeyCannotRetainKeyAtChangedEndpoint() {
        // N1 native sequence with a real stored key: commit a key at the
        // seeded endpoint, change the endpoint to B via the sheet, reopen
        // the editor, Cancel key, cancel the sheet, Save, and prove the
        // old key did not travel to B.
        launch();app.typeKey(",",modifierFlags:.command)
        // Seed: store a key for the first configuration and Save.
        selectFirstRowAndOpenEditor()
        var keyField=app.secureTextFields["settings.model.key.field"]
        if !keyField.waitForExistence(timeout:2) {
            app.buttons["settings.model.key.replace"].firstMatch.click()
            keyField=app.secureTextFields["settings.model.key.field"]
        }
        XCTAssertTrue(keyField.waitForExistence(timeout:3))
        keyField.click();keyField.typeText("NATIVE_UI_KEY")
        app.buttons["settings.model.confirm"].click()
        app.buttons["settings.save"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        // Edit 1: change the endpoint A -> B and confirm.
        selectFirstRowAndOpenEditor()
        let url=app.textFields["settings.model.url"]
        XCTAssertTrue(url.waitForExistence(timeout:5))
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText("https://gateway.example.com/v1/")
        app.buttons["settings.model.confirm"].click()
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)
        // Edit 2 (reopened): the draft has staged the key deletion.
        selectFirstRowAndOpenEditor()
        XCTAssertTrue(url.waitForExistence(timeout:5))
        let cancelKey=app.buttons["settings.model.key.cancel"].firstMatch
        XCTAssertTrue(cancelKey.waitForExistence(timeout:5))
        cancelKey.click()
        app.buttons["settings.model.cancel"].click()
        // Save commits B; the transaction deletes the old key.
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)
        app.buttons["settings.save"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        // Reopening the editor at B shows no key is set for the endpoint.
        selectFirstRowAndOpenEditor()
        XCTAssertTrue(url.waitForExistence(timeout:5))
        let noKey=app.staticTexts["No API key"]
        XCTAssertTrue(noKey.waitForExistence(timeout:5))
        app.buttons["settings.model.cancel"].click()
        app.buttons["settings.cancel"].click()
    }

    func testReopenedEditorPreservesReplacementAndAutomaticallyRestoresKey() {
        launch();app.typeKey(",",modifierFlags:.command)
        selectFirstRowAndOpenEditor()
        let url = app.textFields["settings.model.url"]
        let originalURL = url.value as! String
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText("https://gateway.example.com/v1/")
        app.buttons["Enter key"].click()
        let field = app.secureTextFields["settings.model.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout:5));field.click();field.typeText("SYNTHETIC_UI_KEY_B")
        app.buttons["settings.model.confirm"].click()
        selectFirstRowAndOpenEditor()
        XCTAssertTrue(app.staticTexts["API key set"].waitForExistence(timeout:5))
        let name = app.textFields["settings.model.name"]
        name.click();name.typeKey("a",modifierFlags:.command);name.typeText("Renamed key entry")
        app.buttons["settings.model.confirm"].click()
        app.buttons["settings.save"].click()
        selectFirstRowAndOpenEditor()
        XCTAssertTrue(app.staticTexts["API key set"].waitForExistence(timeout:5))
        // B is now committed. A second two-sheet round trip B -> A -> B
        // automatically restores its key, without any Cancel-key action.
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText(originalURL)
        app.buttons["settings.model.confirm"].click()
        selectFirstRowAndOpenEditor()
        url.click();url.typeKey("a",modifierFlags:.command);url.typeText("https://gateway.example.com/v1/")
        XCTAssertTrue(app.staticTexts["API key set"].waitForExistence(timeout:5))
        app.buttons["settings.model.confirm"].click()
        // The round trip leaves no changes; closing/reopening proves the
        // committed credential remains present after all sheet actions.
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        selectFirstRowAndOpenEditor()
        XCTAssertTrue(app.staticTexts["API key set"].waitForExistence(timeout:5))
        app.buttons["settings.model.cancel"].click()
    }

    func testAddWithTypedKeyCommitsThroughRealInput() {
        // N3 native sequence: type into the Add sheet's real SecureField,
        // confirm Add, Save, and prove the key is stored for the new
        // configuration; canceling the sheet discards a typed key.
        launch();app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.models.add"].waitForExistence(timeout:5))
        // First: canceling Add discards a typed key.
        app.buttons["settings.models.add"].click()
        var field=app.secureTextFields["settings.model.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout:5));field.click();field.typeText("DISCARDED_UI_KEY")
        app.buttons["settings.model.cancel"].click()
        XCTAssertTrue(app.buttons["settings.models.add"].waitForExistence(timeout:5))
        app.buttons["settings.models.add"].click()
        let model=app.textFields["settings.model.id"]
        XCTAssertTrue(model.waitForExistence(timeout:5));model.click();model.typeText("custom-model")
        let url=app.textFields["settings.model.url"]
        url.click();url.typeText("https://gateway.example.com/v1/")
        field=app.secureTextFields["settings.model.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout:5));field.click();field.typeText("TYPED_UI_KEY")
        let name=app.textFields["settings.model.name"]
        name.click();name.typeText("Typed key entry")
        app.buttons["settings.model.confirm"].click()
        app.buttons["settings.save"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        // The new entry exists and reports a stored key when edited.
        let rows=app.buttons.matching(NSPredicate(format:"identifier == %@","settings.model.row"))
        let rowDeadline=Date().addingTimeInterval(6)
        while rows.count < 3 && Date() < rowDeadline { Thread.sleep(forTimeInterval:0.15) }
        XCTAssertEqual(rows.count,3)
        rows.element(boundBy:2).click()
        app.buttons["settings.models.edit"].click()
        let keySet=app.staticTexts["API key set"]
        XCTAssertTrue(keySet.waitForExistence(timeout:5))
        app.buttons["settings.model.cancel"].click()
        app.buttons["settings.cancel"].click()
    }

    func testEffortSelectionInEditorSheet() {
        // Every model has the same four explicit effort choices.
        launch();app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(app.buttons["settings.models.add"].waitForExistence(timeout:5))
        app.buttons["settings.models.add"].click()
        // The blank Add sheet defaults to Low; all four choices are enabled.
        let effort=app.popUpButtons["settings.model.effort"]
        XCTAssertTrue(effort.waitForExistence(timeout:5))
        XCTAssertTrue(effort.isEnabled)
        XCTAssertTrue((effort.value as? String)?.contains("Low") == true)
        effort.click()
        app.menuItems["High"].firstMatch.click()
        XCTAssertTrue((app.popUpButtons["settings.model.effort"].value as? String)?.contains("High") == true)
        app.buttons["settings.model.cancel"].click()
        app.buttons["settings.cancel"].click()
    }
    func testCustomModelEditorFieldsAndProtocols() {
        launch(); app.typeKey(",", modifierFlags: .command)
        app.buttons["settings.models.add"].click()
        let name = app.textFields["settings.model.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let model = app.textFields["settings.model.id"]
        let url = app.textFields["settings.model.url"]
        let api = app.popUpButtons["settings.model.protocol"]
        let key = app.secureTextFields["settings.model.key.field"]
        for field in [name, model, url, key] { XCTAssertEqual(field.value as? String, "") }
        for id in ["preset", "vendor", "catalog", "advanced", "endpoint", "authentication", "output", "translationTokens", "alignmentTokens", "temperature", "parameters", "headers"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "settings.model.\(id)").firstMatch.exists)
        }
        let fields = [name, api, model, app.popUpButtons["settings.model.effort"], url, key]
        for (first, second) in zip(fields, fields.dropFirst()) { XCTAssertLessThan(first.frame.midY, second.frame.midY) }
        capture("settings-custom-blank")
        api.click(); app.menuItems["Anthropic"].firstMatch.click()
        for field in [name, model, url, key] { XCTAssertEqual(field.value as? String, "") }
        api.click(); app.menuItems["OpenAI"].firstMatch.click()
        model.click(); model.typeText("unknown-model-2027")
        url.click(); url.typeText("https://gateway.example.com/api/")
        let effort = app.popUpButtons["settings.model.effort"]
        effort.click()
        for name in ["Off", "Low", "Medium", "High"] { XCTAssertTrue(app.menuItems[name].firstMatch.exists) }
        XCTAssertFalse(app.menuItems["Default"].exists)
        app.menuItems["Medium"].firstMatch.click()
        api.click(); app.menuItems["Anthropic"].firstMatch.click()
        XCTAssertTrue((effort.value as? String)?.contains("Medium") == true)
        XCTAssertFalse(app.staticTexts["API type"].exists)
        XCTAssertFalse(app.textFields["settings.model.endpoint"].exists)
        XCTAssertEqual(model.value as? String, "unknown-model-2027")
        XCTAssertEqual(url.value as? String, "https://gateway.example.com/api/")
        name.click(); name.typeText("Custom gateway")
        app.buttons["settings.model.confirm"].click()
        app.buttons["settings.save"].click()
        let rows = app.buttons.matching(NSPredicate(format: "identifier == %@", "settings.model.row"))
        XCTAssertEqual(rows.count, 3)
        rows.element(boundBy: 2).click(); app.buttons["settings.models.edit"].click()
        XCTAssertEqual(app.textFields["settings.model.name"].value as? String, "Custom gateway")
        XCTAssertEqual(app.textFields["settings.model.url"].value as? String, "https://gateway.example.com/api/")
        XCTAssertEqual(app.textFields["settings.model.id"].value as? String, "unknown-model-2027")
        XCTAssertTrue((app.popUpButtons["settings.model.protocol"].value as? String)?.contains("Anthropic") == true)
        XCTAssertTrue((app.popUpButtons["settings.model.effort"].value as? String)?.contains("Medium") == true)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Custom model configuration"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["settings.model.cancel"].click(); app.buttons["settings.cancel"].click()
    }

    func testLegacyEditorRequiresExplicitEffortAndCancelPreservesEntry() {
        launch(["--legacy-models"]); app.typeKey(",", modifierFlags: .command)
        selectFirstRowAndOpenEditor()
        app.buttons["settings.model.confirm"].click()
        XCTAssertTrue(app.staticTexts["settings.model.sheet.error"].waitForExistence(timeout: 3))
        app.buttons["settings.model.cancel"].click()
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)
        selectFirstRowAndOpenEditor()
        let effort = app.popUpButtons["settings.model.effort"]
        XCTAssertTrue((effort.value as? String)?.contains("Choose an effort") == true)
        effort.click(); app.menuItems["Low"].firstMatch.click()
        app.buttons["settings.model.confirm"].click()
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)
        app.buttons["settings.cancel"].click()
    }

    func testChineseDarkModelEditorLayout() {
        launch(["--language", "zh-Hans", "--appearance", "dark"])
        app.typeKey(",", modifierFlags: .command)
        app.buttons["settings.models.add"].click()
        XCTAssertTrue(app.popUpButtons["settings.model.protocol"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["接口协议"].exists)
        capture("settings-open-chinese-dark")
        app.buttons["settings.model.cancel"].click()
    }

}

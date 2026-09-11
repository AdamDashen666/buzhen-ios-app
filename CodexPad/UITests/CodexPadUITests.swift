import XCTest

@MainActor
final class CodexPadUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLandscapeEditorUnsavedProtectionAndSave() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(["--ui-fixture"])
        let readme = app.buttons["README.md"].firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 20))
        readme.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("\n测试编辑")
        app.buttons["主程序.swift"].firstMatch.tap()
        XCTAssertTrue(app.buttons["保存并继续"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue((editor.value as? String)?.contains("测试编辑") == true)
        app.buttons["保存"].firstMatch.tap()
        app.buttons["主程序.swift"].firstMatch.tap()
        XCTAssertTrue((editor.value as? String)?.contains("import Foundation") == true)
        screenshot("landscape-workspace", app: app)
    }

    func testPortraitChineseSettingsAndDarkMode() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--ui-fixture", "--ui-dark"])
        XCTAssertTrue(app.tabBars.buttons["项目"].waitForExistence(timeout: 15))
        app.tabBars.buttons["项目"].tap()
        app.buttons["项目菜单"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.secureTextFields["api-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["保存并连接"].exists)
        XCTAssertFalse(app.buttons["Apply"].exists)
        XCTAssertFalse(app.staticTexts["Settings"].exists)
        screenshot("portrait-settings-dark", app: app)
        app.buttons["完成"].tap()
        app.tabBars.buttons["智能助手"].tap()
        screenshot("portrait-assistant-dark", app: app)
    }

    func testRealDocumentPickerOpensLocalFolder() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(["--ui-picker"])
        let open = app.buttons["open-folder"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        screenshot("document-picker", app: app)
        let local = app.staticTexts["我的 iPad"].firstMatch
        if !local.waitForExistence(timeout: 5) {
            let browse = app.buttons["浏览"].firstMatch
            if browse.exists { browse.tap() }
        }
        guard local.waitForExistence(timeout: 5) else {
            cancel.tap()
            throw XCTSkip("此模拟器未提供本地 Files 文档提供器；外部文件夹授权仍需真机验证。")
        }
        local.tap()
        let container = app.staticTexts["CodexPad"].firstMatch
        guard container.waitForExistence(timeout: 8) else {
            screenshot("document-provider-container-unavailable", app: app)
            throw XCTSkip("模拟器未注册 App 的文档容器，文件提供器验收需真机。")
        }
        container.tap()
        let folder = app.staticTexts["示例项目"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        app.buttons["打开"].firstMatch.tap()
        XCTAssertTrue(app.buttons["README.md"].firstMatch.waitForExistence(timeout: 20))
        screenshot("picker-opened-project", app: app)
    }
}

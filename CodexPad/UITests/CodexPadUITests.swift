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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLandscapeEditorUnsavedProtectionAndSave() throws {
        let app = launch(["--ui-fixture"])
        XCUIDevice.shared.orientation = .landscapeLeft
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
        let app = launch(["--ui-fixture", "--ui-dark"])
        XCUIDevice.shared.orientation = .portrait
        screenshot("portrait-navigation", app: app)
        let projects = app.buttons["项目"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        app.buttons["项目菜单"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.secureTextFields["api-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["保存并连接"].exists)
        XCTAssertFalse(app.buttons["Apply"].exists)
        XCTAssertFalse(app.staticTexts["Settings"].exists)
        screenshot("portrait-settings-dark", app: app)
        app.buttons["完成"].tap()
        app.buttons["智能助手"].firstMatch.tap()
        screenshot("portrait-assistant-dark", app: app)
    }

    func testExternalDocumentPickerOpensWritesAndRestoresFolder() throws {
        let fixture = XCUIApplication(bundleIdentifier: "com.example.CodexPad.FolderProviderFixture")
        fixture.launch()
        XCTAssertTrue(fixture.staticTexts["外部目录已准备"].waitForExistence(timeout: 20))
        screenshot("external-fixture-ready", app: fixture)
        fixture.terminate()
        let app = launch(["--ui-picker"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let open = app.buttons["open-folder"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        screenshot("document-picker", app: app)
        let local = app.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES[c] %@", ".*(我的|On My).*iPad.*")
        ).firstMatch
        if !local.waitForExistence(timeout: 5) {
            let browse = app.buttons["浏览"].firstMatch
            if browse.exists { browse.tap() }
        }
        XCTAssertTrue(local.waitForExistence(timeout: 5), "必须存在本地文档提供器")
        local.tap()
        let container = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "授权测试源")).firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 15), "CI 必须预先安装并启动独立测试 App")
        container.tap()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "外部示例项目")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        app.buttons["打开"].firstMatch.tap()
        let marker = app.buttons["外部标记.txt"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 35))
        marker.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("\nexternal-saved")
        app.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已保存"].firstMatch.waitForExistence(timeout: 10))
        screenshot("external-picker-opened-and-saved", app: app)
        app.terminate()
        let restored = launch()
        let restoredMarker = restored.buttons["外部标记.txt"].firstMatch
        XCTAssertTrue(restoredMarker.waitForExistence(timeout: 35), "重启后必须从书签恢复外部目录")
        restoredMarker.tap()
        let restoredEditor = restored.textViews.firstMatch
        XCTAssertTrue(restoredEditor.waitForExistence(timeout: 10))
        XCTAssertTrue((restoredEditor.value as? String)?.contains("external-saved") == true)
        screenshot("external-bookmark-restored", app: restored)
    }

    func testPickerCancellationAndReopeningAcrossRotation() throws {
        let app = launch(["--ui-picker"])
        XCUIDevice.shared.orientation = .landscapeLeft
        for attempt in 0..<3 {
            let open = app.buttons["open-folder"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            open.tap()
            let cancel = app.buttons["取消"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15))
            XCUIDevice.shared.orientation = attempt == 1 ? .portrait : .landscapeLeft
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 10), "取消后必须能够再次打开选择器")
            XCTAssertFalse(app.alerts.firstMatch.exists, "主动取消不应显示失败警告")
        }
        app.buttons["项目菜单"].tap()
        app.buttons["设置"].tap()
        let records = app.buttons["查看打开记录"].firstMatch
        if !records.isHittable { app.swipeUp() }
        XCTAssertTrue(records.waitForExistence(timeout: 5))
        records.tap()
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "用户取消选择文件夹")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "取消结果必须到达工作区诊断")
        screenshot("picker-reopened-after-cancellation", app: app)
    }
}

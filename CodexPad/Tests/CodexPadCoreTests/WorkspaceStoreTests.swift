import XCTest
@testable import CodexPadCore

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testOpenImmediatelyLoadsAndRestoresBookmark() async throws {
        let suite = "CodexPad.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("你好.txt"))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        store.openFolder(root)
        XCTAssertTrue(store.isOpening)
        await store.waitForOpening()
        XCTAssertFalse(store.isOpening)
        XCTAssertEqual(store.entries.map(\.name), ["你好.txt"])
        XCTAssertNil(store.errorMessage)
        let restored = WorkspaceStore(defaults: defaults)
        restored.restoreRecentProject()
        await restored.waitForOpening()
        XCTAssertEqual(restored.entries.map(\.name), ["你好.txt"])
        store.closeFolder()
        restored.closeFolder()
    }

    func testUnsavedProtectionAndDeletedFileCleanup() async throws {
        let suite = "CodexPad.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try Data("a".utf8).write(to: root.appendingPathComponent("a"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b"))
        let store = WorkspaceStore(defaults: defaults)
        store.openFolder(root)
        await store.waitForOpening()
        try await store.openFile("a")
        store.editorText = "unsaved"
        do { try await store.openFile("b"); XCTFail("Must protect edits") } catch {}
        store.closeFolder()
        XCTAssertNotNil(store.session)
        XCTAssertEqual(store.editorText, "unsaved")
        try await store.saveEditor()
        XCTAssertFalse(store.isDirty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        await store.refreshSelectedFileIfUnmodified()
        XCTAssertNil(store.selectedPath)
        XCTAssertNotNil(store.errorMessage)
        store.closeFolder()
    }

    func testInvalidBookmarkIsNotSilentlyDiscarded() async {
        let suite = "CodexPad.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "workspace.securityScopedBookmark")
        let store = WorkspaceStore(defaults: defaults)
        store.restoreRecentProject()
        await store.waitForOpening()
        XCTAssertTrue(store.needsAuthorization)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(defaults.data(forKey: "workspace.securityScopedBookmark"))
    }

    func testCancelledOpenCannotPublishOverNewProjectAndDiagnosticsPersist() async throws {
        let suite = "CodexPad.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: root.appendingPathComponent("当前.txt"))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        store.openFolder(root.appendingPathComponent("不存在"))
        store.cancelOpening()
        store.openFolder(root)
        await store.waitForOpening()
        XCTAssertEqual(store.entries.map(\.name), ["当前.txt"])
        XCTAssertNil(store.openingFailure)
        XCTAssertFalse(store.needsAuthorization)
        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(restored.diagnosticsText.contains("项目已打开"))
        XCTAssertFalse(restored.diagnosticsText.contains(root.path))
        store.closeFolder()
    }
}

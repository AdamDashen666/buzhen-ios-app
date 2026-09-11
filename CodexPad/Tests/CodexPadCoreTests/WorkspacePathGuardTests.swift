import XCTest
@testable import CodexPadCore

final class WorkspacePathGuardTests: XCTestCase {
    func testRejectsTraversalAndAbsolutePaths() throws {
        XCTAssertThrowsError(try WorkspacePathGuard.normalize("../Secrets.txt"))
        XCTAssertThrowsError(try WorkspacePathGuard.normalize("Sources/../../Secrets.txt"))
        XCTAssertThrowsError(try WorkspacePathGuard.normalize("/etc/passwd"))
        XCTAssertThrowsError(try WorkspacePathGuard.normalize("C:\\Windows\\system.ini"))
    }

    func testNormalizesSafeRelativePath() throws {
        XCTAssertEqual(try WorkspacePathGuard.normalize("Sources/App/Main.swift"), "Sources/App/Main.swift")
        XCTAssertEqual(try WorkspacePathGuard.normalize("."), "")
    }
}

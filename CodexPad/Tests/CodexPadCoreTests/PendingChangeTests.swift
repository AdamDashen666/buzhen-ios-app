import XCTest
@testable import CodexPadCore

final class PendingChangeTests: XCTestCase {
    func testWriteChangeProducesDiff() {
        let change = PendingChange(kind: .write, path: "A.swift", originalText: "let a = 1\n", proposedText: "let a = 2\n")
        XCTAssertTrue(change.diff.contains("-let a = 1"))
        XCTAssertTrue(change.diff.contains("+let a = 2"))
    }

    func testEmptyAndBinaryMutationsAreNotReportedAsNoChange() {
        XCTAssertTrue(PendingChange(kind: .create, path: "empty", proposedText: "").diff.contains("新建空文件"))
        XCTAssertTrue(PendingChange(kind: .delete, path: "empty", originalText: "").diff.contains("删除空文件"))
        XCTAssertTrue(PendingChange(kind: .delete, path: "image.png").diff.contains("没有文本预览"))
    }
}

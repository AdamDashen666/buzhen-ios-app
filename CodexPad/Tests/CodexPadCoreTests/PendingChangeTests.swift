import XCTest
@testable import CodexPadCore

final class PendingChangeTests: XCTestCase {
    func testWriteChangeProducesDiff() {
        let change = PendingChange(kind: .write, path: "A.swift", originalText: "let a = 1\n", proposedText: "let a = 2\n")
        XCTAssertTrue(change.diff.contains("-let a = 1"))
        XCTAssertTrue(change.diff.contains("+let a = 2"))
    }
}

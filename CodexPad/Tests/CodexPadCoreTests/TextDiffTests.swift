import XCTest
@testable import CodexPadCore

final class TextDiffTests: XCTestCase {
    func testUnifiedDiffShowsAddedAndRemovedLines() {
        let diff = TextDiff.unified(old: "one\ntwo\n", new: "one\nthree\n", path: "a.txt")
        XCTAssertTrue(diff.contains("--- a/a.txt"))
        XCTAssertTrue(diff.contains("+++ b/a.txt"))
        XCTAssertTrue(diff.contains("-two"))
        XCTAssertTrue(diff.contains("+three"))
    }
}

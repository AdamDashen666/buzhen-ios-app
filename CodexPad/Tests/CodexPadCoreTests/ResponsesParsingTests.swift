import XCTest
@testable import CodexPadCore

final class ResponsesParsingTests: XCTestCase {
    func testParsesFunctionCallAndAssistantText() throws {
        let json = #"{"id":"resp_1","output":[{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"README.md\"}"},{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: json)
        XCTAssertEqual(response.id, "resp_1")
        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.name, "read_file")
        XCTAssertEqual(response.outputText, "Done")
    }
}

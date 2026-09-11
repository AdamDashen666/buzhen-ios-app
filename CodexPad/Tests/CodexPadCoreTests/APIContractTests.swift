import XCTest
@testable import CodexPadCore

final class APIContractTests: XCTestCase {
    func testBaseURLNormalizationAndCredentialRejection() throws {
        XCTAssertEqual(try OpenAIResponsesClient.normalizedBaseURL(" https://api.openai.com/ ").absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(try OpenAIResponsesClient.normalizedBaseURL("https://example.com/proxy/v1/").path, "/proxy/v1")
        for bad in ["http://example.com", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com/#fragment", ""] {
            XCTAssertThrowsError(try OpenAIResponsesClient.normalizedBaseURL(bad))
        }
    }

    func testStatelessRequestPreservesReasoningAndAllToolOutputs() throws {
        let json = #"{"id":"r","status":"completed","output":[{"type":"reasoning","id":"reason","encrypted_content":"opaque","summary":[]},{"type":"function_call","call_id":"a","name":"read_file","arguments":"{}"},{"type":"function_call","call_id":"b","name":"read_file","arguments":"{}"}]}"#
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(response.functionCalls.count, 2)
        let request = OpenAIResponsesClient.Request(model: "test", input: response.output + [
            .tool(callID: "a", output: "one"), .tool(callID: "b", output: "two")
        ], instructions: "测试", tools: AgentToolCatalog.all)
        let encoded = try JSONEncoder().encode(request)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(value["store"], .bool(false))
        XCTAssertNil(value["previous_response_id"])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("opaque"))
    }

    func testAllRequiredToolsAndChineseErrors() {
        XCTAssertEqual(Set(AgentToolCatalog.all.map(\.name)), Set([
            "list_directory", "read_file", "search_files", "create_file", "write_file",
            "replace_text", "move_file", "rename_file", "delete_file", "create_directory"
        ]))
        for code in [401, 403, 429, 500, 502] {
            let error = OpenAIResponsesClient.APIError.http(code)
            XCTAssertTrue(error.localizedDescription.contains("API"))
            XCTAssertFalse(error.canTryAnotherModel)
        }
    }
}

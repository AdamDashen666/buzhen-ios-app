import XCTest
@testable import CodexPadCore

final class ToolCatalogTests: XCTestCase {
    func testEveryToolUsesStrictObjectSchema() throws {
        for tool in AgentToolCatalog.all {
            XCTAssertEqual(tool.type, "function")
            XCTAssertTrue(tool.strict)
            XCTAssertEqual(tool.parameters.type, "object")
            XCTAssertFalse(tool.parameters.additionalProperties)
            XCTAssertEqual(Set(tool.parameters.required), Set(tool.parameters.properties.keys))
        }
    }

    func testMutationToolsAreMarkedMutating() {
        XCTAssertFalse(AgentToolCatalog.isMutation("read_file"))
        XCTAssertTrue(AgentToolCatalog.isMutation("write_file"))
        XCTAssertTrue(AgentToolCatalog.isMutation("delete_file"))
        XCTAssertTrue(AgentToolCatalog.isMutation("move_file"))
    }
}

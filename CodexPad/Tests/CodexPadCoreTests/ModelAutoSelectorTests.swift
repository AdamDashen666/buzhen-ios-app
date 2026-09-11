import XCTest
@testable import CodexPadCore

final class ModelAutoSelectorTests: XCTestCase {
    func testPrefersNewestSolModel() {
        let ids = ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.5-sol"]
        XCTAssertEqual(ModelAutoSelector.bestModel(from: ids), "gpt-5.6-sol")
    }

    func testPrefersNewerVersionOverOlderPremiumVariant() {
        let ids = ["gpt-5.5-sol", "gpt-5.6-terra"]
        XCTAssertEqual(ModelAutoSelector.bestModel(from: ids), "gpt-5.6-terra")
    }

    func testFiltersNonTextModels() {
        let ids = ["text-embedding-3-large", "gpt-image-2", "gpt-realtime-2", "gpt-5.6-sol"]
        XCTAssertEqual(ModelAutoSelector.bestModel(from: ids), "gpt-5.6-sol")
    }

    func testFallsBackToCodingLookingModel() {
        let ids = ["vendor-audio", "my-coder-model", "my-chat-model"]
        XCTAssertEqual(ModelAutoSelector.bestModel(from: ids), "my-coder-model")
    }

    func testReturnsNilWhenNoUsableModelExists() {
        XCTAssertNil(ModelAutoSelector.bestModel(from: ["text-embedding-3-large", "gpt-image-2"]))
    }

    func testReasoningCapabilityHeuristic() {
        XCTAssertTrue(ModelAutoSelector.supportsReasoning("gpt-5.6-sol"))
        XCTAssertTrue(ModelAutoSelector.supportsReasoning("o4-mini"))
        XCTAssertFalse(ModelAutoSelector.supportsReasoning("gpt-4o"))
    }
}

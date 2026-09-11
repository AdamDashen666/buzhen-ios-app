import XCTest
@testable import CodexPadCore

final class SensitivePathPolicyTests: XCTestCase {
    func testBlocksCommonSecretFilesButNotSourceFiles() {
        XCTAssertTrue(SensitivePathPolicy.isSensitive(".env"))
        XCTAssertTrue(SensitivePathPolicy.isSensitive("Config/.env.production"))
        XCTAssertTrue(SensitivePathPolicy.isSensitive("Keys/AuthKey.p8"))
        XCTAssertTrue(SensitivePathPolicy.isSensitive("certs/dev.p12"))
        XCTAssertTrue(SensitivePathPolicy.isSensitive(".git/config"))
        XCTAssertFalse(SensitivePathPolicy.isSensitive("Sources/App.swift"))
    }
}

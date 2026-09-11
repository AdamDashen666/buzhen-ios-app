import XCTest
@testable import CodexPadCore

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock { Self.handler }
        let (code, body) = callback?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APITransportTests: XCTestCase, @unchecked Sendable {
    private func client() -> OpenAIResponsesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return OpenAIResponsesClient(baseURL: URL(string: "https://example.invalid/v1")!,
                                     apiKey: "test-only", session: URLSession(configuration: config))
    }

    func testHTTPFailureMappingDoesNotEchoSecret() async throws {
        for code in [401, 403, 429, 500, 503] {
            MockProtocol.lock.withLock { MockProtocol.handler = { _ in (code, "secret-provider-echo") } }
            let client = client()
            defer { client.invalidate() }
            do { _ = try await client.listModels(); XCTFail("Expected failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(String(code)))
                XCTAssertFalse(error.localizedDescription.contains("secret-provider-echo"))
            }
        }
    }

    func testInvalidJSONAndUnsupportedModel() async throws {
        MockProtocol.lock.withLock { MockProtocol.handler = { _ in (200, "<html>gateway</html>") } }
        let client = client()
        defer { client.invalidate() }
        do { _ = try await client.listModels(); XCTFail("Expected JSON failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("JSON")) }
        MockProtocol.lock.withLock { MockProtocol.handler = { _ in (200, #"{"id":"r","output":[]}"#) } }
        do { _ = try await client.probe(model: "test"); XCTFail("Expected probe failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("工具")) }
    }

    @MainActor
    func testAutomaticFallbackProbesBeforeCachingAndInvalidatesForNewKey() async throws {
        let suite = "CodexPad.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        defer { try? keychain.deleteAPIKey(); defaults.removePersistentDomain(forName: suite) }
        MockProtocol.lock.withLock {
            MockProtocol.handler = { request in
                if request.url?.lastPathComponent == "models" { return (404, "{}") }
                return (200, #"{"id":"probe","model":"server-model","output":[{"type":"function_call","call_id":"c","name":"codexpad_probe","arguments":"{}"}]}"#)
            }
        }
        let settings = AppSettings(defaults: defaults, keychain: keychain, clientFactory: { url, key in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockProtocol.self]
            return OpenAIResponsesClient(baseURL: url, apiKey: key, session: URLSession(configuration: configuration))
        })
        try await settings.save(key: "test-key-one", base: "https://example.invalid")
        XCTAssertEqual(settings.model, "auto")
        XCTAssertEqual(defaults.stringArray(forKey: "api.verifiedModels"), ["auto"])
        XCTAssertNil(defaults.string(forKey: "api.key"))
        MockProtocol.lock.withLock { MockProtocol.handler = { _ in (401, "{}") } }
        do { try await settings.save(key: "test-key-two", base: "https://example.invalid"); XCTFail("Expected 401") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(try keychain.loadAPIKey(), "test-key-two")
    }
}

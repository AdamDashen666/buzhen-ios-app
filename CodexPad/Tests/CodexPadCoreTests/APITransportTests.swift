import XCTest
@testable import CodexPadCore

final class MockProtocol: URLProtocol, @unchecked Sendable {
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

@MainActor
final class AgentControllerTests: XCTestCase {
    func testBatchReviewAppliesOnlyAcceptedFilesAndRedactsKey() async throws {
        let suite = "CodexPad.AgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? keychain.deleteAPIKey()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        MockProtocol.lock.withLock {
            MockProtocol.handler = { request in
                if request.url?.lastPathComponent == "models" { return (200, #"{"data":[{"id":"my-coder"}]}"#) }
                return (200, #"{"id":"p","output":[{"type":"function_call","call_id":"p","name":"codexpad_probe","arguments":"{}"}]}"#)
            }
        }
        let settings = AppSettings(defaults: defaults, keychain: keychain, clientFactory: { url, key in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockProtocol.self]
            return OpenAIResponsesClient(baseURL: url, apiKey: key, session: URLSession(configuration: config))
        })
        try await settings.save(key: "fixture-secret-key", base: "https://example.invalid")
        let workspace = WorkspaceStore(defaults: defaults)
        workspace.openFolder(root)
        await workspace.waitForOpening()
        let agent = AgentController(workspace: workspace, settings: settings, keychain: keychain)
        MockProtocol.lock.withLock {
            MockProtocol.handler = { _ in
                (200, #"{"id":"r","output":[{"type":"function_call","call_id":"a","name":"create_file","arguments":"{\"path\":\"a.txt\",\"content\":\"first\"}"},{"type":"function_call","call_id":"b","name":"create_file","arguments":"{\"path\":\"b.txt\",\"content\":\"second\"}"}]}"#)
            }
        }
        XCTAssertTrue(agent.send("创建文件 fixture-secret-key"))
        await agent.waitUntilIdle()
        XCTAssertEqual(agent.pendingChanges.count, 2)
        XCTAssertFalse(agent.messages.contains { $0.text.contains("fixture-secret-key") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        let first = try XCTUnwrap(agent.pendingChanges.first)
        agent.review(ids: [first.id], accept: true)
        await agent.waitUntilIdle()
        XCTAssertEqual(agent.pendingChanges.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "first")
        MockProtocol.lock.withLock {
            MockProtocol.handler = { _ in (200, #"{"id":"done","output":[{"type":"message","content":[{"type":"output_text","text":"已完成"}]}]}"#) }
        }
        agent.review(ids: Set(agent.pendingChanges.map(\.id)), accept: false)
        await agent.waitUntilIdle()
        XCTAssertTrue(agent.pendingChanges.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        XCTAssertNil(agent.errorMessage)
        MockProtocol.lock.withLock {
            MockProtocol.handler = { request in
                let body = request.httpBody ?? request.httpBodyStream.map { stream in
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    return data
                } ?? Data()
                let value = try? JSONDecoder().decode(JSONValue.self, from: body)
                if case .array(let input) = value?["input"],
                   input.contains(where: { $0["call_id"] == .string("overflow") && $0["type"] == .string("function_call_output") }) {
                    return (200, #"{"id":"done","output":[{"type":"message","content":[{"type":"output_text","text":"已到末尾"}]}]}"#)
                }
                return (200, #"{"id":"r","output":[{"type":"function_call","call_id":"overflow","name":"read_file","arguments":"{\"path\":\"a.txt\",\"start_line\":\"9223372036854775807\",\"line_count\":\"200\"}"}]}"#)
            }
        }
        agent.newChat()
        XCTAssertTrue(agent.send("读取极大行号"))
        await agent.waitUntilIdle()
        XCTAssertNil(agent.errorMessage)
        XCTAssertTrue(agent.messages.contains { $0.text == "已到末尾" })
        workspace.closeFolder()
    }
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

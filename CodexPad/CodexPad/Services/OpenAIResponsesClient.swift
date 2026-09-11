import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OpenAIResponsesClient: Sendable {
    struct Request: Encodable, Sendable {
        let model: String
        let input: [JSONValue]
        let instructions: String
        let tools: [FunctionTool]
        var toolChoice: String? = nil
        var maxOutputTokens = 8192
        let store = false
        let parallelToolCalls = true
        let include = ["reasoning.encrypted_content"]

        enum CodingKeys: String, CodingKey {
            case model, input, instructions, tools, store, include
            case toolChoice = "tool_choice"
            case parallelToolCalls = "parallel_tool_calls"
            case maxOutputTokens = "max_output_tokens"
        }
    }

    let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func invalidate() { session.invalidateAndCancel() }

    static func normalizedBaseURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw APIError.httpsRequired }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = parts.path.isEmpty ? "/v1" : "/\(parts.path)"
        guard let url = parts.url else { throw APIError.httpsRequired }
        return url
    }

    func listModels() async throws -> [String] {
        struct Envelope: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let data = try await perform(path: "models", body: nil)
        do { return try JSONDecoder().decode(Envelope.self, from: data).data.map(\.id) }
        catch { throw APIError.invalidJSON }
    }

    func create(request: Request) async throws -> ResponsesEnvelope {
        let data = try await perform(path: "responses", body: JSONEncoder().encode(request))
        do {
            let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
            if let status = response.status, status != "completed" { throw APIError.incomplete }
            return response
        } catch let error as APIError { throw error }
        catch { throw APIError.invalidJSON }
    }

    func probe(model: String) async throws -> String {
        let tool = FunctionTool(name: "codexpad_probe", description: "确认工具调用能力。", properties: [:])
        let response = try await create(request: Request(
            model: model, input: [.user("调用 codexpad_probe。")], instructions: "只调用指定工具。",
            tools: [tool], toolChoice: "required", maxOutputTokens: 256
        ))
        guard response.functionCalls.contains(where: { $0.name == "codexpad_probe" }) else { throw APIError.unsupportedModel }
        return response.model ?? model
    }

    private func perform(path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = body == nil ? 25 : 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                // Never echo a provider's error body: it may include credentials or HTML.
                throw APIError.http(http.statusCode)
            }
            if response.expectedContentLength > 4 * 1024 * 1024 { throw APIError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4 * 1024 * 1024 { throw APIError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.network(error.code)
        }
    }

    enum APIError: LocalizedError {
        case httpsRequired, invalidResponse, invalidJSON, incomplete, unsupportedModel, responseTooLarge
        case network(URLError.Code), http(Int)

        var canTryAnotherModel: Bool {
            switch self {
            case .http(400), .http(404), .http(422), .unsupportedModel, .incomplete: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .httpsRequired: return "API 地址必须是有效的 HTTPS 地址，不能含账号、密码、查询参数或片段。"
            case .invalidResponse: return "API 返回了无法识别的网络响应。"
            case .invalidJSON: return "API 返回的 JSON 格式不兼容，或网关返回了网页。"
            case .incomplete: return "模型输出未完成，可能达到输出或推理上限。未执行本次响应中的工具。"
            case .unsupportedModel: return "此模型未通过 Responses 工具调用验证。"
            case .responseTooLarge: return "API 响应超过安全大小上限，已停止读取。"
            case .network(let code):
                return code == .timedOut ? "API 请求超时，请稍后重试。" : "网络连接失败，请检查当前网络与 API 地址。"
            case .http(let code):
                switch code {
                case 401: return "API Key 无效或已撤销（HTTP 401）。"
                case 403: return "API 权限不足或接口被限制（HTTP 403）。"
                case 429: return "API 请求被限流或额度不足（HTTP 429），请稍后重试并检查额度。"
                case 500...599: return "API 服务端异常（HTTP \(code)），请稍后重试。"
                case 300...399: return "API 地址发生重定向，出于密钥安全已阻止。请填写最终 HTTPS 地址。"
                case 404: return "API 接口或模型不存在（HTTP 404）。"
                default: return "API 请求失败（HTTP \(code)），请确认服务支持 Responses 与工具调用。"
                }
            }
        }
    }
}

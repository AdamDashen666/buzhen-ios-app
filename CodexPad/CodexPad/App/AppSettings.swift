import Foundation
import SwiftUI
import CryptoKit

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var baseURL: String
    @Published private(set) var model = ""
    @Published private(set) var modelStatus = "尚未检测"
    @Published private(set) var isDetecting = false
    @Published private(set) var hasKey = false
    @Published var autoApply: Bool { didSet { defaults.set(autoApply, forKey: "agent.autoApply") } }
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let clientFactory: @Sendable (URL, String) -> OpenAIResponsesClient
    private var detectionTask: Task<String, Error>?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(),
         clientFactory: @escaping @Sendable (URL, String) -> OpenAIResponsesClient = { OpenAIResponsesClient(baseURL: $0, apiKey: $1) }) {
        self.defaults = defaults
        self.keychain = keychain
        self.clientFactory = clientFactory
        baseURL = defaults.string(forKey: "api.baseURL") ?? "https://api.openai.com/v1"
        autoApply = defaults.bool(forKey: "agent.autoApply")
        hasKey = (try? keychain.loadAPIKey()) != nil
    }

    var modelDisplayName: String { model.isEmpty ? "自动检测模型" : model }
    var configurationID: UUID { generation }

    func save(key: String, base: String) async throws {
        let normalized = try OpenAIResponsesClient.normalizedBaseURL(base)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.missingKey }
        try keychain.saveAPIKey(trimmed)
        generation = UUID()
        detectionTask?.cancel()
        detectionTask = nil
        isDetecting = false
        model = ""
        baseURL = normalized.absoluteString
        defaults.set(baseURL, forKey: "api.baseURL")
        hasKey = true
        _ = try await resolveModel(force: true)
    }

    func removeKey() throws {
        try keychain.deleteAPIKey()
        generation = UUID()
        detectionTask?.cancel()
        detectionTask = nil
        isDetecting = false
        model = ""
        modelStatus = "API Key 已移除"
        hasKey = false
        defaults.removeObject(forKey: "api.verifiedModels")
        defaults.removeObject(forKey: "api.verifiedFingerprint")
        defaults.removeObject(forKey: "api.model")
    }

    func client() throws -> OpenAIResponsesClient {
        guard let key = try keychain.loadAPIKey(), !key.isEmpty else { throw SettingsError.missingKey }
        return clientFactory(try OpenAIResponsesClient.normalizedBaseURL(baseURL), key)
    }

    func refreshIfNeeded() async {
        guard hasKey else { return }
        do { _ = try await resolveModel() }
        catch is CancellationError {}
        catch { modelStatus = error.localizedDescription }
    }

    func resolveModel(force: Bool = false) async throws -> String {
        if let detectionTask { return try await detectionTask.value }
        guard let key = try keychain.loadAPIKey(), !key.isEmpty else { throw SettingsError.missingKey }
        let url = try OpenAIResponsesClient.normalizedBaseURL(baseURL)
        let fingerprint = SHA256.hash(data: Data("\(url.absoluteString)\n\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        let matches = defaults.string(forKey: "api.verifiedFingerprint") == fingerprint
        let cached = matches ? (defaults.stringArray(forKey: "api.verifiedModels") ?? []) : []
        let last = defaults.object(forKey: "api.detectedAt") as? Date ?? .distantPast
        if !force, Date().timeIntervalSince(last) < 24 * 3600, let first = cached.first {
            model = first
            modelStatus = "模型已自动就绪"
            return first
        }
        let current = generation
        isDetecting = true
        modelStatus = "正在读取模型并验证工具调用…"
        let factory = clientFactory
        let task = Task<String, Error> { [weak self] in
            let client = factory(url, key)
            defer { client.invalidate() }
            var listError: Error?
            var candidates: [String] = []
            do { candidates = ModelAutoSelector.rankedModels(from: try await client.listModels()) }
            catch is CancellationError { throw CancellationError() }
            catch { listError = error }
            if let error = listError as? OpenAIResponsesClient.APIError {
                switch error {
                case .http(401), .http(429), .http(500...599), .network: throw error
                default: break
                }
            }
            if candidates.isEmpty {
                // Bootstrap aliases only when discovery is unavailable. None is cached
                // until a real Responses function-call probe succeeds.
                candidates = cached + (url.host == "api.openai.com"
                    ? ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"]
                    : ["auto", "default"])
            }
            var seen = Set<String>()
            candidates = candidates.filter { seen.insert($0).inserted }
            var lastError = listError
            for candidate in candidates.prefix(6) {
                try Task.checkCancellation()
                do {
                    _ = try await client.probe(model: candidate)
                    try Task.checkCancellation()
                    guard let self, current == self.generation else { throw CancellationError() }
                    self.model = candidate
                    self.modelStatus = listError == nil ? "已自动选择并验证模型" : "模型列表不可用，已通过 Responses 自动验证"
                    self.defaults.set([candidate], forKey: "api.verifiedModels")
                    self.defaults.set(fingerprint, forKey: "api.verifiedFingerprint")
                    self.defaults.set(Date(), forKey: "api.detectedAt")
                    return candidate
                } catch is CancellationError { throw CancellationError() }
                catch let error as OpenAIResponsesClient.APIError {
                    lastError = error
                    if !error.canTryAnotherModel { throw error }
                }
            }
            throw lastError ?? SettingsError.noModel
        }
        detectionTask = task
        defer {
            if generation == current { detectionTask = nil; isDetecting = false }
        }
        do { return try await task.value }
        catch {
            if generation == current { modelStatus = error.localizedDescription }
            throw error
        }
    }

    func invalidateModel() {
        defaults.removeObject(forKey: "api.detectedAt")
        model = ""
    }

    enum SettingsError: LocalizedError {
        case missingKey, noModel
        var errorDescription: String? {
            switch self {
            case .missingKey: return "请在设置中输入 API Key。"
            case .noModel: return "未找到支持 Responses 工具调用的模型。请确认 API 服务已为此 Key 开通文本模型。"
            }
        }
    }
}

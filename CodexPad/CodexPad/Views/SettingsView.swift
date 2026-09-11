import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agent: AgentController
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var status = ""
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("API 连接") {
                    SecureField(settings.hasKey ? "输入新 API Key" : "API Key", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { save() }
                        .accessibilityIdentifier("api-key")
                        .disabled(saving || agent.isRunning)
                    TextField("API Base URL", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("api-base-url")
                        .disabled(saving || agent.isRunning)
                    Button("保存并连接", action: save)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || agent.isRunning)
                    if saving || settings.isDetecting { ProgressView("正在验证连接…") }
                    Text(status.isEmpty ? settings.modelStatus : status)
                        .font(.callout).foregroundStyle(.secondary)
                    if !settings.model.isEmpty {
                        LabeledContent("自动模型", value: settings.model)
                            .font(.caption.monospaced())
                    }
                }
                if settings.hasKey {
                    Section {
                        Button("重新检测") {
                            saveTask = Task {
                                do { _ = try await settings.resolveModel(force: true); status = "" }
                                catch { status = error.localizedDescription }
                            }
                        }.disabled(settings.isDetecting || agent.isRunning || saving)
                        Button("移除 API Key", role: .destructive) { confirmRemove = true }
                            .disabled(agent.isRunning || saving)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { baseURL = settings.baseURL }
            .onDisappear { apiKey = "" }
            .task(id: apiKey) {
                let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate.count >= 12, !saving, !agent.isRunning,
                      (try? OpenAIResponsesClient.normalizedBaseURL(baseURL)) != nil else { return }
                do { try await Task.sleep(for: .milliseconds(900)) }
                catch { return }
                guard candidate == apiKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                save()
            }
            .confirmationDialog("移除已保存的 API Key？", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("移除", role: .destructive) {
                    do { try settings.removeKey(); agent.newChat(); status = ""; apiKey = "" }
                    catch { status = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func save() {
        guard !saving, !agent.isRunning else { return }
        saving = true
        status = ""
        let key = apiKey
        apiKey = ""
        let base = baseURL
        agent.newChat()
        saveTask = Task {
            do { try await settings.save(key: key, base: base) }
            catch { status = error.localizedDescription }
            saving = false
        }
    }
}

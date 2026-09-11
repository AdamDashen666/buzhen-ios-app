import SwiftUI

struct AgentView: View {
    @EnvironmentObject private var agent: AgentController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppState
    @State private var prompt = ""
    @State private var newChatConfirmation = false
    @State private var autoConfirmation = false
    @State private var acceptAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if agent.messages.isEmpty {
                            ContentUnavailableView("开始编程对话", systemImage: "terminal")
                                .padding(.top, 30)
                            if !settings.hasKey {
                                Button("连接 API", systemImage: "key") { app.showingSettings = true }
                                    .buttonStyle(.borderedProminent)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        ForEach(agent.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == .user ? "你" : message.role == .assistant ? "智能助手" : "操作记录")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                                    .font(message.role == .system ? .caption : .body)
                                    .foregroundStyle(message.role == .system ? Color.secondary : Color.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4).id(message.id)
                        }
                        if !agent.pendingChanges.isEmpty {
                            HStack {
                                Text("待审修改 · \(agent.pendingChanges.count)").font(.headline)
                                Spacer()
                                Menu {
                                    Button("全部接受", systemImage: "checkmark.circle") { acceptAllConfirmation = true }
                                    Button("全部拒绝", systemImage: "xmark.circle", role: .destructive) {
                                        agent.review(ids: Set(agent.pendingChanges.map(\.id)), accept: false)
                                    }
                                } label: { Image(systemName: "checklist") }
                                    .accessibilityLabel("批量审查").disabled(agent.isRunning)
                            }
                            ForEach(agent.pendingChanges) { pending in
                                PendingChangeCard(pending: pending).id(pending.id)
                            }
                        }
                        if agent.isRunning {
                            HStack { ProgressView(); Text(agent.activity).font(.caption).lineLimit(2) }
                        }
                        if agent.retryAvailable {
                            Button("重试上次请求", systemImage: "arrow.clockwise") { agent.retry() }
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }.padding(16)
                }
                .onChange(of: agent.messages.count) { _, _ in withAnimation { proxy.scrollTo("conversation-bottom") } }
                .onChange(of: agent.pendingChanges.count) { _, _ in withAnimation { proxy.scrollTo("conversation-bottom") } }
            }
            Divider()
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("描述需要完成的任务", text: $prompt, axis: .vertical)
                        .lineLimit(1...7).textFieldStyle(.plain).padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { send() }
                        .accessibilityIdentifier("agent-prompt")
                    if agent.isRunning {
                        Button { agent.stop() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                            .buttonStyle(.bordered).tint(.red).accessibilityLabel("停止")
                            .disabled(agent.isStopping)
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up").frame(width: 28, height: 28) }
                            .buttonStyle(.borderedProminent).accessibilityLabel("发送")
                            .disabled(!agent.canSend || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Label(settings.autoApply ? "自动接受已开启" : "修改需要审查",
                          systemImage: settings.autoApply ? "bolt.fill" : "checkmark.shield")
                    Spacer()
                    Text(settings.modelDisplayName).lineLimit(1).truncationMode(.middle)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .navigationTitle("智能助手")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if agent.hasConversation { newChatConfirmation = true } else { agent.newChat() }
                } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("新建对话").help("新建对话").disabled(agent.isRunning)
                Menu {
                    Toggle("自动接受修改", isOn: Binding(get: { settings.autoApply }, set: {
                        if $0 { autoConfirmation = true } else { settings.autoApply = false }
                    })).disabled(agent.isRunning || !agent.pendingChanges.isEmpty)
                    Button("设置", systemImage: "gearshape") { app.showingSettings = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("助手选项")
            }
        }
        .confirmationDialog("结束当前对话？", isPresented: $newChatConfirmation, titleVisibility: .visible) {
            Button("新建对话并丢弃待审提议", role: .destructive) { agent.newChat() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("开启自动接受修改？", isPresented: $autoConfirmation, titleVisibility: .visible) {
            Button("开启", role: .destructive) { settings.autoApply = true }
            Button("取消", role: .cancel) {}
        } message: { Text("后续文件写入、移动和删除将直接执行。请确认项目已有备份。") }
        .confirmationDialog("接受全部待审修改？", isPresented: $acceptAllConfirmation, titleVisibility: .visible) {
            Button("全部接受") { agent.review(ids: Set(agent.pendingChanges.map(\.id)), accept: true) }
            Button("取消", role: .cancel) {}
        } message: { Text("将依次应用修改；遇到冲突会停止，已成功的操作会保留。") }
    }

    private func send() {
        if agent.send(prompt) { prompt = "" }
    }
}

private struct PendingChangeCard: View {
    @EnvironmentObject private var agent: AgentController
    let pending: PendingAgentChange
    @State private var showFullDiff = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "doc.badge.clock").font(.headline)
            Text(pending.change.path).font(.caption.monospaced()).lineLimit(3)
            ScrollView([.horizontal, .vertical]) {
                Text(pending.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            HStack {
                Button("查看 Diff") { showFullDiff = true }
                Spacer(minLength: 4)
                Button("拒绝", role: .destructive) { agent.review(ids: [pending.id], accept: false) }
                Button("接受") { agent.review(ids: [pending.id], accept: true) }.buttonStyle(.borderedProminent)
            }.font(.callout).disabled(agent.isRunning)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showFullDiff) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(pending.diff).font(.system(size: 14, design: .monospaced)).textSelection(.enabled).padding()
                }
                .navigationTitle("修改审查")
                .toolbar { Button("完成") { showFullDiff = false } }
            }
        }
    }
    private var title: String {
        switch pending.change.kind {
        case .write: return "修改文件"
        case .create: return "新建文件"
        case .delete: return "删除文件或空目录"
        case .move: return "移动或重命名"
        case .createDirectory: return "新建目录"
        }
    }
}

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var agent: AgentController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var pane = 1
    @State private var pendingNavigation: Navigation?
    @State private var showProtection = false

    private enum Navigation {
        case file(String, Int), open, close
        var changesProject: Bool {
            switch self { case .file: return false; case .open, .close: return true }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1100 {
                HStack(spacing: 0) {
                    NavigationStack { sidebar }.frame(width: 250)
                    Divider()
                    NavigationStack { EditorView() }.frame(maxWidth: .infinity)
                    Divider()
                    NavigationStack { AgentView() }.frame(width: min(400, geometry.size.width * 0.31))
                }
            } else {
                TabView(selection: $pane) {
                    NavigationStack { sidebar }
                        .tabItem { Label("项目", systemImage: "folder") }.tag(0)
                    NavigationStack { EditorView() }
                        .tabItem { Label("编辑器", systemImage: "curlybraces") }.tag(1)
                    NavigationStack { AgentView() }
                        .tabItem { Label("智能助手", systemImage: "bubble.left.and.text.bubble.right") }.tag(2)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $app.showingFolderImporter) {
            FolderPicker { result in
                switch result {
                case .success(let url):
                    if let url { workspace.openFolder(url); pane = 0 }
                case .failure:
                    workspace.errorMessage = "系统未返回所选文件夹，请重新选择。"
                }
                app.showingFolderImporter = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $app.showingSettings) { SettingsView() }
        .confirmationDialog("继续前处理当前工作", isPresented: $showProtection, titleVisibility: .visible) {
            if workspace.isDirty {
                Button("保存并继续") {
                    guard let action = pendingNavigation else { return }
                    Task {
                        do { try await workspace.saveEditor(); perform(action) }
                        catch { workspace.errorMessage = WorkspaceStore.describe(error) }
                    }
                }
            }
            Button(workspace.isDirty ? "放弃修改并继续" : "结束对话并继续", role: .destructive) {
                workspace.discardEdits()
                if let action = pendingNavigation { perform(action) }
            }
            Button("取消", role: .cancel) { pendingNavigation = nil }
        } message: {
            Text(pendingNavigation?.changesProject == true
                 ? "切换项目将结束当前对话并放弃未接受的提议。已保存的文件不受影响。"
                 : "当前文件还有未保存的编辑。")
        }
        .alert("操作未完成", isPresented: Binding(
            get: { workspace.errorMessage != nil || agent.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil; agent.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { workspace.errorMessage = nil; agent.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? agent.errorMessage ?? "请重试。") }
        .task {
            workspace.restoreRecentProject()
            await settings.refreshIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await workspace.refreshTree()
                    await workspace.refreshSelectedFileIfUnmodified()
                    await settings.refreshIfNeeded()
                }
            } else if phase == .background { agent.stop() }
        }
    }

    private var sidebar: some View {
        FileSidebarView(onOpenFile: { request(.file($0, $1)) },
                        onOpenProject: { request(.open) }, onCloseProject: { request(.close) })
    }

    private func request(_ action: Navigation) {
        guard !workspace.isSavingFile else { return }
        if action.changesProject && agent.isRunning {
            workspace.errorMessage = "请先停止智能助手，再切换项目。"
            return
        }
        if workspace.isDirty || (action.changesProject && agent.hasConversation) {
            pendingNavigation = action
            showProtection = true
        } else { perform(action) }
    }

    private func perform(_ action: Navigation) {
        pendingNavigation = nil
        switch action {
        case .file(let path, let line):
            Task {
                do { try await workspace.openFile(path, line: line); pane = 1 }
                catch { workspace.errorMessage = WorkspaceStore.describe(error) }
            }
        case .open:
            agent.newChat()
            app.showingFolderImporter = true
        case .close:
            agent.newChat()
            workspace.closeFolder()
            pane = 0
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let completion: @MainActor (Result<URL?, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: @MainActor (Result<URL?, Error>) -> Void
        private var delivered = false
        init(completion: @escaping @MainActor (Result<URL?, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !delivered else { return }
            delivered = true
            guard let url = urls.first else { completion(.failure(WorkspaceFileError.noWorkspace)); return }
            completion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !delivered else { return }
            delivered = true
            completion(.success(nil))
        }
    }
}

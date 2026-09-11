import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var agent: AgentController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var pane = 0
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
        .preferredColorScheme(testColorScheme)
        .background {
            FolderPickerPresenter(isPresented: app.showingFolderImporter,
                                  onEvent: workspace.recordOpenEvent,
                                  completion: handleFolderPickerResult)
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $app.showingSettings) { SettingsView() }
        .alert("继续前处理当前工作", isPresented: $showProtection) {
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
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture") || ProcessInfo.processInfo.arguments.contains("--ui-picker") {
                await prepareUITestFixture()
                return
            }
            #endif
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

    private var testColorScheme: ColorScheme? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil
        #else
        nil
        #endif
    }

    #if targetEnvironment(simulator)
    private func prepareUITestFixture() async {
        do {
            let root = try await Task.detached {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let folder = documents.appendingPathComponent("示例项目")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("# 示例项目\n\n你好，CodexPad。\n".utf8).write(to: folder.appendingPathComponent("README.md"))
                try Data("import Foundation\n\nlet greeting = \"你好\"\nprint(greeting)\n".utf8).write(to: folder.appendingPathComponent("主程序.swift"))
                return folder
            }.value
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
                workspace.openFolder(root)
                await workspace.waitForOpening()
                pane = 0
            }
        } catch { workspace.errorMessage = WorkspaceStore.describe(error) }
    }
    #endif

    private var sidebar: some View {
        FileSidebarView(onOpenFile: { request(.file($0, $1)) },
                        onOpenProject: { request(.open) }, onCloseProject: { request(.close) })
    }

    private func request(_ action: Navigation) {
        guard !workspace.isSavingFile, !workspace.isApplyingFile else { return }
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
            guard !app.showingFolderImporter else { return }
            agent.newChat()
            workspace.recordOpenEvent("请求打开文件选择器")
            app.showingFolderImporter = true
        case .close:
            agent.newChat()
            workspace.closeFolder()
            pane = 0
        }
    }

    private func handleFolderPickerResult(_ result: Result<URL?, Error>) {
        switch result {
        case .success(let url):
            guard let url else {
                workspace.recordOpenEvent("用户取消选择文件夹")
                app.showingFolderImporter = false
                return
            }
            pane = 0
            workspace.recordOpenEvent("收到系统文件夹选择回调，立即开始打开")
            workspace.openFolder(url)
            app.showingFolderImporter = false
        case .failure(let error):
            workspace.recordOpenEvent("选择文件夹失败：\(error.localizedDescription)")
            workspace.errorMessage = error.localizedDescription
            app.showingFolderImporter = false
        }
    }
}

// SwiftUI owns only the presentation anchor, never the document picker's delegate.
@MainActor
struct FolderPickerPresenter: UIViewControllerRepresentable {
    let isPresented: Bool
    let onEvent: @MainActor (String) -> Void
    let completion: @MainActor (Result<URL?, Error>) -> Void

    func makeUIViewController(context: Context) -> FolderPickerHostController {
        FolderPickerHostController()
    }

    func updateUIViewController(_ controller: FolderPickerHostController, context: Context) {
        controller.onEvent = onEvent
        controller.completion = completion
        controller.setRequested(isPresented)
    }
}

@MainActor
final class FolderPickerHostController: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    var onEvent: (@MainActor (String) -> Void)?
    var completion: (@MainActor (Result<URL?, Error>) -> Void)?
    private var picker: ObservedFolderPicker?
    private var requested = false
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentIfNeeded()
    }

    func setRequested(_ value: Bool) {
        guard requested != value else { return }
        requested = value
        // Leave the SwiftUI update transaction before presenting or publishing state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.requested { self.presentIfNeeded() }
            else if let picker = self.picker, !self.delivered {
                self.finish(.success(nil), from: picker)
            }
        }
    }

    private func presentIfNeeded() {
        guard requested, picker == nil, viewIfLoaded?.window != nil else { return }
        let picker = ObservedFolderPicker(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .formSheet
        picker.onDisappear = { [weak self, weak picker] in
            guard let self, let picker else { return }
            self.onEvent?("原生文件选择器已离开屏幕")
            // Check after UIKit's dismissal transaction, not after an arbitrary delay.
            DispatchQueue.main.async { [weak self, weak picker] in
                guard let self, let picker, self.picker === picker,
                      !self.delivered, picker.presentingViewController == nil else { return }
                self.finish(.failure(FolderPickerError.missingResult), from: picker)
            }
        }
        self.picker = picker
        delivered = false
        onEvent?("原生文件选择器已创建，代理已绑定")
        present(picker, animated: true) { [weak self, weak picker] in
            guard let self, let picker, self.picker === picker else { return }
            picker.presentationController?.delegate = self
            self.onEvent?(picker.delegate === self
                          ? "原生文件选择器已显示，代理仍有效"
                          : "原生文件选择器代理被替换")
            picker.delegate = self
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onEvent?("原生代理收到目录结果，共 \(urls.count) 项")
        guard let url = urls.first else {
            finish(.failure(FolderPickerError.missingResult), from: controller)
            return
        }
        finish(.success(url), from: controller)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onEvent?("原生代理收到取消事件")
        finish(.success(nil), from: controller)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onEvent?("用户交互关闭原生文件选择器")
        finish(.success(nil), from: presentationController.presentedViewController)
    }

    private func finish(_ result: Result<URL?, Error>, from controller: UIViewController) {
        guard picker === controller, !delivered else { return }
        delivered = true
        requested = false
        // Start the workspace before dismissal. Keep the original scoped URL intact.
        completion?(result)
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { [weak self, weak controller] in
                guard let self, self.picker === controller else { return }
                self.picker = nil
                self.presentIfNeeded()
            }
        } else { picker = nil }
    }
}

@MainActor
final class ObservedFolderPicker: UIDocumentPickerViewController {
    var onDisappear: (@MainActor () -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

enum FolderPickerError: LocalizedError {
    case missingResult

    var errorDescription: String? {
        "系统文件选择器已关闭，但没有返回目录。请重新选择文件夹；若再次失败，请导出打开记录。"
    }
}

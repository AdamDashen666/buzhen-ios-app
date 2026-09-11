import Foundation
import SwiftUI

final class WorkspaceSession: @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let hasScope: Bool
    private let queue = DispatchQueue(label: "CodexPad.workspace.io", qos: .userInitiated)
    private var fileService: WorkspaceFileService?

    private init(url: URL) throws {
        self.url = url
        hasScope = url.startAccessingSecurityScopedResource()
        #if os(iOS)
        if !hasScope {
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(home + "/") else { throw WorkspaceFileError.permissionDenied }
        }
        #endif
    }

    deinit { if hasScope { url.stopAccessingSecurityScopedResource() } }

    static func open(_ url: URL) async throws -> WorkspaceSession {
        // Keep the original URL (and its sandbox extension) across the callback.
        try await FileIOExecutor.run { _ in try WorkspaceSession(url: url) }
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceFileService) throws -> T) async throws -> T {
        try await FileIOExecutor.run(queue: queue) { [self] control in
            if fileService == nil { fileService = try WorkspaceFileService(rootURL: url, control: control) }
            return try operation(fileService!.controlled(by: control))
        }
    }

    func bookmark() async throws -> Data {
        try await FileIOExecutor.run { [self] _ in
            return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    static func restore(_ data: Data) async throws -> WorkspaceSession {
        try await FileIOExecutor.run { _ in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
            // Recreate the bookmark after every successful restore, including stale bookmarks.
            return try WorkspaceSession(url: url)
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var session: WorkspaceSession?
    @Published private(set) var entries: [WorkspaceEntry] = []
    @Published private(set) var children: [String: [WorkspaceEntry]] = [:]
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var selectedPath: String?
    @Published var editorText = ""
    @Published private(set) var savedEditorText = ""
    @Published private(set) var isOpening = false
    @Published private(set) var isLoadingTree = false
    @Published private(set) var isLoadingFile = false
    @Published private(set) var isSavingFile = false
    @Published private(set) var isApplyingFile = false
    @Published private(set) var needsAuthorization = false
    @Published var errorMessage: String?
    @Published var fileNotice: String?
    @Published var editorLine = 1
    @Published private(set) var openingStage = ""
    @Published private(set) var openingFailure: String?
    @Published private(set) var openDiagnostics: [String] = []

    private let defaults: UserDefaults
    private let bookmarkKey = "workspace.securityScopedBookmark"
    private var openTask: Task<Void, Never>?
    private var openGeneration = UUID()
    private var fileGeneration = UUID()
    private var treeGeneration = UUID()
    private var savedRevision: String?
    private var didRestore = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openDiagnostics = defaults.stringArray(forKey: "workspace.openDiagnostics") ?? []
    }
    var rootURL: URL? { session?.url }
    var isDirty: Bool { selectedPath != nil && editorText != savedEditorText }
    var displayName: String { rootURL?.lastPathComponent ?? "项目" }
    var isBusy: Bool { isOpening || isLoadingFile || isSavingFile || isApplyingFile }

    func restoreRecentProject() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        let generation = beginOpening()
        recordOpenEvent("正在恢复最近项目权限")
        openTask = Task { [weak self] in
            do {
                let restored = try await WorkspaceSession.restore(data)
                try Task.checkCancellation()
                await self?.finishOpening(restored, generation: generation)
            } catch {
                self?.openingFailed(error, generation: generation)
            }
        }
    }

    func openFolder(_ url: URL) {
        guard !isDirty, !isSavingFile, !isApplyingFile else {
            errorMessage = "当前文件尚未保存，请先保存或放弃修改。"
            return
        }
        let generation = beginOpening()
        recordOpenEvent("正在获取文件夹访问权限")
        openTask = Task { [weak self] in
            do {
                let candidate = try await WorkspaceSession.open(url)
                try Task.checkCancellation()
                guard let self, self.openGeneration == generation else { return }
                await self.finishOpening(candidate, generation: generation)
            } catch { self?.openingFailed(error, generation: generation) }
        }
    }

    func cancelOpening() {
        if isOpening { recordOpenEvent("已取消打开项目") }
        openTask?.cancel()
        openGeneration = UUID()
        isOpening = false
    }

    func waitForOpening() async { await openTask?.value }

    func closeFolder() {
        guard !isDirty, !isSavingFile, !isApplyingFile else { errorMessage = "请先保存或等待当前文件操作完成。"; return }
        cancelOpening()
        session = nil
        entries = []
        children = [:]
        loadingDirectories = []
        clearEditor()
        needsAuthorization = false
        defaults.removeObject(forKey: bookmarkKey)
    }

    func discardEdits() { editorText = savedEditorText }

    func refreshTree() async {
        guard let current = session, !isOpening else { return }
        let generation = UUID()
        treeGeneration = generation
        isLoadingTree = true
        defer { if treeGeneration == generation { isLoadingTree = false } }
        do {
            let tree = try await current.perform { try $0.listDirectory(path: "") }
            try Task.checkCancellation()
            guard session?.id == current.id, treeGeneration == generation else { return }
            entries = tree
            let expanded = Array(children.keys)
            children = [:]
            for path in expanded { await loadDirectory(path) }
        } catch is CancellationError {
        } catch { report(error, sessionID: current.id) }
    }

    func loadDirectory(_ path: String) async {
        guard let current = session, !loadingDirectories.contains(path) else { return }
        loadingDirectories.insert(path)
        defer { if session?.id == current.id { loadingDirectories.remove(path) } }
        do {
            let values = try await current.perform { try $0.listDirectory(path: path) }
            try Task.checkCancellation()
            guard session?.id == current.id else { return }
            children[path] = values
        } catch is CancellationError {
        } catch { report(error, sessionID: current.id) }
    }

    func openFile(_ path: String, discardUnsaved: Bool = false, line: Int = 1) async throws {
        if isDirty && !discardUnsaved { throw EditorError.unsavedChanges }
        guard !isSavingFile, !isOpening, !isApplyingFile, let current = session else { throw WorkspaceFileError.noWorkspace }
        let generation = UUID()
        fileGeneration = generation
        isLoadingFile = true
        defer { if fileGeneration == generation { isLoadingFile = false } }
        let snapshot = try await current.perform { try $0.readSnapshot(path: path) }
        try Task.checkCancellation()
        guard session?.id == current.id, fileGeneration == generation else { return }
        selectedPath = path
        editorText = snapshot.text
        savedEditorText = snapshot.text
        savedRevision = snapshot.revision
        editorLine = max(1, line)
        fileNotice = nil
    }

    func saveEditor() async throws {
        guard !isSavingFile, !isLoadingFile, !isOpening, !isApplyingFile else { throw EditorError.busy }
        guard let path = selectedPath, let current = session, let baseline = savedRevision else { return }
        let text = editorText
        isSavingFile = true
        defer { isSavingFile = false }
        let newSnapshot = try await current.perform { try $0.save(path: path, text: text, baseline: baseline) }
        guard session?.id == current.id, selectedPath == path else { return }
        savedEditorText = text
        savedRevision = newSnapshot.revision
        if newSnapshot.text != text { fileNotice = "保存后文件又被外部修改，请重新读取。" }
        else { fileNotice = "已保存" }
    }

    func revertEditor() async throws {
        guard let path = selectedPath else { return }
        try await openFile(path, discardUnsaved: true)
    }

    func refreshSelectedFileIfUnmodified() async {
        guard !isSavingFile, !isLoadingFile, let path = selectedPath, let current = session else { return }
        let generation = fileGeneration
        do {
            let snapshot = try await current.perform { try $0.readSnapshot(path: path) }
            guard session?.id == current.id, selectedPath == path, fileGeneration == generation, !isSavingFile else { return }
            if isDirty {
                if savedRevision != snapshot.revision { fileNotice = "文件在外部发生变化，保存已启用冲突保护。" }
            } else {
                editorText = snapshot.text
                savedEditorText = snapshot.text
                savedRevision = snapshot.revision
                fileNotice = nil
            }
        } catch {
            guard session?.id == current.id, selectedPath == path, fileGeneration == generation else { return }
            if isDirty { fileNotice = "文件无法读取或已被删除，本地未保存内容仍保留。" }
            else { clearEditor(); errorMessage = "当前文件无法继续打开：\(Self.describe(error))" }
        }
    }

    func apply(_ change: PendingChange, in expectedSession: UUID) async throws {
        guard let current = session, current.id == expectedSession, !isOpening else { throw WorkspaceFileError.changed }
        guard !isApplyingFile else { throw EditorError.busy }
        let affectsEditor = selectedPath.map { $0 == change.path || $0.hasPrefix(change.path + "/") } ?? false
        if affectsEditor && (isDirty || isSavingFile || isLoadingFile) { throw EditorError.unsavedChanges }
        isApplyingFile = true
        defer { isApplyingFile = false }
        try await current.perform { try $0.apply(change) }
        guard session?.id == current.id else { return }
        if selectedPath == change.path {
            if change.kind == .delete { clearEditor() }
            else if change.kind == .move { selectedPath = change.destinationPath }
        }
        else if change.kind == .move, let path = selectedPath, path.hasPrefix(change.path + "/"),
                let destination = change.destinationPath {
            selectedPath = destination + path.dropFirst(change.path.count)
        }
        await refreshTree()
        await refreshSelectedFileIfUnmodified()
    }

    private func beginOpening() -> UUID {
        cancelOpening()
        fileGeneration = UUID()
        isLoadingFile = false
        isOpening = true
        needsAuthorization = false
        errorMessage = nil
        openingFailure = nil
        return openGeneration
    }

    private func finishOpening(_ candidate: WorkspaceSession, generation: UUID) async {
        do {
            recordOpenEvent("已取得访问资格，正在协调文件提供器并读取首层目录")
            // Opening only enumerates the first level, never descendants.
            let tree = try await candidate.perform { try $0.listDirectory(path: "") }
            try Task.checkCancellation()
            guard generation == openGeneration else { return }
            session = candidate
            entries = tree
            children = [:]
            loadingDirectories = []
            clearEditor()
            isOpening = false
            isLoadingTree = false
            needsAuthorization = false
            recordOpenEvent("项目已打开，共 \(tree.count) 项")
            do {
                let data = try await candidate.bookmark()
                guard generation == openGeneration else { return }
                defaults.set(data, forKey: bookmarkKey)
                recordOpenEvent("最近项目权限已保存")
            } catch {
                guard generation == openGeneration else { return }
                errorMessage = "项目已打开，但无法保存下次访问权限。重启后请重新选择文件夹。"
                recordOpenEvent("无法保存书签：\(Self.describe(error))")
            }
        } catch { openingFailed(error, generation: generation) }
    }

    private func openingFailed(_ error: Error, generation: UUID) {
        guard generation == openGeneration else { return }
        isOpening = false
        if error is CancellationError { return }
        needsAuthorization = true
        openingFailure = "无法打开项目：\(Self.describe(error))"
        recordOpenEvent(openingFailure!)
        errorMessage = openingFailure
    }

    func recordOpenEvent(_ message: String) {
        openingStage = message
        let time = Date().formatted(date: .omitted, time: .standard)
        openDiagnostics.append("\(time) \(message)")
        openDiagnostics = Array(openDiagnostics.suffix(30))
        defaults.set(openDiagnostics, forKey: "workspace.openDiagnostics")
    }

    var diagnosticsText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "测试"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "测试"
        return "CodexPad \(version) (\(build))\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n" +
            openDiagnostics.joined(separator: "\n")
    }

    private func clearEditor() {
        fileGeneration = UUID()
        selectedPath = nil
        editorText = ""
        savedEditorText = ""
        savedRevision = nil
        fileNotice = nil
        isLoadingFile = false
    }

    private func report(_ error: Error, sessionID: UUID) {
        guard session?.id == sessionID else { return }
        errorMessage = Self.describe(error)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? WorkspaceFileError { return error.localizedDescription }
        if let error = error as? WorkspacePathError { return error.localizedDescription }
        if let error = error as? EditorError { return error.localizedDescription }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            return "文件提供器无法完成请求（错误 \(ns.code)）。请确认 iCloud 已同步且文件夹权限仍有效。"
        }
        return "操作未完成（错误 \(ns.code)），请重试。"
    }

    enum EditorError: LocalizedError {
        case unsavedChanges, busy
        var errorDescription: String? {
            switch self {
            case .unsavedChanges: return "当前文件有未保存的修改，请先保存或放弃后重试。"
            case .busy: return "文件正在读取或保存，请稍后重试。"
            }
        }
    }
}

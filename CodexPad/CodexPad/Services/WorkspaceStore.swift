import Foundation
import SwiftUI

final class WorkspaceSession: @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let hasScope: Bool
    private let lock = NSLock()
    private var fileService: WorkspaceFileService?

    init(url: URL) {
        self.url = url
        hasScope = url.startAccessingSecurityScopedResource()
    }

    deinit { if hasScope { url.stopAccessingSecurityScopedResource() } }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceFileService) throws -> T) async throws -> T {
        let control = FileOperationControl()
        let job = Task.detached(priority: .userInitiated) { [self] in
            try lock.withLock {
                try Task.checkCancellation()
                if fileService == nil { fileService = try WorkspaceFileService(rootURL: url) }
                return try operation(fileService!.controlled(by: control))
            }
        }
        let timeout = Task.detached {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            control.cancel(timeout: true)
            job.cancel()
        }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await job.value
            } onCancel: { control.cancel(); job.cancel() }
        } catch {
            if control.timedOut { throw WorkspaceFileError.timedOut }
            throw error
        }
    }

    func bookmark() async throws -> Data {
        let job = Task.detached { [self] in
            try Task.checkCancellation()
            return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    static func restore(_ data: Data) async throws -> WorkspaceSession {
        try await Task.detached {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
            // Recreate the bookmark after every successful restore, including stale bookmarks.
            return WorkspaceSession(url: url)
        }.value
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
    @Published private(set) var needsAuthorization = false
    @Published var errorMessage: String?
    @Published var fileNotice: String?
    @Published var editorLine = 1

    private let defaults: UserDefaults
    private let bookmarkKey = "workspace.securityScopedBookmark"
    private var openTask: Task<Void, Never>?
    private var openGeneration = UUID()
    private var fileGeneration = UUID()
    private var treeGeneration = UUID()
    private var savedRevision: String?
    private var didRestore = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var rootURL: URL? { session?.url }
    var isDirty: Bool { selectedPath != nil && editorText != savedEditorText }
    var displayName: String { rootURL?.lastPathComponent ?? "项目" }
    var isBusy: Bool { isOpening || isLoadingFile || isSavingFile }

    func restoreRecentProject() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        let generation = beginOpening()
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
        guard !isDirty, !isSavingFile else {
            errorMessage = "当前文件尚未保存，请先保存或放弃修改。"
            return
        }
        let generation = beginOpening()
        // Acquire the lightweight scope while the picker callback is still alive.
        // Bookmark creation and provider access happen only in background operations.
        let candidate = WorkspaceSession(url: url)
        openTask = Task { [weak self] in
            await self?.finishOpening(candidate, generation: generation)
        }
    }

    func cancelOpening() {
        openTask?.cancel()
        openGeneration = UUID()
        isOpening = false
    }

    func waitForOpening() async { await openTask?.value }

    func closeFolder() {
        guard !isDirty, !isSavingFile else { errorMessage = "请先保存或放弃当前修改。"; return }
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
        guard !isSavingFile, !isOpening, let current = session else { throw WorkspaceFileError.noWorkspace }
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
        guard !isSavingFile, !isLoadingFile, !isOpening else { throw EditorError.busy }
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
        if selectedPath == change.path && (isDirty || isSavingFile || isLoadingFile) { throw EditorError.unsavedChanges }
        try await current.perform { try $0.apply(change) }
        guard session?.id == current.id else { return }
        if selectedPath == change.path {
            if change.kind == .delete { clearEditor() }
            else if change.kind == .move { selectedPath = change.destinationPath }
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
        return openGeneration
    }

    private func finishOpening(_ candidate: WorkspaceSession, generation: UUID) async {
        do {
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
            do {
                let data = try await candidate.bookmark()
                guard generation == openGeneration else { return }
                defaults.set(data, forKey: bookmarkKey)
            } catch {
                guard generation == openGeneration else { return }
                errorMessage = "项目已打开，但无法保存下次访问权限。重启后请重新选择文件夹。"
            }
        } catch { openingFailed(error, generation: generation) }
    }

    private func openingFailed(_ error: Error, generation: UUID) {
        guard generation == openGeneration else { return }
        isOpening = false
        if error is CancellationError { return }
        needsAuthorization = true
        errorMessage = "无法打开项目：\(Self.describe(error))\n请点击“重新授权”选择文件夹。"
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

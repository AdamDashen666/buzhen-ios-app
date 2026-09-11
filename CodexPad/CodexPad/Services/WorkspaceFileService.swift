import Foundation
import CryptoKit
import Darwin

struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}

struct SearchHit: Codable, Identifiable, Sendable {
    let path: String
    let line: Int
    let preview: String
    var id: String { "\(path):\(line)" }
}

struct SearchResults: Codable, Sendable {
    let hits: [SearchHit]
    let truncated: Bool
    let skippedFiles: Int
}

struct FileSnapshot: Sendable {
    let text: String
    let revision: String
}

enum WorkspaceFileError: LocalizedError {
    case noWorkspace, rootMutation, cancelled, changed, invalidReplacement, tooManyEntries, timedOut
    case binaryOrInvalidUTF8(String), tooLarge(String), symlinkNotAllowed(String)
    case notFound(String), alreadyExists(String), directoryNotEmpty(String), io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .noWorkspace: return "请先打开项目文件夹。"
        case .rootMutation: return "不允许修改、移动或删除工作区根目录。"
        case .cancelled: return "操作已取消。"
        case .changed: return "文件已被其他操作修改、移动或删除。为避免覆盖，已停止保存；请重新读取后审查。"
        case .invalidReplacement: return "原文必须非空且恰好匹配一处。请提供更完整的上下文。"
        case .tooManyEntries: return "此目录超过 5000 个项目，请选择更小的项目目录。"
        case .timedOut: return "文件提供器响应超时。请确认 iCloud 文件已下载，或稍后重新打开。"
        case .binaryOrInvalidUTF8(let path): return "\(path) 不是 UTF-8 文本，无法在代码编辑器中打开。"
        case .tooLarge(let path): return "\(path) 超过 2 MB 文本编辑上限。"
        case .symlinkNotAllowed(let path): return "已阻止符号链接访问：\(path)"
        case .notFound(let path): return "找不到文件或目录：\(path)"
        case .alreadyExists(let path): return "目标已经存在，不会覆盖：\(path)"
        case .directoryNotEmpty(let path): return "不允许递归删除非空目录，请逐项审查其中的文件：\(path)"
        case .io(let path, let code):
            if code == EACCES || code == EPERM { return "没有访问权限：\(path)。请重新选择项目文件夹授权。" }
            if code == ENOENT { return "找不到路径：\(path)。如来自 iCloud，请确认文件已同步。" }
            if code == ELOOP { return "已阻止符号链接：\(path)" }
            if code == ENOSPC { return "存储空间不足，无法保存：\(path)" }
            return "文件操作失败：\(path)（系统错误 \(code)）。请检查文件提供器或重新授权。"
        }
    }
}

// Descriptor-relative access prevents a symlink swap from redirecting file I/O
// after validation. Descriptors and security scopes outlive each operation.
struct WorkspaceFileService: Sendable {
    let rootURL: URL
    private let rootHandle: DirectoryHandle
    private var cancellation: FileOperationControl?
    static let maxTextBytes = 2 * 1024 * 1024

    init(rootURL: URL) throws {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        rootHandle = try DirectoryHandle(url: self.rootURL)
    }

    func controlled(by control: FileOperationControl) -> Self {
        var copy = self
        copy.cancellation = control
        return copy
    }

    func listDirectory(path: String) throws -> [WorkspaceEntry] {
        let normalized = try WorkspacePathGuard.normalize(path)
        return try coordinate { try listUncoordinated(normalized) }
    }

    func readSnapshot(path: String) throws -> FileSnapshot {
        try coordinate(path: path) {
            let data = try readData(path: path)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceFileError.binaryOrInvalidUTF8(path)
            }
            return FileSnapshot(text: text, revision: digest(data))
        }
    }

    func prepare(kind: PendingChange.Kind, path: String, destination: String? = nil,
                 content: String? = nil, oldText: String? = nil) throws -> PendingChange {
        try coordinate(path: kind == .write ? path : nil) {
            try requireNonRoot(path)
            if let destination { try requireNonRoot(destination) }
            if let content, content.utf8.count > Self.maxTextBytes { throw WorkspaceFileError.tooLarge(path) }
            if kind == .create || kind == .createDirectory {
                try requireMissing(path)
                return PendingChange(kind: kind, path: path, originalText: "", proposedText: content)
            }
            if kind == .write {
                let data = try readData(path: path)
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                    throw WorkspaceFileError.binaryOrInvalidUTF8(path)
                }
                var proposed = content ?? ""
                if let oldText {
                    guard !oldText.isEmpty, text.components(separatedBy: oldText).count == 2 else {
                        throw WorkspaceFileError.invalidReplacement
                    }
                    proposed = text.replacingOccurrences(of: oldText, with: proposed)
                }
                guard proposed.utf8.count <= Self.maxTextBytes else { throw WorkspaceFileError.tooLarge(path) }
                return PendingChange(kind: kind, path: path, originalText: text,
                                     proposedText: proposed, baseline: digest(data))
            }
            if let destination { try requireMissing(destination) }
            let revision = try itemRevision(path, includeChildren: kind == .move)
            let old = try? readData(path: path)
            return PendingChange(kind: kind, path: path, destinationPath: destination,
                                 originalText: old.flatMap { String(data: $0, encoding: .utf8) },
                                 proposedText: "", baseline: revision)
        }
    }

    func apply(_ change: PendingChange) throws {
        try coordinate(writing: true) {
            try Task.checkCancellation()
            try requireNonRoot(change.path)
            switch change.kind {
            case .write:
                guard let baseline = change.baseline, try digest(readData(path: change.path)) == baseline else {
                    throw WorkspaceFileError.changed
                }
                try atomicWrite(path: change.path, content: change.proposedText ?? "", create: false)
            case .create:
                try requireMissing(change.path)
                try atomicWrite(path: change.path, content: change.proposedText ?? "", create: true)
            case .createDirectory:
                try withParent(change.path) { parent, leaf in
                    guard mkdirat(parent, leaf, 0o755) == 0 else { throw failure(change.path) }
                }
            case .delete, .move:
                guard let baseline = change.baseline, try itemRevision(change.path, includeChildren: change.kind == .move) == baseline else {
                    throw WorkspaceFileError.changed
                }
                try withParent(change.path) { parent, leaf in
                    var info = stat()
                    guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(change.path) }
                    if change.kind == .delete {
                        let flags = (info.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
                        guard unlinkat(parent, leaf, flags) == 0 else { throw failure(change.path) }
                    } else {
                        guard let destination = change.destinationPath else { throw WorkspacePathError.invalidComponent }
                        try requireNonRoot(destination)
                        try withParent(destination) { target, name in
                            guard renameatx_np(parent, leaf, target, name, UInt32(RENAME_EXCL)) == 0 else {
                                throw failure(destination)
                            }
                        }
                    }
                }
            }
        }
    }

    func save(path: String, text: String, baseline: String) throws -> FileSnapshot {
        try apply(PendingChange(kind: .write, path: path, proposedText: text, baseline: baseline))
        return FileSnapshot(text: text, revision: digest(Data(text.utf8)))
    }

    func search(query: String, under path: String, excludeSensitive: Bool) throws -> SearchResults {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchResults(hits: [], truncated: false, skippedFiles: 0)
        }
        let start = try WorkspacePathGuard.normalize(path)
        var queue = [start]
        var hits: [SearchHit] = []
        var visited = 0
        var skipped = 0
        let deadline = Date().addingTimeInterval(15)
        while let directory = queue.popLast() {
            try Task.checkCancellation()
            for entry in try listDirectory(path: directory) {
                try Task.checkCancellation()
                visited += 1
                if visited > 5000 || hits.count >= 100 || Date() > deadline {
                    return SearchResults(hits: hits, truncated: true, skippedFiles: skipped)
                }
                if Self.isGenerated(entry.path) || (excludeSensitive && SensitivePathPolicy.isSensitive(entry.path)) { continue }
                if entry.name.localizedCaseInsensitiveContains(query) {
                    hits.append(SearchHit(path: entry.path, line: 0, preview: entry.isDirectory ? "目录名称匹配" : "文件名称匹配"))
                }
                if entry.isDirectory { queue.append(entry.path); continue }
                let snapshot: FileSnapshot
                do { snapshot = try readSnapshot(path: entry.path) }
                catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; continue }
                for (index, line) in snapshot.text.components(separatedBy: "\n").enumerated() {
                    if line.localizedCaseInsensitiveContains(query) {
                        hits.append(SearchHit(path: entry.path, line: index + 1, preview: String(line.prefix(240))))
                        if hits.count >= 100 {
                            return SearchResults(hits: hits, truncated: true, skippedFiles: skipped)
                        }
                    }
                }
            }
        }
        return SearchResults(hits: hits, truncated: false, skippedFiles: skipped)
    }

    static func isGenerated(_ path: String) -> Bool {
        let names: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "Pods", "node_modules", ".next", ".venv"]
        return path.split(separator: "/").contains { names.contains(String($0)) }
    }

    private func listUncoordinated(_ path: String) throws -> [WorkspaceEntry] {
        let fd = try openDirectory(path)
        guard let dir = fdopendir(fd) else { close(fd); throw failure(path) }
        defer { closedir(dir) }
        var entries: [WorkspaceEntry] = []
        while let pointer = readdir(dir) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(name) }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { continue }
            if type != S_IFREG && type != S_IFDIR { continue }
            entries.append(WorkspaceEntry(name: name, path: path.isEmpty ? name : "\(path)/\(name)", isDirectory: type == S_IFDIR))
            if entries.count > 5000 { throw WorkspaceFileError.tooManyEntries }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func readData(path: String) throws -> Data {
        try requireNonRoot(path)
        return try withParent(path) { parent, leaf in
            let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw failure(path) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw failure(path) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.binaryOrInvalidUTF8(path) }
            guard info.st_size <= Self.maxTextBytes else { throw WorkspaceFileError.tooLarge(path) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure(path)
                }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > Self.maxTextBytes { throw WorkspaceFileError.tooLarge(path) }
            }
            return data
        }
    }

    private func atomicWrite(path: String, content: String, create: Bool) throws {
        let data = Data(content.utf8)
        guard data.count <= Self.maxTextBytes else { throw WorkspaceFileError.tooLarge(path) }
        try withParent(path) { parent, leaf in
            let temporary = ".codexpad-\(UUID().uuidString).tmp"
            var mode: mode_t = 0o644
            var info = stat()
            if !create, fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { mode = info.st_mode & 0o777 }
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard fd >= 0 else { throw failure(path) }
            defer { close(fd); unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure(path) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw failure(path) }
            try Task.checkCancellation()
            let flags: UInt32 = create ? UInt32(RENAME_EXCL) : 0
            guard renameatx_np(parent, temporary, parent, leaf, flags) == 0 else { throw failure(path) }
        }
    }

    private func itemRevision(_ path: String, includeChildren: Bool) throws -> String {
        var remaining = 5000
        return try revision(path, includeChildren: includeChildren, remaining: &remaining, depth: 0)
    }

    private func revision(_ path: String, includeChildren: Bool, remaining: inout Int, depth: Int) throws -> String {
        remaining -= 1
        guard remaining >= 0, depth <= 64 else { throw WorkspaceFileError.tooManyEntries }
        try Task.checkCancellation()
        return try withParent(path) { parent, leaf in
            var info = stat()
            guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(path) }
            let metadata = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            if info.st_mode & S_IFMT == S_IFLNK { throw WorkspaceFileError.symlinkNotAllowed(path) }
            if info.st_mode & S_IFMT == S_IFDIR {
                let entries = try listUncoordinated(path)
                if !includeChildren && !entries.isEmpty { throw WorkspaceFileError.directoryNotEmpty(path) }
                var parts = [metadata]
                for entry in entries {
                    parts.append(entry.path)
                    parts.append(try revision(entry.path, includeChildren: true, remaining: &remaining, depth: depth + 1))
                }
                return digest(Data(parts.joined(separator: "\n").utf8))
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.binaryOrInvalidUTF8(path) }
            if info.st_size > Self.maxTextBytes { return metadata }
            return try metadata + ":" + digest(readData(path: path))
        }
    }

    private func requireMissing(_ path: String) throws {
        try withParent(path) { parent, leaf in
            var info = stat()
            if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw WorkspaceFileError.alreadyExists(path) }
            if errno != ENOENT { throw failure(path) }
        }
    }

    private func requireNonRoot(_ path: String) throws {
        if try WorkspacePathGuard.normalize(path).isEmpty { throw WorkspaceFileError.rootMutation }
    }

    private func openDirectory(_ path: String) throws -> Int32 {
        let normalized = try WorkspacePathGuard.normalize(path)
        var fd = openat(rootHandle.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(path) }
        for component in normalized.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw failure(path) }
            fd = next
        }
        return fd
    }

    private func withParent<T>(_ path: String, _ body: (Int32, String) throws -> T) throws -> T {
        try requireNonRoot(path)
        let normalized = try WorkspacePathGuard.normalize(path)
        var parts = normalized.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        let parent = try openDirectory(parts.joined(separator: "/"))
        defer { close(parent) }
        return try body(parent, leaf)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ path: String) -> WorkspaceFileError { .io(path, errno) }

    private func coordinate<T>(path: String? = nil, writing: Bool = false, _ body: @escaping () throws -> T) throws -> T {
        try Task.checkCancellation()
        try cancellation?.check()
        let target: URL
        if let path {
            try withParent(path) { parent, leaf in
                var info = stat()
                let status = fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW)
                if status != 0 && errno != ENOENT { throw failure(path) }
                if status == 0 && info.st_mode & S_IFMT == S_IFLNK { throw WorkspaceFileError.symlinkNotAllowed(path) }
            }
            target = rootURL.appendingPathComponent(try WorkspacePathGuard.normalize(path))
        } else { target = rootURL }
        if path != nil && FileManager.default.isUbiquitousItem(at: target) {
            try FileManager.default.startDownloadingUbiquitousItem(at: target)
        }
        var error: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        try cancellation?.register(coordinator)
        defer { cancellation?.unregister() }
        let accessor: (URL) -> Void = { url in
            result = Result {
                try Task.checkCancellation()
                try cancellation?.check()
                guard url.standardizedFileURL == target.standardizedFileURL else {
                    throw WorkspaceFileError.changed
                }
                var live = stat()
                var pinned = stat()
                guard lstat(rootURL.path, &live) == 0, fstat(rootHandle.fd, &pinned) == 0,
                      live.st_ino == pinned.st_ino, live.st_dev == pinned.st_dev,
                      live.st_mode & S_IFMT == S_IFDIR else { throw WorkspaceFileError.changed }
                return try body()
            }
        }
        if writing {
            coordinator.coordinate(writingItemAt: target, options: [], error: &error, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: target, options: [], error: &error, byAccessor: accessor)
        }
        if result == nil { try cancellation?.check() }
        if let error { throw error }
        guard let result else { throw WorkspaceFileError.cancelled }
        return try result.get()
    }
}

final class FileOperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: NSFileCoordinator?
    private var cancelled = false
    private var timeout = false
    var timedOut: Bool { lock.withLock { timeout } }
    func register(_ coordinator: NSFileCoordinator) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.coordinator = coordinator
        }
    }
    func unregister() { lock.withLock { coordinator = nil } }
    func cancel(timeout: Bool = false) {
        let current = lock.withLock {
            cancelled = true
            self.timeout = self.timeout || timeout
            return coordinator
        }
        current?.cancel()
    }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

private final class DirectoryHandle: @unchecked Sendable {
    let fd: Int32
    init(url: URL) throws {
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceFileError.io(url.lastPathComponent, errno) }
    }
    deinit { close(fd) }
}

import Foundation

public enum WorkspacePathError: LocalizedError, Equatable, Sendable {
    case absolutePath
    case traversal
    case invalidComponent

    public var errorDescription: String? {
        switch self {
        case .absolutePath: return "不允许使用绝对路径。"
        case .traversal: return "不允许通过路径跳出当前工作区。"
        case .invalidComponent: return "路径中包含无效的目录或文件名。"
        }
    }
}

public enum WorkspacePathGuard {
    /// 将模型提供的路径限制为工作区内的相对路径。
    /// 同时拒绝 Windows 分隔符、POSIX 绝对路径和目录穿越。
    public static func normalize(_ raw: String) throws -> String {
        if raw == "." || raw.isEmpty { return "" }
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.contains("\\") || raw.contains(":") {
            throw WorkspacePathError.absolutePath
        }
        if raw.contains("\0") { throw WorkspacePathError.invalidComponent }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty || $0 == ".." }) {
            if parts.contains(where: { $0 == ".." }) { throw WorkspacePathError.traversal }
            throw WorkspacePathError.invalidComponent
        }
        if parts.contains(where: { $0 == "." }) { throw WorkspacePathError.invalidComponent }
        return parts.joined(separator: "/")
    }
}

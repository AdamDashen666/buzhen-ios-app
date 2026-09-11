import Foundation

public struct PendingChange: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case write, create, delete, move, createDirectory
    }

    public let id: UUID
    public let kind: Kind
    public let path: String
    public let destinationPath: String?
    public let originalText: String?
    public let proposedText: String?
    public let baseline: String?

    public init(id: UUID = UUID(), kind: Kind, path: String, destinationPath: String? = nil, originalText: String? = nil, proposedText: String? = nil, baseline: String? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.destinationPath = destinationPath
        self.originalText = originalText
        self.proposedText = proposedText
        self.baseline = baseline
    }

    public var diff: String {
        switch kind {
        case .write:
            return TextDiff.unified(old: originalText ?? "", new: proposedText ?? "", path: path)
        case .create:
            if proposedText?.isEmpty != false { return "新建空文件：\(path)" }
            return TextDiff.unified(old: "", new: proposedText ?? "", path: path)
        case .delete:
            guard let originalText else { return "删除文件或目录：\(path)\n此项目没有文本预览。" }
            if originalText.isEmpty { return "删除空文件：\(path)" }
            return TextDiff.unified(old: originalText, new: "", path: path)
        case .move:
            return "移动 \(path) → \(destinationPath ?? "")"
        case .createDirectory:
            return "新建目录：\(path)"
        }
    }
}

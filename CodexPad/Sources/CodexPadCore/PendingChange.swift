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
            return TextDiff.unified(old: "", new: proposedText ?? "", path: path)
        case .delete:
            return TextDiff.unified(old: originalText ?? "", new: "", path: path)
        case .move:
            return "移动 \(path) → \(destinationPath ?? "")"
        case .createDirectory:
            return "新建目录：\(path)"
        }
    }
}

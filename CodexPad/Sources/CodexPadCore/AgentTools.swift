import Foundation

public struct ToolProperty: Codable, Equatable, Sendable {
    public let type: String
    public let description: String

    public init(type: String = "string", description: String) {
        self.type = type
        self.description = description
    }
}

public struct ToolParameters: Codable, Equatable, Sendable {
    public let type: String
    public let properties: [String: ToolProperty]
    public let required: [String]
    public let additionalProperties: Bool

    public init(properties: [String: ToolProperty]) {
        self.type = "object"
        self.properties = properties
        self.required = Array(properties.keys).sorted()
        self.additionalProperties = false
    }
}

public struct FunctionTool: Codable, Equatable, Sendable {
    public let type: String
    public let name: String
    public let description: String
    public let parameters: ToolParameters
    public let strict: Bool

    public init(name: String, description: String, properties: [String: ToolProperty]) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = ToolParameters(properties: properties)
        self.strict = true
    }
}

public enum AgentToolCatalog {
    public static let all: [FunctionTool] = [
        .init(name: "list_directory", description: "列出工作区相对路径中的文件和文件夹。根目录请传空字符串。", properties: [
            "path": .init(description: "工作区相对目录路径；根目录使用空字符串。")
        ]),
        .init(name: "read_file", description: "分页读取 UTF-8 文本，返回行号。单次最多 200 行，超出部分继续分页读取。", properties: [
            "path": .init(description: "工作区相对文件路径。"),
            "start_line": .init(description: "起始行号，十进制字符串，从 1 开始。"),
            "line_count": .init(description: "读取行数，十进制字符串，1 到 200。")
        ]),
        .init(name: "search_files", description: "搜索文件路径及 UTF-8 文件内容，返回匹配路径、行号和摘要。结果有上限，可缩小目录继续搜索。", properties: [
            "path": .init(description: "工作区相对目录路径；根目录使用空字符串。"),
            "query": .init(description: "要搜索的文本。")
        ]),
        .init(name: "write_file", description: "提议完整替换现有 UTF-8 文件内容。根据设置，修改可能需要用户确认后才会应用。", properties: [
            "path": .init(description: "工作区相对文件路径。"),
            "content": .init(description: "文件的完整新内容。")
        ]),
        .init(name: "create_file", description: "提议创建新的 UTF-8 文本文件，不覆盖同名文件。父目录必须存在，否则先用 create_directory 创建。", properties: [
            "path": .init(description: "工作区相对的新文件路径。"),
            "content": .init(description: "新文件的完整内容。")
        ]),
        .init(name: "delete_file", description: "提议删除工作区中的文件或空目录。", properties: [
            "path": .init(description: "要删除的工作区相对路径。")
        ]),
        .init(name: "move_file", description: "提议移动或重命名工作区中的文件或目录。", properties: [
            "from": .init(description: "当前工作区相对路径。"),
            "to": .init(description: "目标工作区相对路径。")
        ]),
        .init(name: "rename_file", description: "提议重命名文件或目录；目标为完整工作区相对路径，不覆盖已有项目。", properties: [
            "from": .init(description: "当前相对路径。"),
            "to": .init(description: "新相对路径。")
        ]),
        .init(name: "replace_text", description: "提议替换文件中唯一匹配的原文。零处或多处匹配时拒绝，请提供更完整的上下文。", properties: [
            "path": .init(description: "相对文件路径。"),
            "old_text": .init(description: "需要替换的非空原文，必须唯一匹配。"),
            "new_text": .init(description: "替换后的文本，可以为空。")
        ]),
        .init(name: "create_directory", description: "提议创建空目录，父目录必须已存在。", properties: [
            "path": .init(description: "新目录的相对路径。")
        ])
    ]

    private static let mutationNames: Set<String> = [
        "write_file", "create_file", "replace_text", "delete_file", "move_file", "rename_file", "create_directory"
    ]
    public static func isMutation(_ name: String) -> Bool { mutationNames.contains(name) }
}

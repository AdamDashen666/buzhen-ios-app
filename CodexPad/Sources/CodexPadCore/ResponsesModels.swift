import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }

    public static func user(_ text: String) -> JSONValue {
        .object(["role": .string("user"), "content": .string(text)])
    }
    public static func tool(callID: String, output: String) -> JSONValue {
        .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(output)])
    }
}

public struct ResponsesEnvelope: Codable, Equatable, Sendable {
    public let id: String
    public let model: String?
    public let status: String?
    public let output: [JSONValue]

    public init(id: String, output: [JSONValue], model: String? = nil, status: String? = nil) {
        self.id = id
        self.output = output
        self.model = model
        self.status = status
    }

    public var functionCalls: [FunctionCall] {
        output.compactMap {
            guard $0["type"]?.string == "function_call", let callID = $0["call_id"]?.string,
                  let name = $0["name"]?.string, let arguments = $0["arguments"]?.string else { return nil }
            return FunctionCall(callID: callID, name: name, arguments: arguments)
        }
    }

    public var outputText: String {
        output.flatMap { item -> [String] in
            guard item["type"]?.string == "message", case .array(let content) = item["content"] else { return [] }
            return content.compactMap {
                if $0["type"]?.string == "refusal" { return "模型拒绝了本次请求。" }
                return $0["type"]?.string == "output_text" ? $0["text"]?.string : nil
            }
        }.joined(separator: "\n")
    }
}

public struct FunctionCall: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let arguments: String
}

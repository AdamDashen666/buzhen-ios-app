import Foundation

public enum ModelAutoSelector {
    public static func bestModel(from ids: [String]) -> String? {
        rankedModels(from: ids).first
    }

    public static func rankedModels(from ids: [String]) -> [String] {
        let candidates = ids
            .filter { isUsableTextModel($0) }
            .map { ($0, score($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.localizedStandardCompare(rhs.0) == .orderedDescending
            }
        return candidates.map(\.0)
    }

    public static func supportsReasoning(_ id: String) -> Bool {
        let lower = id.lowercased()
        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("o5") { return true }
        guard lower.hasPrefix("gpt-") else { return false }
        let version = parsedVersion(lower)
        return version.major >= 5
    }

    private struct ModelScore: Comparable {
        let family: Int
        let major: Int
        let minor: Int
        let quality: Int
        let coding: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.family != rhs.family { return lhs.family < rhs.family }
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
            return lhs.coding < rhs.coding
        }
    }

    private static func score(_ id: String) -> ModelScore {
        let lower = id.lowercased()
        let version = parsedVersion(lower)
        let family: Int
        if lower.hasPrefix("gpt-") { family = 5 }
        else if lower.range(of: #"^o[0-9]"#, options: .regularExpression) != nil { family = 4 }
        else if lower.contains("codex") || lower.contains("coder") { family = 3 }
        else if lower.contains("chat") || lower.contains("text") { family = 2 }
        else { family = 1 }

        let quality: Int
        if lower.contains("sol") { quality = 5 }
        else if lower.contains("pro") { quality = 4 }
        else if lower.contains("codex") || lower.contains("coder") { quality = 4 }
        else if lower.contains("terra") { quality = 3 }
        else if lower.contains("luna") || lower.contains("mini") || lower.contains("nano") { quality = 1 }
        else { quality = 2 }

        let coding = (lower.contains("codex") || lower.contains("coder")) ? 2 : 1
        return ModelScore(family: family, major: version.major, minor: version.minor, quality: quality, coding: coding)
    }

    private static func isUsableTextModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let blocked = [
            "embedding", "image", "audio", "realtime", "transcrib", "whisper",
            "tts", "moderation", "search", "computer-use", "video", "sora", "instruct", "cyber"
        ]
        if blocked.contains(where: lower.contains) { return false }
        return lower.hasPrefix("gpt-") ||
            lower.range(of: #"^o[0-9]"#, options: .regularExpression) != nil ||
            ["codex", "coder", "chat", "claude", "deepseek", "qwen", "gemini", "llama", "mistral", "reasoner"].contains(where: lower.contains)
    }

    private static func parsedVersion(_ id: String) -> (major: Int, minor: Int) {
        let chars = Array(id)
        var index = 0
        while index < chars.count, !chars[index].isNumber { index += 1 }
        guard index < chars.count else { return (0, 0) }

        var majorText = ""
        while index < chars.count, chars[index].isNumber {
            majorText.append(chars[index])
            index += 1
        }

        var minorText = ""
        if index < chars.count, chars[index] == "." {
            index += 1
            while index < chars.count, chars[index].isNumber {
                minorText.append(chars[index])
                index += 1
            }
        }
        return (Int(majorText) ?? 0, Int(minorText) ?? 0)
    }
}

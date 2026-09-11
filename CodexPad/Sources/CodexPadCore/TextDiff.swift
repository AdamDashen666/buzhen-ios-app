import Foundation

public enum TextDiff {
    /// 线性时间的审查 Diff：保留共同前后文，只展开变化区域，避免大文件上产生平方级内存占用。
    public static func unified(old: String, new: String, path: String) -> String {
        if old == new { return "没有变化。" }
        if old.trimmingCharacters(in: .newlines) == new.trimmingCharacters(in: .newlines) {
            return "--- a/\(path)\n+++ b/\(path)\n@@ 文件末尾换行发生变化 @@\n-\(String(reflecting: old.suffix(80)))\n+\(String(reflecting: new.suffix(80)))"
        }
        let a = lines(old)
        let b = lines(new)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < a.count - prefix,
              suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let context = 3
        let beforeStart = max(0, prefix - context)
        let afterOldStart = a.count - suffix
        let afterNewStart = b.count - suffix
        let afterCount = min(context, suffix)

        var output = ["--- a/\(path)", "+++ b/\(path)", "@@ 修改预览 @@"]
        if beforeStart > 0 { output.append(" … 前面省略 \(beforeStart) 行未修改内容") }
        for line in a[beforeStart..<prefix] { output.append(" \(line)") }
        if prefix < afterOldStart {
            for line in a[prefix..<afterOldStart] { output.append("-\(line)") }
        }
        if prefix < afterNewStart {
            for line in b[prefix..<afterNewStart] { output.append("+\(line)") }
        }
        if afterCount > 0 {
            let start = a.count - suffix
            for line in a[start..<(start + afterCount)] { output.append(" \(line)") }
        }
        if suffix > afterCount { output.append(" … 后面省略 \(suffix - afterCount) 行未修改内容") }
        let limit = 1200
        if output.count > limit {
            output = Array(output.prefix(limit)) + ["… Diff 预览已截断；完整修改内容仍保留。"]
        }
        return String(output.joined(separator: "\n").prefix(100_000))
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }
}

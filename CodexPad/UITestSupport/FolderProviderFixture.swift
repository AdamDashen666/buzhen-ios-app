import SwiftUI

@main
struct FolderProviderFixture: App {
    init() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("外部示例项目")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("# 外部项目\n来自另一个 App 的文档目录。\n".utf8)
                .write(to: folder.appendingPathComponent("README.md"))
            try Data("external-workspace\n".utf8).write(to: folder.appendingPathComponent("外部标记.txt"))
        } catch { fatalError("Cannot prepare external test directory: \(error)") }
    }

    var body: some Scene {
        WindowGroup { Text("外部目录已准备").padding() }
    }
}

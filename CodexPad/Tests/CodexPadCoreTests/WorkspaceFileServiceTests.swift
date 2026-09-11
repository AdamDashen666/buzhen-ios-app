import XCTest
@testable import CodexPadCore

final class WorkspaceFileServiceTests: XCTestCase {
    private func fixture(_ operation: (URL, WorkspaceFileService) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root, WorkspaceFileService(rootURL: root))
    }

    func testCreateReadReplaceMoveDeleteAndUnicode() throws {
        try fixture { _, service in
            try service.apply(service.prepare(kind: .createDirectory, path: "中文目录"))
            try service.apply(service.prepare(kind: .create, path: "中文目录/你好.swift", content: "let a = 1\n"))
            let snapshot = try service.readSnapshot(path: "中文目录/你好.swift")
            XCTAssertEqual(snapshot.text, "let a = 1\n")
            let replace = try service.prepare(kind: .write, path: "中文目录/你好.swift", content: "2", oldText: "1")
            try service.apply(replace)
            XCTAssertEqual(try service.readSnapshot(path: replace.path).text, "let a = 2\n")
            let move = try service.prepare(kind: .move, path: replace.path, destination: "中文目录/新名字.swift")
            try service.apply(move)
            XCTAssertThrowsError(try service.readSnapshot(path: replace.path))
            try service.apply(service.prepare(kind: .delete, path: "中文目录/新名字.swift"))
            try service.apply(service.prepare(kind: .delete, path: "中文目录"))
            XCTAssertTrue(try service.listDirectory(path: "").isEmpty)
        }
    }

    func testConflictDoesNotOverwriteExternalChanges() throws {
        try fixture { root, service in
            try service.apply(service.prepare(kind: .create, path: "a.txt", content: "old"))
            let change = try service.prepare(kind: .write, path: "a.txt", content: "AI")
            let snapshot = try service.readSnapshot(path: "a.txt")
            try Data("external".utf8).write(to: root.appendingPathComponent("a.txt"))
            XCTAssertThrowsError(try service.apply(change))
            XCTAssertThrowsError(try service.save(path: "a.txt", text: "editor", baseline: snapshot.revision))
            XCTAssertEqual(try service.readSnapshot(path: "a.txt").text, "external")
        }
    }

    func testRejectRootTraversalAndDuplicateCreation() throws {
        try fixture { _, service in
            for path in ["", ".", "../escape", "/tmp/escape", "C:/escape"] {
                XCTAssertThrowsError(try service.prepare(kind: .delete, path: path))
                XCTAssertThrowsError(try service.prepare(kind: .create, path: path, content: "x"))
            }
            try service.apply(service.prepare(kind: .create, path: "a", content: "first"))
            XCTAssertThrowsError(try service.prepare(kind: .create, path: "a", content: "second"))
            let proposal = try service.prepare(kind: .create, path: "b", content: "AI")
            try service.apply(service.prepare(kind: .create, path: "b", content: "external"))
            XCTAssertThrowsError(try service.apply(proposal))
            XCTAssertEqual(try service.readSnapshot(path: "b").text, "external")
        }
    }

    func testSymlinksAndDanglingSymlinksCannotEscape() throws {
        try fixture { root, service in
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/tmp")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "/tmp/\(UUID().uuidString)")
            XCTAssertThrowsError(try service.readSnapshot(path: "outside/test"))
            XCTAssertThrowsError(try service.prepare(kind: .create, path: "outside/test", content: "x"))
            XCTAssertThrowsError(try service.prepare(kind: .create, path: "dangling", content: "x"))
            XCTAssertTrue(try service.listDirectory(path: "").isEmpty)
        }
    }

    func testParentReplacedBySymlinkAfterReviewIsRejected() throws {
        try fixture { root, service in
            try service.apply(service.prepare(kind: .createDirectory, path: "folder"))
            try service.apply(service.prepare(kind: .create, path: "folder/a", content: "old"))
            let change = try service.prepare(kind: .write, path: "folder/a", content: "new")
            try FileManager.default.removeItem(at: root.appendingPathComponent("folder"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("folder").path, withDestinationPath: "/tmp")
            XCTAssertThrowsError(try service.apply(change))
        }
    }

    func testLargeAndBinaryFilesDoNotEnterEditor() throws {
        try fixture { root, service in
            try Data(repeating: 65, count: WorkspaceFileService.maxTextBytes + 1).write(to: root.appendingPathComponent("large"))
            try Data([65, 0, 66]).write(to: root.appendingPathComponent("binary"))
            XCTAssertThrowsError(try service.readSnapshot(path: "large"))
            XCTAssertThrowsError(try service.readSnapshot(path: "binary"))
        }
    }

    func testSearchSkipsSecretsAndGeneratedDirectories() throws {
        try fixture { _, service in
            try service.apply(service.prepare(kind: .create, path: "hello.swift", content: "match\nother\nMATCH\n"))
            try service.apply(service.prepare(kind: .create, path: ".env", content: "match"))
            try service.apply(service.prepare(kind: .createDirectory, path: "node_modules"))
            try service.apply(service.prepare(kind: .create, path: "node_modules/a", content: "match"))
            let result = try service.search(query: "match", under: "", excludeSensitive: true)
            XCTAssertEqual(result.hits.map(\.line), [1, 3])
            XCTAssertFalse(result.truncated)
            XCTAssertTrue(try service.search(query: "", under: "", excludeSensitive: true).hits.isEmpty)
        }
    }

    func testAmbiguousReplaceAndNonEmptyDeleteAreRejected() throws {
        try fixture { _, service in
            try service.apply(service.prepare(kind: .createDirectory, path: "folder"))
            try service.apply(service.prepare(kind: .create, path: "folder/a", content: "aa"))
            XCTAssertThrowsError(try service.prepare(kind: .write, path: "folder/a", content: "b", oldText: "a"))
            XCTAssertThrowsError(try service.prepare(kind: .write, path: "folder/a", content: "b", oldText: ""))
            XCTAssertThrowsError(try service.prepare(kind: .delete, path: "folder"))
        }
    }
}

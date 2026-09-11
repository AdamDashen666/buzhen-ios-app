import SwiftUI

struct FileSidebarView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var agent: AgentController
    let onOpenFile: (String, Int) -> Void
    let onOpenProject: () -> Void
    let onCloseProject: () -> Void
    @State private var expanded = Set<String>()
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var searching = false
    @State private var operation: FileOperation?

    var body: some View {
        VStack(spacing: 0) {
            if workspace.rootURL != nil && !workspace.isOpening {
                HStack(spacing: 8) {
                    Text(workspace.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Menu {
                        Button("新建文件", systemImage: "doc.badge.plus") { operation = .init(kind: .create, path: "") }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { operation = .init(kind: .createDirectory, path: "") }
                    } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                        .accessibilityLabel("新建").disabled(!canMutate)
                }
                .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 4)
                Divider()
            }
            if workspace.isOpening {
                VStack(spacing: 16) {
                    ProgressView("正在打开项目…")
                    Button("取消") { workspace.cancelOpening() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.needsAuthorization {
                ContentUnavailableView {
                    Label("需要重新授权", systemImage: "folder.badge.questionmark")
                } actions: { Button("重新授权", action: onOpenProject).buttonStyle(.borderedProminent) }
            } else if workspace.rootURL == nil {
                ContentUnavailableView {
                    Label("尚未打开项目", systemImage: "folder")
                } actions: {
                    Button("打开文件夹", systemImage: "folder.badge.plus", action: onOpenProject)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("open-folder")
                }
            } else {
                if searching { ProgressView("正在搜索…").padding(12) }
                List {
                    if !query.isEmpty, let results {
                        ForEach(results.hits) { hit in
                            Button {
                                if hit.line == 0 {
                                    Task {
                                        do {
                                            guard let session = workspace.session else { return }
                                            _ = try await session.perform { try $0.readSnapshot(path: hit.path) }
                                            onOpenFile(hit.path, 1)
                                        } catch { workspace.errorMessage = WorkspaceStore.describe(error) }
                                    }
                                } else { onOpenFile(hit.path, hit.line) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.path).font(.caption.monospaced()).lineLimit(2)
                                    Text(hit.line > 0 ? "\(hit.line)：\(hit.preview)" : hit.preview)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                        if results.hits.isEmpty { Text("没有找到匹配项").foregroundStyle(.secondary) }
                        if results.truncated { Text("结果已达上限，请缩小搜索范围。").font(.caption).foregroundStyle(.orange) }
                        if results.skippedFiles > 0 { Text("已跳过 \(results.skippedFiles) 个不可读取的文件").font(.caption) }
                    } else {
                        if workspace.entries.isEmpty {
                            Text("文件夹为空").foregroundStyle(.secondary)
                        }
                        ForEach(visibleRows) { row in
                            entryRow(row.entry, depth: row.depth)
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay(alignment: .bottomTrailing) {
                    if workspace.isLoadingTree { ProgressView().padding() }
                }
            }
        }
        .navigationTitle("项目")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索文件与内容")
        .task(id: query) {
            guard !query.isEmpty, let session = workspace.session else { results = nil; searching = false; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let currentQuery = query
                let found = try await session.perform { try $0.search(query: currentQuery, under: "", excludeSensitive: true) }
                try Task.checkCancellation()
                guard workspace.session?.id == session.id else { return }
                results = found
                searching = false
            } catch is CancellationError {}
            catch { searching = false; workspace.errorMessage = WorkspaceStore.describe(error) }
        }
        .onChange(of: workspace.session?.id) { _, _ in query = ""; results = nil; expanded = [] }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("打开文件夹", systemImage: "folder.badge.plus", action: onOpenProject)
                        .disabled(agent.isRunning || workspace.isBusy)
                    Button("刷新文件列表", systemImage: "arrow.clockwise") { Task { await workspace.refreshTree() } }
                        .disabled(workspace.session == nil || workspace.isOpening || workspace.isLoadingTree)
                    Button("设置", systemImage: "gearshape") { app.showingSettings = true }
                    if workspace.session != nil {
                        Button("关闭项目", systemImage: "xmark.circle", role: .destructive, action: onCloseProject)
                            .disabled(agent.isRunning || workspace.isBusy)
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("项目菜单")
            }
        }
        .sheet(item: $operation) { FileOperationView(operation: $0) }
    }

    private var canMutate: Bool {
        workspace.session != nil && !workspace.isBusy && !agent.isRunning && agent.pendingChanges.isEmpty
    }
    private struct Row: Identifiable {
        let entry: WorkspaceEntry
        let depth: Int
        var id: String { entry.id }
    }
    private var visibleRows: [Row] {
        func flatten(_ entries: [WorkspaceEntry], depth: Int) -> [Row] {
            entries.flatMap { entry in
                [Row(entry: entry, depth: depth)] +
                    (expanded.contains(entry.path) ? flatten(workspace.children[entry.path] ?? [], depth: depth + 1) : [])
            }
        }
        return flatten(workspace.entries, depth: 0)
    }
    private func entryRow(_ entry: WorkspaceEntry, depth: Int) -> some View {
        Button {
            if entry.isDirectory {
                if expanded.contains(entry.path) { expanded.remove(entry.path) }
                else {
                    expanded.insert(entry.path)
                    Task { await workspace.loadDirectory(entry.path) }
                }
            } else { onOpenFile(entry.path, 1) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.isDirectory ? (expanded.contains(entry.path) ? "chevron.down" : "chevron.right") : "doc.text")
                    .font(.caption).frame(width: 14)
                if entry.isDirectory {
                    Image(systemName: "folder.fill").foregroundStyle(.teal)
                }
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if workspace.loadingDirectories.contains(entry.path) { ProgressView().controlSize(.mini) }
            }
            .padding(.leading, CGFloat(min(depth, 8)) * 12)
            .foregroundStyle(workspace.selectedPath == entry.path ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .listRowBackground(workspace.selectedPath == entry.path ? Color.accentColor.opacity(0.12) : nil)
        .contextMenu {
            Button("移动或重命名", systemImage: "pencil") { operation = .init(kind: .move, path: entry.path) }.disabled(!canMutate)
            Button("删除", systemImage: "trash", role: .destructive) { operation = .init(kind: .delete, path: entry.path) }.disabled(!canMutate)
        }
        .disabled(workspace.isSavingFile)
    }
}

private struct FileOperation: Identifiable {
    let id = UUID()
    let kind: PendingChange.Kind
    let path: String
}

private struct FileOperationView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let operation: FileOperation
    @State private var path = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !operation.path.isEmpty { Text(operation.path).font(.body.monospaced()) }
                    if operation.kind != .delete {
                        TextField(operation.kind == .move ? "目标相对路径" : "相对路径", text: $path)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Button(operation.kind == .delete ? "确认删除" : "确认", role: operation.kind == .delete ? .destructive : nil) {
                    guard let session = workspace.session else { return }
                    busy = true
                    let destination = path
                    Task {
                        do {
                            let change = try await session.perform {
                                try $0.prepare(kind: operation.kind, path: operation.path.isEmpty ? destination : operation.path,
                                               destination: operation.kind == .move ? destination : nil, content: "")
                            }
                            try await workspace.apply(change, in: session.id)
                            dismiss()
                        } catch { self.error = WorkspaceStore.describe(error) }
                        busy = false
                    }
                }
                .disabled(busy || (operation.kind != .delete && path.isEmpty))
                if busy { ProgressView("正在处理…") }
            }
            .navigationTitle(operation.kind == .delete ? "删除项目" : operation.kind == .move ? "移动或重命名" : "新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .onAppear { if operation.kind == .move { path = operation.path } }
        }
    }
}

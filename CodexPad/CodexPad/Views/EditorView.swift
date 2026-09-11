import SwiftUI
import UIKit

struct EditorView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var findRequest = 0
    @State private var confirmRevert = false

    var body: some View {
        VStack(spacing: 0) {
            if let path = workspace.selectedPath {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    if workspace.isDirty {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                            .accessibilityLabel("未保存")
                    }
                    Spacer(minLength: 0)
                    if workspace.isLoadingFile || workspace.isSavingFile { ProgressView().controlSize(.small) }
                }.padding(12)
                Divider()
                CodeTextView(text: $workspace.editorText, findRequest: findRequest,
                             documentID: path, line: workspace.editorLine)
                    .disabled(workspace.isLoadingFile || workspace.isOpening)
                    .accessibilityIdentifier("code-editor")
                Divider()
                HStack {
                    Text(workspace.fileNotice ?? (workspace.isDirty ? "未保存" : "已保存")).lineLimit(2)
                    Spacer()
                    Text("UTF-8").fixedSize()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            } else if workspace.isLoadingFile {
                ProgressView("正在打开文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("未打开文件", systemImage: "doc.text")
            }
        }
        .navigationTitle("编辑器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("查找与替换").accessibilityLabel("查找与替换")
                    .disabled(workspace.selectedPath == nil)
                Button { confirmRevert = true } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("重新读取文件").accessibilityLabel("重新读取文件")
                    .disabled(workspace.selectedPath == nil || workspace.isBusy)
                Button {
                    Task {
                        do { try await workspace.saveEditor() }
                        catch { workspace.errorMessage = WorkspaceStore.describe(error) }
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存").accessibilityLabel("保存")
                    .disabled(!workspace.isDirty || workspace.isBusy)
            }
        }
        .confirmationDialog("重新读取磁盘文件？", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("放弃本地编辑并重新读取", role: .destructive) {
                Task {
                    do { try await workspace.revertEditor() }
                    catch { workspace.errorMessage = WorkspaceStore.describe(error) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let findRequest: Int
    let documentID: String
    let line: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 10, bottom: 24, right: 10)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
        if context.coordinator.documentID != documentID || context.coordinator.line != line {
            context.coordinator.documentID = documentID
            context.coordinator.line = line
            let value = text as NSString
            var offset = 0
            for _ in 1..<max(1, line) {
                if offset >= value.length { break }
                offset = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            }
            let range = NSRange(location: min(offset, value.length), length: 0)
            view.selectedRange = range
            view.scrollRangeToVisible(range)
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: true)
        }
    }
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        var findRequest = 0
        var documentID = ""
        var line = 1
        init(_ parent: CodeTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

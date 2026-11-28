import SwiftUI

struct CompareInspectorView: View {
    @ObservedObject var tab: RepoTab
    @State private var collapsedFolderPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if case .loaded(let summary) = tab.compareState {
                    let destination = summary.headOid == "WORKTREE"
                        ? "Working Tree" : Self.branchName(summary.targetRef)
                    Text("merge-base \(summary.mergeBaseOid.prefix(7)) → \(destination)")
                        .font(.headline)
                        .lineLimit(1)
                        .help(summary.mergeBaseOid)
                    Text("\(summary.ahead) ahead · \(summary.behind) behind")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(summary.headOid == "WORKTREE"
                              ? "HEAD relative to \(Self.branchName(summary.targetRef))"
                              : "Branch relative to HEAD")
                } else {
                    Text("Compare Common Base").font(.headline)
                }
                Spacer()
                Button {
                    tab.closeCompare()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Comparison")
                .help("Close Comparison")
            }
            .paneHeaderBar()
            Divider()
            switch tab.compareState {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                EmptyDiffView(message: message)
            case .loaded(let summary):
                if summary.files.isEmpty {
                    EmptyDiffView(message: "No changes.")
                } else {
                    comparison(summary)
                }
            }
        }
    }

    private func comparison(_ summary: CompareSummary) -> some View {
        let files = Dictionary(summary.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = summary.files.map { FileChange(path: $0.path, status: $0.status, staged: false) }
        return HSplitView {
            ScrollView {
                LazyVStack(spacing: 2) {
                    FileTreeRows(changes: changes, collapsedFolderPaths: $collapsedFolderPaths) { _ in
                        EmptyView()
                    } fileRow: { change, name, depth in
                        Button {
                            tab.selectCompareFile(files[change.path])
                        } label: {
                            FileTreeFileLabel(
                                change: change,
                                name: name,
                                depth: depth,
                                isSelected: tab.compareFile?.path == change.path
                            ) { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        .help(files[change.path]?.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            DiffPaneContainer(
                filePath: tab.compareFile?.path,
                badgeText: nil,
                badgeColor: .blue,
                diffRows: tab.compareDiffRows,
                diffRevision: tab.compareFileRevision,
                emptyMessage: tab.compareDiffMessage ?? "No diff content for selection",
                canPreviewMarkdown: RepoTab.isMarkdownPath(tab.compareFile?.path),
                isMarkdownPreview: tab.compareShowsMarkdown,
                markdownPreviewState: tab.compareMarkdownState,
                repoRootPath: tab.activeCheckoutPath,
                previewSession: tab.session,
                previewCommitOid: summary.headOid == "WORKTREE" ? nil : summary.headOid,
                previewBaseOid: summary.mergeBaseOid,
                onToggleMarkdownPreview: { tab.toggleCompareMarkdown() }
            )
        }
    }

    private static func branchName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}

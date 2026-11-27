import SwiftUI

private enum CommitPaneTab: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case changes = "Changes"
    var id: String { rawValue }
}

/// Slim strip along the top of the bottom pane: the Commit / Changes tabs (when there are
/// any) on the left and the maximize toggle flush right. The panel collapses by dragging its
/// divider down; when collapsed this strip is all that remains visible.
private struct BottomPaneBar: View {
    var selection: Binding<CommitPaneTab>?
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false

    var body: some View {
        HStack(spacing: 4) {
            if let selection {
                ForEach(CommitPaneTab.allCases) { item in
                    Button {
                        selection.wrappedValue = item
                        // Picking a tab while collapsed reopens the panel at its last height.
                        if isCollapsed {
                            withAnimation(BottomPanelDefaults.animation) { isCollapsed = false }
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: selection.wrappedValue == item ? .semibold : .regular))
                            .foregroundStyle(selection.wrappedValue == item ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selection.wrappedValue == item ? Color.primary.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button {
                withAnimation(BottomPanelDefaults.animation) {
                    // From the collapsed strip this only reopens the panel at its last height;
                    // a second click maximizes.
                    if isCollapsed {
                        isCollapsed = false
                    } else {
                        isMaximized.toggle()
                    }
                }
            } label: {
                PhosphorIcon(glyph: .maximize, size: 16)
                    .foregroundStyle(isMaximized ? Color.accentColor : Color.primary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isMaximized ? Color.primary.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isCollapsed ? "Show the bottom panel"
                    : isMaximized ? "Restore the bottom panel size" : "Maximize the bottom panel"
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        // Collapsing is a divider drag, which VoiceOver and keyboard users can't do, so expose
        // the same toggle as a labeled action on the bar.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isCollapsed ? "Show Panel" : "Collapse Panel") {
            withAnimation(BottomPanelDefaults.animation) {
                if isMaximized { isMaximized = false }
                isCollapsed.toggle()
            }
        }
    }
}

struct CommitInspectorView: View {
    @ObservedObject var tab: RepoTab
    let commit: CommitRow
    @State private var pane: CommitPaneTab = .changes
    /// Shared by both tabs' file lists. Folders start expanded for every commit.
    @State private var collapsedFolderPaths: Set<String> = []
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @FocusState private var fileListFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Maximizing hands the arrow keys to the changed-files list; restoring hands them back to
    /// the commit list, so the keys always drive whatever the person is looking at.
    private func updateKeyboardFocus() {
        if isMaximized {
            if pane == .changes { fileListFocused = true }
        } else {
            fileListFocused = false
            NotificationCenter.default.post(name: .focusCommitTable, object: nil)
        }
    }

    /// Moves the selected changed file one visible row up or down, stopping at the ends.
    private func moveFileSelection(by delta: Int) {
        // At the first or last file there is nowhere to go; skip the diff reload.
        guard let path = FileTree.filePath(
            movingFrom: tab.selectedFilePath,
            by: delta,
            in: tab.commitDetail?.files ?? [],
            collapsedFolderPaths: collapsedFolderPaths
        ) else { return }
        tab.selectCommitFile(path)
    }

    var body: some View {
        VStack(spacing: 0) {
            BottomPaneBar(selection: $pane)
            Divider()
            if pane == .changes {
                header
                Divider()
            }
            switch pane {
            case .commit:
                CommitMessagePane(tab: tab, commit: commit, collapsedFolderPaths: $collapsedFolderPaths) { path in
                    tab.selectCommitFile(path)
                    pane = .changes
                }
            case .changes:
                changesPane
            }
        }
        .onAppear {
            // An inspector created while the panel is already maximized (a new selection, or
            // a relaunch) never sees `isMaximized` change, so claim focus here too.
            if isMaximized && pane == .changes {
                DispatchQueue.main.async { fileListFocused = true }
            }
        }
        .onChange(of: commit.oidHex) { collapsedFolderPaths = [] }
        .onChange(of: isMaximized) { updateKeyboardFocus() }
        .onChange(of: isCollapsed) {
            // A collapsed pane keeps the file list mounted but clipped, so the arrow keys would
            // keep selecting files nobody can see. Hand them back to the commit list.
            if isCollapsed {
                fileListFocused = false
                NotificationCenter.default.post(name: .focusCommitTable, object: nil)
            }
        }
        .onChange(of: pane) {
            if isMaximized && pane == .changes { fileListFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tab.commitDetail?.summary ?? commit.summary)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    tab.copyOid(commit.oidHex)
                } label: {
                    Label(commit.shortOid, systemImage: "doc.on.doc")
                        .font(.caption.monospaced())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy full SHA: \(commit.oidHex)")
            }

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    AvatarView(name: commit.authorName, email: tab.commitDetail?.authorEmail ?? "", size: 16)
                    Text(commit.authorName)
                }
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(commit.timestamp))))
                if let parents = tab.commitDetail?.parentOids, !parents.isEmpty {
                    Text("Parents: \(formatShortParents(parents))")
                        .font(.caption.monospaced())
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var changesPane: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("CHANGED FILES (\(tab.commitDetail?.files.count ?? 0))")
                        .sectionTitleStyle()
                    Spacer()
                    Button("All") {
                        tab.selectCommitFile(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(tab.selectedFilePath == nil ? .semibold : .regular))
                    .foregroundStyle(tab.selectedFilePath == nil ? Color.accentColor : Color.secondary)
                }
                .paneHeaderBar()

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        CommitFileList(tab: tab, collapsedFolderPaths: $collapsedFolderPaths) {
                            tab.selectCommitFile($0)
                        }
                    }
                    .focusable()
                    .focused($fileListFocused)
                    .focusEffectDisabled()
                    .arrowKeySelection { moveFileSelection(by: $0) }
                    .onChange(of: tab.selectedFilePath) {
                        if let path = tab.selectedFilePath { proxy.scrollTo(path) }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            DiffPaneContainer(
                filePath: tab.selectedFilePath ?? "All Changed Files",
                badgeText: commit.shortOid,
                badgeColor: .blue,
                diffRows: tab.diffRows,
                emptyMessage: "No diff content for selection",
                canPreviewMarkdown: RepoTab.isMarkdownPath(tab.selectedFilePath),
                isMarkdownPreview: tab.isMarkdownPreview,
                markdownPreviewState: tab.markdownPreviewState,
                repoRootPath: tab.activeCheckoutPath,
                previewSession: tab.session,
                previewCommitOid: commit.oidHex,
                onToggleMarkdownPreview: { tab.toggleMarkdownPreview() }
            )
        }
    }
}

/// The "Commit" tab: full message plus the changed-file list, scrollable as one page.
private struct CommitMessagePane: View {
    @ObservedObject var tab: RepoTab
    let commit: CommitRow
    @Binding var collapsedFolderPaths: Set<String>
    let onOpenFile: (String) -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(name: commit.authorName, email: tab.commitDetail?.authorEmail ?? "", size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AUTHOR")
                            .sectionTitleStyle(.caption2)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(commit.authorName).font(.title3.weight(.medium))
                            if let email = tab.commitDetail?.authorEmail, !email.isEmpty {
                                Text(email).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(commit.timestamp))))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("SHA").sectionTitleStyle(.caption2)
                        Text(commit.oidHex).font(.system(size: 12, design: .monospaced))
                    }
                    if let parents = tab.commitDetail?.parentOids, !parents.isEmpty {
                        GridRow {
                            Text("PARENTS").sectionTitleStyle(.caption2)
                            Text(formatShortParents(parents))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                .textSelection(.enabled)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(tab.commitDetail?.summary ?? commit.summary)
                        .font(.title3.weight(.medium))
                    if let body = tab.commitDetail?.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                Text("CHANGED FILES (\(tab.commitDetail?.files.count ?? 0))")
                    .sectionTitleStyle(.caption2)
                CommitFileList(
                    tab: tab,
                    collapsedFolderPaths: $collapsedFolderPaths,
                    selectsPath: false,
                    edgeInset: 0,
                    onSelect: onOpenFile
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CommitFileList: View {
    @ObservedObject var tab: RepoTab
    @Binding var collapsedFolderPaths: Set<String>
    var selectsPath = true
    /// Margin between the pane edge and the row highlight (matches the 10pt header inset).
    var edgeInset: CGFloat = 10
    let onSelect: (String) -> Void

    private static let indent: CGFloat = 14
    private static let chevronWidth: CGFloat = 10

    private var rows: [FlatFileRow] {
        FileTree.rows(from: tab.commitDetail?.files ?? [], collapsedFolderPaths: collapsedFolderPaths)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                Group {
                    switch row.kind {
                    case let .folder(name, folderPath, isExpanded):
                        folderRow(name: name, path: folderPath, isExpanded: isExpanded, depth: row.depth)
                    case let .file(change, name):
                        // The row's id is its path, which lets the list scroll to the selected file.
                        fileRow(change, name: name, depth: row.depth)
                    }
                }
                .padding(.horizontal, edgeInset)
            }
        }
        .padding(.vertical, 4)
    }

    private func folderRow(name: String, path: String, isExpanded: Bool, depth: Int) -> some View {
        Button {
            if isExpanded {
                collapsedFolderPaths.insert(path)
            } else {
                collapsedFolderPaths.remove(path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.chevronWidth)
                PhosphorIcon(glyph: .folder, size: 14)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * Self.indent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func fileRow(_ file: FileChange, name: String, depth: Int) -> some View {
        Button {
            onSelect(file.path)
        } label: {
            HStack(spacing: 6) {
                // Stands in for a folder's chevron, so badges line up with sibling folder icons.
                Color.clear.frame(width: Self.chevronWidth, height: 1)
                StatusBadge(status: file.status)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * Self.indent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                selectsPath && tab.selectedFilePath == file.path
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
    }
}

private func formatShortParents(_ parents: [String]) -> String {
    parents.map(\.shortOid).joined(separator: ", ")
}

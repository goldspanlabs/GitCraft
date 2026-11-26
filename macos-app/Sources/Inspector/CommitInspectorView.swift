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
                            withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = false }
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
                withAnimation(.easeInOut(duration: 0.18)) {
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
            withAnimation(.easeInOut(duration: 0.18)) {
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
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false
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

    /// Moves the selected changed file by `delta` rows, stopping at the first and last file.
    private func moveFileSelection(by delta: Int) {
        let files = tab.commitDetail?.files ?? []
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == tab.selectedFilePath }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), files.count - 1)
        } else {
            // Nothing selected ("All"): down picks the first file, up the last.
            next = delta > 0 ? 0 : files.count - 1
        }
        // At the first or last file, another press changes nothing; skip the diff reload.
        guard files[next].path != tab.selectedFilePath else { return }
        tab.selectCommitFile(files[next].path)
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
                CommitMessagePane(tab: tab, commit: commit) { path in
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
        .onChange(of: isMaximized) { updateKeyboardFocus() }
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("All") {
                        tab.selectCommitFile(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(tab.selectedFilePath == nil ? .semibold : .regular))
                    .foregroundStyle(tab.selectedFilePath == nil ? Color.accentColor : Color.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        CommitFileList(tab: tab) { tab.selectCommitFile($0) }
                    }
                    .focusable()
                    .focused($fileListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) {
                        moveFileSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveFileSelection(by: 1)
                        return .handled
                    }
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
                emptyMessage: "No diff content for selection"
            )
        }
    }
}

/// The "Commit" tab: full message plus the changed-file list, scrollable as one page.
private struct CommitMessagePane: View {
    @ObservedObject var tab: RepoTab
    let commit: CommitRow
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
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                        Text("SHA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(commit.oidHex).font(.system(size: 12, design: .monospaced))
                    }
                    if let parents = tab.commitDetail?.parentOids, !parents.isEmpty {
                        GridRow {
                            Text("PARENTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                CommitFileList(tab: tab, selectsPath: false, edgeInset: 0) { onOpenFile($0 ?? "") }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CommitFileList: View {
    @ObservedObject var tab: RepoTab
    var selectsPath = true
    /// Margin between the pane edge and the row highlight (matches the 10pt header inset).
    var edgeInset: CGFloat = 10
    let onSelect: (String?) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(tab.commitDetail?.files ?? [], id: \.path) { file in
                // The row's id is its path, which lets the list scroll to the selected file.
                Button {
                    onSelect(file.path)
                } label: {
                    HStack(spacing: 6) {
                        StatusBadge(status: file.status)
                        Text(file.path)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                    }
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
                .padding(.horizontal, edgeInset)
            }
        }
        .padding(.vertical, 4)
    }
}

private func formatShortParents(_ parents: [String]) -> String {
    parents.map { String($0.prefix(7)) }.joined(separator: ", ")
}

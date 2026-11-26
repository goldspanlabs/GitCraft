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
                    isMaximized.toggle()
                    // Maximizing from the collapsed strip goes straight to full size.
                    if isMaximized { isCollapsed = false }
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
            .help(isMaximized ? "Restore the bottom panel size" : "Maximize the bottom panel")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct CommitInspectorView: View {
    @ObservedObject var tab: RepoTab
    let commit: CommitRow
    @State private var pane: CommitPaneTab = .changes

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

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

                ScrollView {
                    CommitFileList(tab: tab) { tab.selectCommitFile($0) }
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

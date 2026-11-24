import SwiftUI

struct InspectorView: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        if let commit = tab.selectedCommit {
            CommitInspectorView(tab: tab, commit: commit)
        } else {
            WorkingChangesInspectorView(tab: tab)
        }
    }
}

private struct WorkingChangesInspectorView: View {
    @ObservedObject var tab: RepoTab
    @AppStorage(GitPreferences.autoStageOnCommitKey) private var autoStageOnCommit = true

    private var canCommit: Bool {
        GitPreferences.canCommit(
            summary: tab.commitSummary,
            stagedCount: tab.stagedFiles.count,
            changedCount: tab.totalChangesCount,
            autoStage: autoStageOnCommit,
            isBusy: tab.isBusy,
            amend: tab.amendCommit
        )
    }

    // This view has no tab strip, so a collapsed panel would have no way to reopen.
    @AppStorage(PersistentVSplit<EmptyView, EmptyView>.collapsedKey) private var isCollapsed = false

    var body: some View {
        HSplitView {
            // Left: Staged & Unstaged lists + Commit Composer
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Staged section
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("STAGED CHANGES (\(tab.stagedFiles.count))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !tab.stagedFiles.isEmpty {
                                    Button("Unstage All") { tab.unstageAll() }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 10)

                            if tab.stagedFiles.isEmpty {
                                Text("No staged changes")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(tab.stagedFiles, id: \.path) { file in
                                    WorkingFileRow(
                                        file: file,
                                        isSelected: tab.selectedFilePath == file.path && tab.selectedFileStaged,
                                        isStaged: true,
                                        onSelect: { tab.selectWorkingFile(file) },
                                        onToggleStaged: { tab.unstageFile(file.path) }
                                    )
                                }
                            }
                        }

                        Divider().padding(.horizontal, 10)

                        // Unstaged section
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("UNSTAGED CHANGES (\(tab.unstagedFiles.count))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !tab.unstagedFiles.isEmpty {
                                    Button("Stage All") { tab.stageAll() }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 10)

                            if tab.unstagedFiles.isEmpty {
                                Text("Working tree clean")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(tab.unstagedFiles, id: \.path) { file in
                                    WorkingFileRow(
                                        file: file,
                                        isSelected: tab.selectedFilePath == file.path && !tab.selectedFileStaged,
                                        isStaged: false,
                                        onSelect: { tab.selectWorkingFile(file) },
                                        onToggleStaged: { tab.stageFile(file.path) }
                                    )
                                    .contextMenu {
                                        Button("Stage File") { tab.stageFile(file.path) }
                                        if file.status == "?" {
                                            Divider()
                                            Button("Add to .gitignore") {
                                                tab.ignorePath(file.path, localOnly: false)
                                            }
                                            Button("Add to .git/info/exclude (local only)") {
                                                tab.ignorePath(file.path, localOnly: true)
                                            }
                                            Divider()
                                        }
                                        Button("Discard Changes…", role: .destructive) {
                                            tab.pendingConfirmation = .discardFile(path: file.path)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }

                Divider()

                // Commit Composer
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Commit summary…", text: $tab.commitSummary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .accessibilityIdentifier("commit-summary")

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $tab.commitBody)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                        if tab.commitBody.isEmpty {
                            Text("Extended description (optional)…")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 54)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                    HStack {
                        Toggle("Skip Hooks", isOn: $tab.skipHooks)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Toggle("Amend", isOn: Binding(
                            get: { tab.amendCommit },
                            set: { tab.setAmend($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        Spacer()
                        Button("Stash…") {
                            tab.isShowingStashSheet = true
                        }
                        .disabled(tab.totalChangesCount == 0 || tab.isBusy)

                        // A disabled prominent button renders as a heavy grey slab, so fall back
                        // to the regular bordered style until committing is possible.
                        if canCommit {
                            Button("Commit") {
                                tab.commitChanges()
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("commit-button")
                        } else {
                            Button("Commit") {}
                                .buttonStyle(.bordered)
                                .disabled(true)
                                .accessibilityIdentifier("commit-button")
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            .frame(minWidth: 260, idealWidth: 310, maxWidth: 420)

            // Right: Diff Viewer
            VStack(spacing: 0) {
                DiffHeaderBar(
                    filePath: tab.selectedFilePath,
                    badgeText: tab.selectedFilePath == nil ? nil : (tab.selectedFileStaged ? "Staged" : "Unstaged"),
                    badgeColor: tab.selectedFileStaged ? .green : .orange
                )
                Divider()
                if tab.diffRows.isEmpty {
                    EmptyDiffView(
                        message: tab.totalChangesCount == 0
                            ? "Working tree is clean"
                            : "Select a changed file to inspect its diff"
                    )
                } else {
                    DiffTableView(rows: tab.diffRows)
                }
            }
        }
        .onAppear {
            if isCollapsed { isCollapsed = false }
        }
    }
}

private enum CommitPaneTab: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case changes = "Changes"
    var id: String { rawValue }
}

/// Slim strip along the top of the bottom pane: the Commit / Changes tabs (when there are
/// any) on the left and the show/hide toggle flush right. When the panel is collapsed this
/// strip is all that remains visible.
private struct BottomPaneBar: View {
    var selection: Binding<CommitPaneTab>?
    @AppStorage(PersistentVSplit<EmptyView, EmptyView>.collapsedKey) private var isCollapsed = false

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
                withAnimation(.easeInOut(duration: 0.18)) { isCollapsed.toggle() }
            } label: {
                PhosphorIcon(glyph: .panelBottom, size: 16)
                    .foregroundStyle(isCollapsed ? Color.secondary : Color.primary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the bottom panel" : "Hide the bottom panel")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CommitInspectorView: View {
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
                    Text("Parents: \(parents.map { String($0.prefix(7)) }.joined(separator: ", "))")
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

            VStack(spacing: 0) {
                DiffHeaderBar(
                    filePath: tab.selectedFilePath ?? "All Changed Files",
                    badgeText: commit.shortOid,
                    badgeColor: .blue
                )
                Divider()
                if tab.diffRows.isEmpty {
                    EmptyDiffView(message: "No diff content for selection")
                } else {
                    DiffTableView(rows: tab.diffRows)
                }
            }
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
                            Text(parents.map { String($0.prefix(7)) }.joined(separator: ", "))
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

private struct WorkingFileRow: View {
    let file: FileChange
    let isSelected: Bool
    /// Checked means staged; toggling stages or unstages the file.
    let isStaged: Bool
    let onSelect: () -> Void
    let onToggleStaged: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { isStaged }, set: { _ in onToggleStaged() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(isStaged ? "Unstage file" : "Stage file")

            StatusBadge(status: file.status)
            Text(file.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        // The highlight's edges line up with the 10pt section headers above it.
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 10)
    }
}

private struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        case "R": return .purple
        default: return .orange
        }
    }

    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }
}

private struct DiffHeaderBar: View {
    let filePath: String?
    let badgeText: String?
    let badgeColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(filePath ?? "No file selected")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let badgeText {
                Text(badgeText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

private struct EmptyDiffView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

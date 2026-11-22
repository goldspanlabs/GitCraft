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
                                        actionIcon: "minus.circle",
                                        actionHelp: "Unstage file",
                                        onSelect: { tab.selectWorkingFile(file) },
                                        onAction: { tab.unstageFile(file.path) }
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
                                        actionIcon: "plus.circle",
                                        actionHelp: "Stage file",
                                        onSelect: { tab.selectWorkingFile(file) },
                                        onAction: { tab.stageFile(file.path) }
                                    )
                                    .contextMenu {
                                        Button("Stage File") { tab.stageFile(file.path) }
                                        Button("Discard Changes", role: .destructive) {
                                            tab.discardFile(file.path)
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
                        .textFieldStyle(.roundedBorder)

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
                        Text("\(tab.stagedFiles.count) staged")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Commit") {
                            tab.commitChanges()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(
                            tab.stagedFiles.isEmpty
                                || tab.commitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || tab.isBusy
                        )
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
    }
}

private struct CommitInspectorView: View {
    @ObservedObject var tab: RepoTab
    let commit: CommitRow

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Commit header metadata
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tab.commitDetail?.summary ?? commit.summary)
                        .font(.headline)
                        .lineLimit(2)

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
                    Label(commit.authorName, systemImage: "person.circle")
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(commit.timestamp))))
                    if let parents = tab.commitDetail?.parentOids, !parents.isEmpty {
                        Text("Parents: \(parents.map { String($0.prefix(7)) }.joined(separator: ", "))")
                            .font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let body = tab.commitDetail?.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            HSplitView {
                // Changed files in commit
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
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(tab.commitDetail?.files ?? [], id: \.path) { file in
                                Button {
                                    tab.selectCommitFile(file.path)
                                } label: {
                                    HStack(spacing: 6) {
                                        StatusBadge(status: file.status)
                                        Text(file.path)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        tab.selectedFilePath == file.path
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear
                                    )
                                    .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

                // Diff viewer
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
}

private struct WorkingFileRow: View {
    let file: FileChange
    let isSelected: Bool
    let actionIcon: String
    let actionHelp: String
    let onSelect: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(status: file.status)
            Text(file.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button(action: onAction) {
                Image(systemName: actionIcon)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(actionHelp)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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

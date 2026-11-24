import SwiftUI

/// The commit description in a larger editor, for longer messages. Edits go straight to the
/// composer's description, so closing the sheet keeps them.
struct ExpandedDescriptionSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extended description")
                .font(.system(size: 13, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

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
    @State private var isExpandingDescription = false

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
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false

    var body: some View {
        HSplitView {
            // Left: Staged & Unstaged lists + Commit Composer
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkingFileSection(
                            title: "STAGED CHANGES",
                            files: tab.stagedFiles,
                            actionTitle: "Unstage All",
                            emptyMessage: "No staged changes",
                            onAction: { tab.unstageAll() }
                        ) { file in
                            WorkingFileRow(
                                file: file,
                                isSelected: tab.selectedFilePath == file.path && tab.selectedFileStaged,
                                isStaged: true,
                                onSelect: { tab.selectWorkingFile(file) },
                                onToggleStaged: { tab.unstageFile(file.path) }
                            )
                        }

                        Divider()

                        WorkingFileSection(
                            title: "UNSTAGED CHANGES",
                            files: tab.unstagedFiles,
                            actionTitle: "Stage All",
                            emptyMessage: "Working tree clean",
                            onAction: { tab.stageAll() }
                        ) { file in
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
                    .padding(.vertical, 10)
                }

                Divider()

                // Commit Composer
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Commit summary…", text: $tab.commitSummary)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .onChange(of: tab.commitSummary) { _, newValue in
                            // Pasted text can carry line breaks; a summary is one line.
                            if newValue.contains(where: \.isNewline) {
                                tab.commitSummary = newValue.replacingOccurrences(
                                    of: "\r\n|\n|\r", with: " ", options: .regularExpression
                                )
                            }
                        }
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
                    .frame(height: 96)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isExpandingDescription = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(5)
                        }
                        .buttonStyle(.plain)
                        .help("Expand description")
                        .padding(3)
                    }
                    .sheet(isPresented: $isExpandingDescription) {
                        ExpandedDescriptionSheet(text: $tab.commitBody)
                    }
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
                            tab.presentNewStash()
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
            DiffPaneContainer(
                filePath: tab.selectedFilePath,
                badgeText: tab.selectedFilePath == nil ? nil : (tab.selectedFileStaged ? "Staged" : "Unstaged"),
                badgeColor: tab.selectedFileStaged ? .green : .orange,
                diffRows: tab.diffRows,
                emptyMessage: tab.totalChangesCount == 0
                    ? "Working tree is clean"
                    : "Select a changed file to inspect its diff"
            )
        }
        .onAppear {
            if isCollapsed { isCollapsed = false }
        }
    }
}

private struct WorkingFileSection<RowContent: View>: View {
    let title: String
    let files: [FileChange]
    let actionTitle: String
    let emptyMessage: String
    let onAction: () -> Void
    @ViewBuilder let row: (FileChange) -> RowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title) (\(files.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !files.isEmpty {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)

            if files.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach(files, id: \.path) { file in
                    row(file)
                }
            }
        }
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

struct StatusBadge: View {
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

struct DiffPaneContainer: View {
    let filePath: String?
    let badgeText: String?
    let badgeColor: Color
    let diffRows: [DiffRow]
    let emptyMessage: String

    var body: some View {
        VStack(spacing: 0) {
            DiffHeaderBar(
                filePath: filePath,
                badgeText: badgeText,
                badgeColor: badgeColor
            )
            Divider()
            if diffRows.isEmpty {
                EmptyDiffView(message: emptyMessage)
            } else {
                DiffTableView(rows: diffRows)
            }
        }
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

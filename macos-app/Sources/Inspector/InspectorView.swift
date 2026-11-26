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
    /// Set by clicking a file, so the arrow keys move through the file lists.
    @FocusState private var fileListFocused: Bool

    private var canCommit: Bool {
        tab.canCommit(autoStage: autoStageOnCommit)
    }

    // This view has no tab strip or maximize button, so a collapsed or maximized panel would
    // have no way to reopen or restore.
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false

    private var skipHooksToggle: some View {
        Toggle("Skip Hooks", isOn: $tab.skipHooks)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .lineLimit(1)
            .fixedSize()
    }

    private var amendToggle: some View {
        Toggle("Amend", isOn: Binding(
            get: { tab.amendCommit },
            set: { tab.setAmend($0) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize()
    }

    private func stashButton(fillWidth: Bool) -> some View {
        Button {
            tab.presentNewStash()
        } label: {
            Text("Stash…")
                .lineLimit(1)
                .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .fixedSize(horizontal: !fillWidth, vertical: true)
        .disabled(tab.totalChangesCount == 0 || tab.isBusy)
    }

    /// One combo control, always drawn with both halves. When committing isn't possible it turns
    /// grey and both halves are inert. With `fillWidth` the Commit half stretches to the row.
    @ViewBuilder
    private func commitControl(fillWidth: Bool) -> some View {
        let combo = HStack(spacing: 0) {
            // Padding and the hit shape live inside the label, so the whole
            // half is clickable, not just the text.
            Button {
                tab.commitChanges()
            } label: {
                Text("Commit")
                    .padding(.horizontal, 14)
                    .frame(maxWidth: fillWidth ? .infinity : nil, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)
            .accessibilityIdentifier("commit-button")

            Rectangle()
                .fill((canCommit ? Color.white : Color.secondary).opacity(0.35))
                .frame(width: 1)
                .padding(.vertical, 4)

            Menu {
                Button("Commit and Push") {
                    tab.commitChanges(pushAfter: true)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!canCommit)
            .help("More commit options")
            .accessibilityIdentifier("commit-menu")
        }
            .foregroundStyle(canCommit ? Color.white : Color.secondary)
            .frame(height: 23)
            .background(
                canCommit ? Color.accentColor : Color.secondary.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 6)
            )
        if fillWidth {
            combo
        } else {
            combo.fixedSize()
        }
    }

    private func select(_ file: FileChange) {
        fileListFocused = true
        tab.selectWorkingFile(file)
    }

    /// A partly staged file is in both lists, so a row is identified by its list and path.
    private static func rowID(path: String, staged: Bool) -> String {
        "\(staged ? "staged" : "unstaged"):\(path)"
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let path = tab.selectedFilePath else { return }
        proxy.scrollTo(Self.rowID(path: path, staged: tab.selectedFileStaged))
    }

    var body: some View {
        HSplitView {
            // Left: Staged & Unstaged lists + Commit Composer
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
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
                                    onSelect: { select(file) },
                                    onToggleStaged: { tab.unstageFile(file.path) }
                                )
                                .id(Self.rowID(path: file.path, staged: true))
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
                                    onSelect: { select(file) },
                                    onToggleStaged: { tab.stageFile(file.path) }
                                )
                                .id(Self.rowID(path: file.path, staged: false))
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
                    .focusable()
                    .focused($fileListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) {
                        tab.moveWorkingFileSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        tab.moveWorkingFileSelection(by: 1)
                        return .handled
                    }
                    .onChange(of: tab.selectedFilePath) { scrollToSelection(proxy) }
                    .onChange(of: tab.selectedFileStaged) { scrollToSelection(proxy) }
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
                        CommitBodyTextEditor(text: $tab.commitBody)
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
                        .accessibilityIdentifier("expand-description")
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

                    // Wide: everything on one row. Narrow: options on top, actions below, so
                    // labels never wrap and the Commit button keeps its size.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            skipHooksToggle
                            amendToggle
                            Spacer()
                            stashButton(fillWidth: false)
                            commitControl(fillWidth: false)
                        }
                        // Two equal columns, so each row's items line up with the one above.
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                skipHooksToggle.frame(maxWidth: .infinity, alignment: .leading)
                                amendToggle.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack(spacing: 8) {
                                stashButton(fillWidth: true)
                                commitControl(fillWidth: true)
                            }
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
            if isMaximized { isMaximized = false }
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
                        // A link-style button isn't reported as a button, so tests find it by id.
                        .accessibilityIdentifier(actionTitle.lowercased().replacingOccurrences(of: " ", with: "-"))
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
        // One accessibility element per row, so UI tests can tell the file list apart from the
        // diff header, which shows the same path.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(isStaged ? "staged" : "unstaged")-file:\(file.path)")
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
                .accessibilityIdentifier("diff-path")
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

private struct CommitBodyTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 12)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

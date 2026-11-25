import AppKit
import SwiftUI

struct NewWorktreeSheet: View {
    enum Mode: String, Hashable {
        case existingBranch
        case newBranch
        case detached
    }

    @ObservedObject var tab: RepoTab
    let source: RepoTab.WorktreeSource
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .newBranch
    @State private var existingBranch = ""
    @State private var branchName = ""
    @State private var folderPath = ""
    @State private var hasEditedPath = false
    @AppStorage("createWorktreeSwitch") private var switchAfterCreate = true
    @FocusState private var isBranchNameFocused: Bool

    /// Suggests a sibling directory next to `repoPath` named `<repo>-<suffix>`, replacing
    /// path separators and whitespace in `suffix` with `-`.
    static func suggestedPath(repoPath: String, suffix: String) -> String {
        let repoURL = URL(fileURLWithPath: repoPath)
        let parent = repoURL.deletingLastPathComponent()
        let repoName = repoURL.lastPathComponent
        let folderName = suggestedFolderName(repoName: repoName, suffix: suffix)
        return parent.appendingPathComponent(folderName).path
    }

    private static func suggestedFolderName(repoName: String, suffix: String) -> String {
        let cleaned = suffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\ \t\n"))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "\(repoName)-worktree" : "\(repoName)-\(cleaned)"
    }

    private var availableLocalBranches: [String] {
        let checkedOut = Set(tab.worktrees.compactMap(\.branch))
        return tab.branches
            .filter { !$0.isRemote && !checkedOut.contains($0.name) }
            .map(\.name)
    }

    private var canUseExistingBranchMode: Bool {
        switch source {
        case .head:
            return !availableLocalBranches.isEmpty
        case let .localBranch(_, isCheckedOut):
            return !isCheckedOut
        case .remoteBranch, .commit:
            return false
        }
    }

    /// Opened from a local branch that no worktree has checked out: there's nothing to choose,
    /// the branch is simply checked out in a new folder.
    private var isPlainBranchCheckout: Bool {
        if case .localBranch(_, false) = source { return true }
        return false
    }

    private var startPoint: String? {
        switch source {
        case .head:
            return nil
        case let .localBranch(name, _), let .remoteBranch(name):
            return name
        case let .commit(oid):
            return oid
        }
    }

    private var startPointDisplay: String {
        if let start = startPoint {
            if start.count == 40, start.allSatisfy(\.isHexDigit) {
                return String(start.prefix(7))
            }
            return start
        }
        return tab.currentBranch.isEmpty ? "HEAD" : tab.currentBranch
    }

    private var activeSuffix: String {
        switch mode {
        case .existingBranch:
            return existingBranch
        case .newBranch:
            return branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? startPointDisplay
                : branchName
        case .detached:
            return startPointDisplay
        }
    }

    private var confirmDisabled: Bool {
        if folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        switch mode {
        case .existingBranch:
            return existingBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .newBranch:
            return branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .detached:
            return false
        }
    }

    var body: some View {
        ActionSheetLayout(
            title: "Create Worktree",
            subtitle: isPlainBranchCheckout
                ? "Check out this branch in a separate working directory."
                : "Check out another working directory sharing this repository's Git history.",
            confirmLabel: switchAfterCreate ? "Create and Switch" : "Create",
            confirmDisabled: confirmDisabled,
            onCancel: { dismiss() },
            onConfirm: createWorktreeNow
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                if !isPlainBranchCheckout {
                    GridRow {
                        Text("Checkout:")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .gridColumnAlignment(.trailing)

                        Picker("", selection: $mode) {
                            if canUseExistingBranchMode {
                                Text("Existing Branch").tag(Mode.existingBranch)
                            }
                            Text("New Branch").tag(Mode.newBranch)
                            Text("Detached HEAD").tag(Mode.detached)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 440)
                    }
                }

                if mode != .existingBranch {
                    GridRow {
                        Text("Start at:")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        if case let .commit(oid) = source {
                            CommitPreviewRow(
                                oid: oid,
                                commit: tab.commits.first { $0.oidHex == oid }
                            )
                        } else {
                            HStack(spacing: 5) {
                                PhosphorIcon(glyph: .branch)
                                    .foregroundStyle(.secondary)
                                Text(startPointDisplay)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                if mode == .existingBranch {
                    GridRow {
                        Text(isPlainBranchCheckout ? "Local branch:" : "Branch:")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        if case let .localBranch(name, false) = source {
                            HStack(spacing: 5) {
                                PhosphorIcon(glyph: .branch)
                                    .foregroundStyle(.secondary)
                                Text(name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Picker("", selection: $existingBranch) {
                                ForEach(availableLocalBranches, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 440)
                        }
                    }
                } else if mode == .newBranch {
                    GridRow {
                        Text("Branch name:")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 6) {
                            PhosphorIcon(glyph: .branch)
                                .foregroundStyle(.secondary)
                            TextField("Enter Branch Name", text: $branchName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($isBranchNameFocused)
                                .accessibilityIdentifier("new-worktree-branch")
                                .onChange(of: branchName) { _, newValue in
                                    if let replacement = BranchSpaceReplacement.current.replacement,
                                       newValue.contains(" ")
                                    {
                                        branchName = newValue.replacingOccurrences(of: " ", with: replacement)
                                    }
                                    syncSuggestedPathIfNeeded()
                                }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(width: 440)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    isBranchNameFocused
                                        ? Color.accentColor.opacity(0.65)
                                        : Color(nsColor: .separatorColor),
                                    lineWidth: isBranchNameFocused ? 2.5 : 1
                                )
                        )
                    }
                }

                GridRow {
                    Text("Folder:")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .gridColumnAlignment(.trailing)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            TextField(
                                "Path for new worktree",
                                text: Binding(
                                    get: { folderPath },
                                    set: { newValue in
                                        folderPath = newValue
                                        hasEditedPath = true
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 364)
                            .accessibilityIdentifier("new-worktree-folder")

                            Button("Choose…", action: chooseFolder)
                                .controlSize(.regular)
                        }

                        Toggle("Switch to worktree after creating", isOn: $switchAfterCreate)
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            configureDefaults()
        }
        .onChange(of: mode) { _, _ in
            syncSuggestedPathIfNeeded()
            if mode == .newBranch {
                isBranchNameFocused = true
            }
        }
        .onChange(of: existingBranch) { _, _ in
            syncSuggestedPathIfNeeded()
        }
    }

    private func configureDefaults() {
        switch source {
        case .head:
            mode = .newBranch
            existingBranch = availableLocalBranches.first ?? ""
        case let .localBranch(name, isCheckedOut):
            mode = isCheckedOut ? .newBranch : .existingBranch
            existingBranch = name
        case let .remoteBranch(name):
            mode = .newBranch
            if let slash = name.firstIndex(of: "/") {
                let candidate = String(name[name.index(after: slash)...])
                let localExists = tab.branches.contains { !$0.isRemote && $0.name == candidate }
                if !candidate.isEmpty && !localExists {
                    branchName = candidate
                }
            }
        case .commit:
            mode = .detached
        }
        folderPath = Self.suggestedPath(repoPath: tab.repoPath, suffix: activeSuffix)
        hasEditedPath = false
        if mode == .newBranch {
            isBranchNameFocused = true
        }
    }

    private func syncSuggestedPathIfNeeded() {
        guard !hasEditedPath else { return }
        folderPath = Self.suggestedPath(repoPath: tab.repoPath, suffix: activeSuffix)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let currentParent = URL(fileURLWithPath: folderPath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: currentParent.path) {
            panel.directoryURL = currentParent
        } else {
            panel.directoryURL = URL(fileURLWithPath: tab.repoPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: chosen.path)) ?? []
        if contents.isEmpty {
            folderPath = chosen.path
        } else {
            let repoName = URL(fileURLWithPath: tab.repoPath).lastPathComponent
            let name = Self.suggestedFolderName(repoName: repoName, suffix: activeSuffix)
            folderPath = chosen.appendingPathComponent(name).path
        }
        hasEditedPath = true
    }

    private func createWorktreeNow() {
        switch mode {
        case .existingBranch:
            tab.addWorktree(
                path: folderPath,
                branchName: nil,
                startPoint: existingBranch,
                detach: false,
                switchAfterCreate: switchAfterCreate
            )
        case .newBranch:
            tab.addWorktree(
                path: folderPath,
                branchName: branchName,
                startPoint: startPoint,
                detach: false,
                switchAfterCreate: switchAfterCreate
            )
        case .detached:
            tab.addWorktree(
                path: folderPath,
                branchName: nil,
                startPoint: startPoint,
                detach: true,
                switchAfterCreate: switchAfterCreate
            )
        }
        dismiss()
    }
}

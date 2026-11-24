import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var tab: RepoTab
    // Remembered across launches (shared by every repository window).
    @AppStorage("sidebar.localBranchesExpanded") private var isLocalBranchesExpanded = true
    @AppStorage("sidebar.worktreesExpanded") private var isWorktreesExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var isRemotesExpanded = false
    @AppStorage("sidebar.tagsExpanded") private var isTagsExpanded = false
    @AppStorage("sidebar.stashesExpanded") private var isStashesExpanded = false
    @State private var collapsedFolderIDs: Set<String> = []

    /// The default branch is pinned above the rest of Local Branches, so it's kept out of the tree.
    private var localBranches: [BranchInfo] {
        tab.branches.filter { !$0.isRemote && !$0.isDefault }
    }

    private var defaultLocalBranch: BranchInfo? {
        tab.branches.first { !$0.isRemote && $0.isDefault }
    }

    private var remoteBranches: [BranchInfo] {
        tab.branches.filter { $0.isRemote }
    }

    private var localBranchRows: [FlatBranchRow] {
        BranchTreeNode.buildFlattenedRows(
            from: localBranches,
            scope: "local",
            collapsedFolderIDs: collapsedFolderIDs
        )
    }

    /// The commit HEAD points at when HEAD is detached. The graph only carries a HEAD ref in that case.
    private var detachedHeadOid: String? {
        tab.commits.first { commit in commit.refs.contains { $0.kind == .head } }?.oidHex
    }

    private var remoteBranchRows: [FlatBranchRow] {
        BranchTreeNode.buildFlattenedRows(
            from: remoteBranches,
            scope: "remote",
            collapsedFolderIDs: collapsedFolderIDs
        )
    }

    private func toggleFolder(_ folderID: String) {
        withAnimation(.easeInOut(duration: 0.14)) {
            if collapsedFolderIDs.contains(folderID) {
                collapsedFolderIDs.remove(folderID)
            } else {
                collapsedFolderIDs.insert(folderID)
            }
        }
    }

    var body: some View {
        List {
            Section(isExpanded: $isLocalBranchesExpanded) {
                if isLocalBranchesExpanded {
                    if let headOid = detachedHeadOid {
                        DetachedHeadRowView(tab: tab, oidHex: headOid)
                    }
                    if let pinned = defaultLocalBranch {
                        LocalBranchRowView(
                            tab: tab,
                            branch: pinned,
                            displayName: pinned.name,
                            depth: 0
                        )
                    }
                    ForEach(localBranchRows) { row in
                        switch row.kind {
                        case let .folder(name, folderID, isExpanded):
                            BranchFolderRowView(
                                name: name,
                                depth: row.depth,
                                isExpanded: isExpanded,
                                isTopLevelRemote: false
                            ) {
                                toggleFolder(folderID)
                            }
                        case let .branch(branch, leafName):
                            LocalBranchRowView(
                                tab: tab,
                                branch: branch,
                                displayName: leafName,
                                depth: row.depth
                            )
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "LOCAL BRANCHES") {
                    [.item("New Branch…") {
                        tab.presentNewBranch()
                    }]
                }
            }

            Section(isExpanded: $isWorktreesExpanded) {
                if isWorktreesExpanded {
                    ForEach(tab.worktrees, id: \.path) { worktree in
                        WorktreeRowView(tab: tab, worktree: worktree)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "WORKTREES") {
                    [.item(
                        "Prune Stale Worktrees",
                        enabled: !tab.isBusy && tab.worktrees.contains { $0.isPrunable }
                    ) {
                        tab.pruneWorktrees()
                    }]
                }
            }

            Section(isExpanded: $isRemotesExpanded) {
                if isRemotesExpanded {
                    if tab.remotes.isEmpty {
                        Text("No remotes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(remoteBranchRows) { row in
                        switch row.kind {
                        case let .folder(name, folderID, isExpanded):
                            BranchFolderRowView(
                                name: name,
                                depth: row.depth,
                                isExpanded: isExpanded,
                                isTopLevelRemote: row.depth == 0
                            ) {
                                toggleFolder(folderID)
                            }
                        case let .branch(branch, leafName):
                            RemoteBranchRowView(
                                tab: tab,
                                branch: branch,
                                displayName: leafName,
                                depth: row.depth
                            )
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "REMOTES") {
                    var entries: [MenuEntry] = [
                        .item("Add Remote…") {
                            tab.presentRemotes(startsAdding: true)
                        },
                        .item("Manage Remotes…", enabled: !tab.remotes.isEmpty) {
                            tab.presentRemotes(startsAdding: false)
                        },
                    ]
                    if !tab.remotes.isEmpty {
                        entries.append(.separator)
                        for remote in tab.remotes {
                            entries.append(.item("Fetch \(remote.name)", enabled: !tab.isBusy) {
                                tab.fetchRemote(remote.name)
                            })
                        }
                    }
                    return entries
                }
            }

            Section(isExpanded: $isTagsExpanded) {
                if isTagsExpanded {
                    if tab.tags.isEmpty {
                        Text("No tags")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tab.tags, id: \.fullRef) { tag in
                            HStack(spacing: 6) {
                                PhosphorIcon(glyph: .tag)
                                    .foregroundStyle(.orange)
                                    .frame(width: 16, alignment: .center)
                                Text(tag.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                tab.scrollToCommit(oidHex: tag.targetOidHex)
                            }
                            .nativeContextMenu {
                                [.item("Push \(tag.name) to origin") {
                                    tab.pushTag(tag.name)
                                }, .separator,
                                 .item("Delete \(tag.name) (Local)…") {
                                    tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: false)
                                 },
                                 .item("Delete \(tag.name) (Local & Remote)…") {
                                    tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: true)
                                 }]
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "TAGS") {
                    [.item("New Tag…") {
                        tab.presentNewTag()
                    }]
                }
            }

            Section(isExpanded: $isStashesExpanded) {
                if isStashesExpanded {
                    if tab.stashes.isEmpty {
                        Text("No stashes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tab.stashes, id: \.index) { stash in
                            HStack(spacing: 6) {
                                PhosphorIcon(glyph: .archive)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, alignment: .center)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(stash.message)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text(stash.name)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .nativeContextMenu {
                                [.item("Pop \(stash.name)") {
                                    tab.stashPop(stash.index)
                                }, .item("Apply \(stash.name)") {
                                    tab.stashApply(stash.index)
                                }, .separator,
                                 .item("Drop \(stash.name)…") {
                                    tab.pendingConfirmation = .dropStash(index: stash.index, name: stash.name)
                                 }]
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "STASHES") {
                    [.item("Stash Changes…", enabled: tab.totalChangesCount > 0 && !tab.isBusy) {
                        tab.presentNewStash()
                    }]
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Section title row with a right-click menu. The menu is a plain `NSMenu`, because
/// SwiftUI's `.contextMenu` makes macOS append a system "Ask Siri" item on text rows.
private struct SectionHeaderLabel: View {
    let title: String
    let entries: () -> [MenuEntry]

    var body: some View {
        // The disclosure chevron is drawn natively by the sidebar `Section(isExpanded:)`.
        HStack {
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .nativeContextMenu(entries)
    }
}

private struct BranchFolderRowView: View {
    let name: String
    let depth: Int
    let isExpanded: Bool
    let isTopLevelRemote: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .center)

            PhosphorIcon(glyph: isTopLevelRemote ? .cloud : .folder)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

/// One checkout of the repository. A tap scrolls the graph to its HEAD and a double-tap
/// switches the tab to it, matching branch rows. The menu holds the checkout actions.
private struct WorktreeRowView: View {
    @ObservedObject var tab: RepoTab
    let worktree: WorktreeInfo

    private var isActive: Bool {
        tab.activeCheckoutPath == worktree.path
    }

    private var title: String {
        worktree.branch ?? "detached at \(worktree.headOidHex.prefix(7))"
    }

    private var subtitle: String {
        worktree.isMain ? "main checkout" : URL(fileURLWithPath: worktree.path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            PhosphorIcon(glyph: .folder)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if worktree.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(worktree.lockReason.map { "Locked: \($0)" } ?? "Locked")
            }
            if worktree.isPrunable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("The folder is missing. Prune Stale Worktrees to forget it.")
            }
            if worktree.dirtyCount > 0 {
                Text("\(worktree.dirtyCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .help("Changed files in this checkout")
            }
            if isActive {
                Text("CURRENT")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        // Single tap must fire immediately, as on branch rows (see BranchRowContainer).
        .onTapGesture {
            tab.scrollToCommit(oidHex: worktree.headOidHex)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !worktree.isPrunable {
                    tab.switchCheckout(to: worktree.path)
                }
            }
        )
        .nativeContextMenu { menuEntries }
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if !isActive {
            entries.append(.item("Switch to Worktree", enabled: !tab.isBusy && !worktree.isPrunable) {
                tab.switchCheckout(to: worktree.path)
            })
        }
        entries.append(.item("Reveal in Finder", enabled: !worktree.isPrunable) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
        })
        entries.append(.item("Copy Path") {
            Clipboard.copy(worktree.path)
        })
        if !worktree.isMain {
            entries.append(.separator)
            if worktree.isLocked {
                entries.append(.item("Unlock Worktree", enabled: !tab.isBusy) {
                    tab.unlockWorktree(worktree.path)
                })
            } else {
                entries.append(.item("Lock Worktree", enabled: !tab.isBusy && !worktree.isPrunable) {
                    tab.lockWorktree(worktree.path)
                })
            }
        }
        return entries
    }
}

/// Shown in Local Branches while HEAD is detached: the commit HEAD sits on, with no branch name.
private struct DetachedHeadRowView: View {
    @ObservedObject var tab: RepoTab
    let oidHex: String

    var body: some View {
        HStack(spacing: 6) {
            PhosphorIcon(glyph: .branch)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text("HEAD (detached)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            tab.scrollToCommit(oidHex: oidHex)
        }
    }
}

/// Shared row chrome for local and remote branch rows: indentation, branch icon, name,
/// immediate single-click reveal, double-click checkout, and native context menu.
private struct BranchRowContainer<Trailing: View>: View {
    @ObservedObject var tab: RepoTab
    let branch: BranchInfo
    let displayName: String
    let depth: Int
    let menuEntries: () -> [MenuEntry]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            // Align leaf branch icon under folder icon when nested, or flush when top-level
            PhosphorIcon(glyph: .branch)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            trailing()
        }
        .padding(.leading, CGFloat(depth) * 14 + (depth > 0 ? 15 : 0))
        .contentShape(Rectangle())
        // Single tap must fire immediately; a count:1 gesture declared next to a
        // count:2 one makes SwiftUI wait out the double-click interval first.
        .onTapGesture {
            tab.scrollToCommit(oidHex: branch.targetOidHex)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                tab.checkoutBranch(branch.name)
            }
        )
        .nativeContextMenu(menuEntries)
    }
}

private struct LocalBranchRowView: View {
    @ObservedObject var tab: RepoTab
    let branch: BranchInfo
    let displayName: String
    let depth: Int

    var body: some View {
        BranchRowContainer(
            tab: tab,
            branch: branch,
            displayName: displayName,
            depth: depth,
            menuEntries: { menuEntries }
        ) {
            if branch.isMerged {
                Text("merged")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
                    .help("Fully merged into origin's default branch")
            }

            if branch.isHead || branch.ahead > 0 || branch.behind > 0 {
                HStack(spacing: 6) {
                    if branch.isHead {
                        Text("HEAD")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                    if branch.isHead && (branch.ahead > 0 || branch.behind > 0) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 10)
                    }
                    if branch.ahead > 0 {
                        Text("↑\(branch.ahead)")
                    }
                    if branch.behind > 0 {
                        Text("↓\(branch.behind)")
                    }
                }
                .font(branch.isHead ? .caption2.weight(.bold).monospacedDigit() : .caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(branch.isHead ? 0.2 : 0.12))
                .clipShape(Capsule())
            }
        }
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if !branch.isHead {
            entries.append(.item("Checkout...") {
                tab.checkoutBranch(branch.name)
            })
            entries.append(.item("Merge into '\(tab.currentBranch)'") {
                tab.mergeBranch(branch.name)
            })
        }
        entries.append(.item("New Branch...") {
            tab.presentNewBranch(startPoint: branch.name)
        })
        if !branch.isHead {
            entries.append(.separator)
            entries.append(.item("Delete...") {
                tab.pendingConfirmation = .deleteBranch(name: branch.name, force: false)
            })
        }
        return entries
    }
}

private struct RemoteBranchRowView: View {
    @ObservedObject var tab: RepoTab
    let branch: BranchInfo
    let displayName: String
    let depth: Int

    var body: some View {
        BranchRowContainer(
            tab: tab,
            branch: branch,
            displayName: displayName,
            depth: depth
        ) {
            [.item("Checkout...") {
                tab.checkoutBranch(branch.name)
            }, .item("New Branch...") {
                tab.presentNewBranch(startPoint: branch.name)
            }, .separator,
             .item("Delete '\(branch.name)'") {
                tab.pendingConfirmation = .deleteRemoteBranch(name: branch.name)
             }]
        } trailing: {
            EmptyView()
        }
    }
}

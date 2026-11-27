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

    private func remoteContextMenuEntries(for remote: RemoteInfo) -> [MenuEntry] {
        let displayName = remote.name == "origin" ? "Origin" : remote.name
        let autoFetchEnabled = AutoFetchInterval.currentMinutes > 0
        return [
            .item("Fetch \(remote.name)", enabled: !tab.isBusy) {
                tab.fetchRemote(remote.name)
            },
            .item("Edit \(remote.name)", enabled: !tab.isBusy) {
                tab.presentEditRemote(remote)
            },
            .item("Delete \(remote.name)", enabled: !tab.isBusy) {
                tab.pendingConfirmation = .removeRemote(name: remote.name)
            },
            .separator,
            .item("Fetch \(displayName) Automatically", checked: autoFetchEnabled) {
                let next = autoFetchEnabled
                    ? AutoFetchInterval.off.rawValue
                    : AutoFetchInterval.fiveMinutes.rawValue
                UserDefaults.standard.set(next, forKey: AutoFetchInterval.storageKey)
            },
            .item("Add New Remote", enabled: !tab.isBusy) {
                tab.presentAddRemote()
            },
        ]
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

            Section(isExpanded: $isRemotesExpanded) {
                if isRemotesExpanded {
                    if tab.remotes.isEmpty {
                        EmptySectionLabel(text: "No remotes")
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
                            .nativeContextMenu {
                                guard row.depth == 0,
                                      let remote = tab.remotes.first(where: { $0.name == name })
                                else { return [] }
                                return remoteContextMenuEntries(for: remote)
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
                    [
                        .item("Add Remote", enabled: !tab.isBusy) {
                            tab.presentAddRemote()
                        },
                    ]
                }
            }

            Section(isExpanded: $isWorktreesExpanded) {
                if isWorktreesExpanded {
                    if !tab.worktrees.contains(where: { !$0.isMain }) {
                        EmptySectionLabel(text: "No worktrees")
                    } else {
                        ForEach(tab.worktrees, id: \.path) { worktree in
                            WorktreeRowView(tab: tab, worktree: worktree)
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "WORKTREES") {
                    [
                        .item("New Worktree…", enabled: !tab.isBusy) {
                            tab.presentNewWorktree(source: .head)
                        },
                        .item(
                            "Prune Stale Worktrees",
                            enabled: !tab.isBusy && tab.worktrees.contains { $0.isPrunable }
                        ) {
                            tab.pruneWorktrees()
                        },
                    ]
                }
            }

            Section(isExpanded: $isTagsExpanded) {
                if isTagsExpanded {
                    if tab.tags.isEmpty {
                        EmptySectionLabel(text: "No tags")
                    } else {
                        ForEach(tab.tags, id: \.fullRef) { tag in
                            TagRowView(tab: tab, tag: tag)
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
                        EmptySectionLabel(text: "No stashes")
                    } else {
                        ForEach(tab.stashes, id: \.index) { stash in
                            StashRowView(tab: tab, stash: stash)
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

/// The placeholder a sidebar section shows when it has nothing to list.
private struct EmptySectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct TagRowView: View {
    @ObservedObject var tab: RepoTab
    let tag: TagInfo

    var body: some View {
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
        .sidebarRowHighlight()
        .onTapGesture {
            tab.scrollToCommit(oidHex: tag.targetOidHex)
        }
        .nativeContextMenu {
            [.item("Push \(tag.name) to \(tab.defaultRemoteName)") {
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

private struct StashRowView: View {
    @ObservedObject var tab: RepoTab
    let stash: StashInfo

    var body: some View {
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
        .sidebarRowHighlight(showsPress: false)
        // One accessibility element per row, so UI tests can find a stash by index.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stash-row:\(stash.index)")
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

private struct BranchFolderRowView: View {
    let name: String
    let depth: Int
    let isExpanded: Bool
    let isTopLevelRemote: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 9, alignment: .center)

            PhosphorIcon(glyph: isTopLevelRemote ? .cloud : .folder)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 8)
        .contentShape(Rectangle())
        .sidebarRowHighlight()
        .onHover { isHovered = $0 }
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

    /// What's checked out here: the branch, or the commit when HEAD is detached.
    private var branchLabel: String {
        worktree.branch ?? "detached at \(worktree.headOidHex.shortOid)"
    }

    /// A worktree is identified by its folder, like the repository's own name for the main checkout.
    private var title: String {
        worktree.path.folderName
    }

    /// The branch is already listed under Local Branches, so only a detached HEAD, which has
    /// no branch there, gets a subtitle.
    private var subtitle: String? {
        worktree.branch == nil ? branchLabel : nil
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
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
                    .accessibilityIdentifier("worktree-current:\(branchLabel)")
            }
        }
        .contentShape(Rectangle())
        .sidebarRowHighlight()
        .help("\(worktree.path)\n\(branchLabel)")
        // Make the row its own accessibility element. Without this the identifier is pushed
        // down onto the leaf views (the folder icon) and overwrites the CURRENT badge's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worktree-row:\(branchLabel)")
        // Single tap must fire immediately, as on branch rows (see BranchRowContainer).
        .onTapGesture {
            tab.scrollToCommit(oidHex: worktree.headOidHex)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !worktree.isPrunable else { return }
                let before = tab.activeCheckoutPath
                tab.switchCheckout(to: worktree.path)
                guard tab.activeCheckoutPath != before else { return }
                // Each click of the double-click also fires the single tap above, which selects
                // this worktree's head commit, and that can land after the switch. Once this
                // click is handled, go back to Working Changes so the new checkout's changes show.
                DispatchQueue.main.async { tab.scrollToWorkingChanges() }
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
            entries.append(.item("Remove Worktree…", enabled: !tab.isBusy && tab.canRemoveWorktree(worktree)) {
                tab.requestRemoveWorktree(worktree)
            })
        }
        return entries
    }
}

/// Shown in Local Branches while HEAD is detached: the commit HEAD sits on, with a detached chip.
private struct DetachedHeadRowView: View {
    @ObservedObject var tab: RepoTab
    let oidHex: String

    private static let detachedForeground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? (NSColor.systemYellow.blended(withFraction: 0.55, of: .white) ?? .systemYellow)
            : (NSColor.systemYellow.blended(withFraction: 0.5, of: .black) ?? .systemOrange)
    })

    private static let detachedBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.systemYellow.withAlphaComponent(isDark ? 0.18 : 0.22)
    })

    var body: some View {
        HStack(spacing: 6) {
            PhosphorIcon(glyph: .branch)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text(oidHex.shortOid)
                .lineLimit(1)

            Spacer()

            Text("DETACHED")
                .font(.caption2)
                .foregroundStyle(Self.detachedForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Self.detachedBackground)
                .clipShape(Capsule())
        }
        .contentShape(Rectangle())
        .sidebarRowHighlight()
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
    /// The leading icon. A local branch checked out in another worktree swaps the branch glyph for a folder.
    var glyph: PhosphorGlyph = .branch
    var glyphHelp = ""
    let menuEntries: () -> [MenuEntry]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            // Align leaf branch icon under folder icon when nested, or flush when top-level
            PhosphorIcon(glyph: glyph)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
                .help(glyphHelp)
                // VoiceOver (and UI tests) read the same note the tooltip shows.
                .accessibilityLabel(glyphHelp.isEmpty ? "Branch" : glyphHelp)

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            trailing()
        }
        .padding(.leading, CGFloat(depth) * 8 + (depth > 0 ? 13 : 0))
        .contentShape(Rectangle())
        .sidebarRowHighlight()
        // One accessibility element per row, so UI tests can find it by branch name.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("branch-row:\(branch.name)")
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
            glyph: otherWorktree == nil ? .branch : .folder,
            glyphHelp: otherWorktree.map { "Checked out in \(URL(fileURLWithPath: $0.path).lastPathComponent)" } ?? "",
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

    /// The worktree that has this branch checked out, when it isn't the checkout being viewed.
    private var otherWorktree: WorktreeInfo? {
        tab.worktrees.first {
            $0.branch == branch.name && !$0.isPrunable && $0.path != tab.activeCheckoutPath
        }
    }

    private var menuEntries: [MenuEntry] {
        let branchWorktree = tab.worktrees.first { $0.branch == branch.name }
        var entries: [MenuEntry] = []
        if !branch.isHead {
            if let wt = branchWorktree, wt.path != tab.activeCheckoutPath {
                entries.append(.item("Switch to Worktree", enabled: !tab.isBusy && !wt.isPrunable) {
                    tab.switchCheckout(to: wt.path)
                })
            } else {
                entries.append(.item("Checkout") {
                    tab.checkoutBranch(branch.name)
                })
            }
            if branchWorktree == nil && branch.behind > 0 && branch.ahead == 0 {
                entries.append(.item("Fast-Forward '\(branch.name)'", enabled: !tab.isBusy) {
                    tab.fastForwardBranch(branch.name)
                })
            }
            entries.append(.item("Merge into '\(tab.currentBranch)'…") {
                tab.requestMergeCommit(branch.targetOidHex)
            })
        }
        entries.append(.item("New Branch…") {
            tab.presentNewBranch(startPoint: branch.name)
        })
        entries.append(.item("New Worktree from Branch…", enabled: !tab.isBusy) {
            tab.presentNewWorktree(source: .localBranch(name: branch.name, isCheckedOut: branchWorktree != nil))
        })
        if let wt = branchWorktree, !wt.isMain {
            entries.append(.item("Remove Worktree…", enabled: !tab.isBusy && tab.canRemoveWorktree(wt)) {
                tab.requestRemoveWorktree(wt)
            })
        }
        if !branch.isHead {
            entries.append(.separator)
            entries.append(.item("Delete…") {
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
            [
                .item("Checkout") {
                    tab.checkoutBranch(branch.name)
                },
                .item("New Branch…") {
                    tab.presentNewBranch(startPoint: branch.name)
                },
                .item("New Worktree from Branch…", enabled: !tab.isBusy) {
                    tab.presentNewWorktree(source: .remoteBranch(name: branch.name))
                },
                .separator,
                .item("Delete '\(branch.name)'…") {
                    tab.pendingConfirmation = .deleteRemoteBranch(name: branch.name)
                },
            ]
        } trailing: {
            EmptyView()
        }
    }
}

/// Subtle hover and transient press highlight for sidebar rows without interfering
/// with single-click, double-click, right-click, or accessibility containment.
private struct SidebarRowHighlightModifier: ViewModifier {
    let showsPress: Bool
    @State private var isHovered = false
    @State private var isPressed = false

    private var highlightColor: Color {
        if isPressed {
            return Color.primary.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlightColor)
                    if showsPress {
                        PressTrackingBackground(isPressed: $isPressed)
                    }
                }
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func sidebarRowHighlight(showsPress: Bool = true) -> some View {
        modifier(SidebarRowHighlightModifier(showsPress: showsPress))
    }
}

/// Tracks left-mouse press state via AppKit event monitoring without adding a SwiftUI gesture,
/// so single-click, double-click, right-click, and accessibility containment are never blocked.
private struct PressTrackingBackground: NSViewRepresentable {
    @Binding var isPressed: Bool

    func makeNSView(context: Context) -> PressTrackingNSView {
        let view = PressTrackingNSView()
        view.onPressChange = { pressed in
            if isPressed != pressed {
                isPressed = pressed
            }
        }
        return view
    }

    func updateNSView(_ view: PressTrackingNSView, context: Context) {
        view.onPressChange = { pressed in
            if isPressed != pressed {
                isPressed = pressed
            }
        }
    }
}

@MainActor
private final class SidebarPressMonitor {
    static let shared = SidebarPressMonitor()

    private let views = NSHashTable<PressTrackingNSView>.weakObjects()
    private var pressedViews = NSHashTable<PressTrackingNSView>.weakObjects()
    private var monitor: Any?

    func register(_ view: PressTrackingNSView) {
        views.add(view)
        ensureMonitor()
    }

    func unregister(_ view: PressTrackingNSView) {
        views.remove(view)
        pressedViews.remove(view)
        if views.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func ensureMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard !event.modifierFlags.contains(.control) else { return }
            for view in views.allObjects {
                guard let window = view.window, window === event.window, !view.isHiddenOrHasHiddenAncestor else {
                    continue
                }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) {
                    pressedViews.add(view)
                    view.setPressed(true)
                }
            }
        case .leftMouseDragged:
            for view in pressedViews.allObjects {
                guard let window = view.window, window === event.window, !view.isHiddenOrHasHiddenAncestor else {
                    view.setPressed(false)
                    continue
                }
                let point = view.convert(event.locationInWindow, from: nil)
                view.setPressed(view.bounds.contains(point))
            }
        case .leftMouseUp:
            for view in pressedViews.allObjects {
                view.setPressed(false)
            }
            pressedViews.removeAllObjects()
        default:
            break
        }
    }
}

private final class PressTrackingNSView: NSView {
    var onPressChange: ((Bool) -> Void)?
    private var isCurrentlyPressed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SidebarPressMonitor.shared.register(self)
        } else {
            setPressed(false)
            SidebarPressMonitor.shared.unregister(self)
        }
    }

    func setPressed(_ pressed: Bool) {
        guard isCurrentlyPressed != pressed else { return }
        isCurrentlyPressed = pressed
        onPressChange?(pressed)
    }
}


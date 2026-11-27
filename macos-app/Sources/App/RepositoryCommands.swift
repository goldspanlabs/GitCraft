import SwiftUI

/// The Repository menu. With no active repository it lists the same items, disabled.
struct RepositoryMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabRepositoryMenuItems(tab: tab)
        } else {
            Group {
                Toggle("Amend Last Commit", isOn: .constant(false))
                Toggle("Skip Hooks", isOn: .constant(false))
                Button("Commit") {}
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Commit and Push") {}
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button("Stage All Changes") {}
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Unstage All Changes") {}
                    .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                Divider()
                Button("Fetch") {}
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Pull") {}
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Push") {}
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            .disabled(true)
            Divider()
            Group {
                Button("Save Stash…") {}
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Apply Latest Stash") {}
                    .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                Button("Pop Latest Stash") {}
                Menu("Checkout Branch") {
                    Text("No Open Repository")
                }
                Divider()
                Button("New Branch…") {}
                    .keyboardShortcut("b", modifiers: .command)
                Button("New Tag…") {}
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("New Worktree…") {}
                Button("Prune Stale Worktrees") {}
                Button("Add Remote…") {}
            }
            .disabled(true)
        }
    }
}

private struct ActiveTabRepositoryMenuItems: View {
    @ObservedObject var tab: RepoTab
    @AppStorage(GitPreferences.autoStageOnCommitKey) private var autoStageOnCommit = true

    private var canCommit: Bool {
        tab.canCommit(autoStage: autoStageOnCommit)
    }

    private var localBranches: [BranchInfo] {
        tab.branches.filter { !$0.isRemote }
    }

    var body: some View {
        Toggle("Amend Last Commit", isOn: Binding(
            get: { tab.amendCommit },
            set: { tab.setAmend($0) }
        ))
        .disabled(!tab.canAmend)
        Toggle("Skip Hooks", isOn: $tab.skipHooks)
        Button("Commit") { tab.commitChanges() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)
        Button("Commit and Push") { tab.commitChanges(pushAfter: true) }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!canCommit)

        Divider()

        Button("Stage All Changes") { tab.stageAll() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!tab.canStageAll)
        Button("Unstage All Changes") { tab.unstageAll() }
            .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            .disabled(!tab.canUnstageAll)

        Divider()

        Button("Fetch") { tab.runRemote(.fetch) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(tab.isBusy)
        Button("Pull") { tab.runRemote(.pull) }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(tab.isBusy)
        Button("Push") { tab.runRemote(.push) }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(tab.isBusy)

        Divider()

        Button("Save Stash…") { tab.presentNewStash() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(tab.totalChangesCount == 0 || tab.isBusy)
        Button("Apply Latest Stash") { tab.applyLatestStash() }
            .keyboardShortcut("s", modifiers: [.command, .shift, .option])
            .disabled(!tab.canUseLatestStash)
        Button("Pop Latest Stash") { tab.popLatestStash() }
            .disabled(!tab.canUseLatestStash)
        Menu("Checkout Branch") {
            if localBranches.isEmpty {
                Text("No Local Branches")
            } else {
                ForEach(localBranches, id: \.fullRef) { branch in
                    let otherWorktree = tab.worktrees.first {
                        $0.branch == branch.name && $0.path != tab.activeCheckoutPath
                    }
                    let label: String = if branch.isHead {
                        "✓ \(branch.name)"
                    } else if otherWorktree != nil {
                        "\(branch.name) (Worktree)"
                    } else {
                        branch.name
                    }
                    Button(label) {
                        if let wt = otherWorktree {
                            tab.switchCheckout(to: wt.path)
                        } else {
                            tab.checkoutBranch(branch.name)
                        }
                    }
                    .disabled(branch.isHead || tab.isBusy || (otherWorktree?.isPrunable == true))
                }
            }
        }
        .disabled(tab.isBusy)

        Divider()

        Button("New Branch…") { tab.activeSheet = .newBranch(startPoint: nil) }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(tab.isBusy)
        Button("New Tag…") { tab.activeSheet = .newTag(target: nil) }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(tab.isBusy)
        Button("New Worktree…") { tab.activeSheet = .newWorktree(source: .head) }
            .disabled(tab.isBusy)
        Button("Prune Stale Worktrees") { tab.pruneWorktrees() }
            .disabled(!tab.canPruneWorktrees)
        Button("Add Remote…") { tab.presentAddRemote() }
            .disabled(tab.isBusy)
    }
}

/// Edit ▸ Undo <action>: takes back the repository's latest undoable action. Plain ⌘Z stays
/// with text editing, so typing in the commit message never undoes a reset.
struct RepositoryUndoMenuItem: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabUndoMenuItem(tab: tab)
        } else {
            Button("Undo Repository Action") {}
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(true)
        }
    }
}

private struct ActiveTabUndoMenuItem: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Button(tab.latestUndo.map { "Undo \($0.actionName)" } ?? "Undo Repository Action") {
            tab.undo()
        }
        .keyboardShortcut("z", modifiers: [.command, .option])
        .disabled(tab.latestUndo == nil || tab.isBusy)
    }
}

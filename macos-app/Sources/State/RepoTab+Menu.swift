import Foundation

/// What the menu bar can do with this tab right now, and the actions that need a little logic.
extension RepoTab {
    /// The commit HEAD points at in the shown checkout, or `nil` before the first commit.
    var headCommitOid: String? {
        guard let oid = worktrees.first(where: { $0.path == activeCheckoutPath })?.headOidHex,
              // Git reports an unborn branch's HEAD as all zeros.
              oid.contains(where: { $0 != "0" })
        else { return nil }
        return oid
    }

    var canStageAll: Bool { !unstagedFiles.isEmpty && !isBusy }
    var canUnstageAll: Bool { !stagedFiles.isEmpty && !isBusy }
    var canUseLatestStash: Bool { !stashes.isEmpty && !isBusy }
    var canPruneWorktrees: Bool { !isBusy && worktrees.contains { $0.isPrunable } }

    /// A selected commit hides the commit fields, so amending or committing would act on text
    /// nobody can see.
    var canAmend: Bool { selectedCommit == nil && selectedCommits.isEmpty }

    func canCommit(autoStage: Bool) -> Bool {
        canAmend && GitPreferences.canCommit(
            summary: commitSummary,
            stagedCount: stagedFiles.count,
            changedCount: totalChangesCount,
            autoStage: autoStage,
            isBusy: isBusy,
            amend: amendCommit
        )
    }

    func goToHead() {
        guard let headCommitOid else { return }
        scrollToCommit(oidHex: headCommitOid)
    }

    func applyLatestStash() {
        guard canUseLatestStash, let latest = stashes.first else { return }
        stashApply(latest.index)
    }

    func popLatestStash() {
        guard canUseLatestStash, let latest = stashes.first else { return }
        stashPop(latest.index)
    }
}

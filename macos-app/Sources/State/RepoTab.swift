import AppKit
import SwiftUI

@MainActor
final class RepoTab: ObservableObject, Identifiable {
    struct ScrollRequest: Equatable {
        let id = UUID()
        let oidHex: String?
    }

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
    }

    enum LocalChangesHandling: String, CaseIterable, Identifiable {
        case doNotChange
        case stashAndReapply
        case discard

        var id: String { rawValue }
    }

    enum WorktreeSource: Equatable {
        case head
        case localBranch(name: String, isCheckedOut: Bool)
        case remoteBranch(name: String)
        case commit(oid: String)

        var id: String {
            switch self {
            case .head: return "head"
            case let .localBranch(name, isCheckedOut): return "local-\(name)-\(isCheckedOut)"
            case let .remoteBranch(name): return "remote-\(name)"
            case let .commit(oid): return "commit-\(oid)"
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case newBranch(startPoint: String?)
        case newWorktree(source: WorktreeSource)
        case checkoutCommit(oid: String)
        case mergeCommit(oid: String)
        case newTag(target: String?)
        case newStash
        case remotes(startsAdding: Bool)

        var id: String {
            switch self {
            case let .newBranch(startPoint): return "new-branch-\(startPoint ?? "head")"
            case let .newWorktree(source): return "new-worktree-\(source.id)"
            case let .checkoutCommit(oid): return "checkout-commit-\(oid)"
            case let .mergeCommit(oid): return "merge-commit-\(oid)"
            case let .newTag(target): return "new-tag-\(target ?? "head")"
            case .newStash: return "new-stash"
            case let .remotes(startsAdding): return "remotes-\(startsAdding)"
            }
        }
    }

    enum DestructiveAction: Identifiable {
        case discardFile(path: String)
        case deleteBranch(name: String, force: Bool)
        case forceDeleteBranch(name: String)
        case deleteRemoteBranch(name: String)
        case deleteTag(name: String, deleteRemote: Bool)
        case removeWorktree(path: String, label: String, isActive: Bool)
        case forceRemoveWorktree(path: String, label: String, isActive: Bool)
        case abortMerge
        case abortRebase
        case dropStash(index: UInt32, name: String)
        case resetHard(branch: String, commit: String)
        case rebase(branch: String, commit: String)

        var id: String {
            switch self {
            case let .discardFile(path): return "discard-\(path)"
            case let .deleteBranch(name, force): return "del-branch-\(name)-\(force)"
            case let .forceDeleteBranch(name): return "force-del-branch-\(name)"
            case let .deleteRemoteBranch(name): return "del-remote-branch-\(name)"
            case let .deleteTag(name, remote): return "del-tag-\(name)-\(remote)"
            case let .removeWorktree(path, _, _): return "remove-worktree-\(path)"
            case let .forceRemoveWorktree(path, _, _): return "force-remove-worktree-\(path)"
            case .abortMerge: return "abort-merge"
            case .abortRebase: return "abort-rebase"
            case let .dropStash(index, _): return "drop-stash-\(index)"
            case let .resetHard(_, commit): return "reset-hard-\(commit)"
            case let .rebase(_, commit): return "rebase-\(commit)"
            }
        }

        var title: String {
            switch self {
            case let .discardFile(path): return "Discard changes to \"\(path)\"?"
            case let .deleteBranch(name, _): return "Delete branch \"\(name)\"?"
            case let .forceDeleteBranch(name): return "Branch \"\(name)\" isn't merged"
            case let .deleteRemoteBranch(name): return "Delete remote branch \"\(name)\"?"
            case let .deleteTag(name, remote):
                return remote ? "Delete tag \"\(name)\" locally and from remote?" : "Delete local tag \"\(name)\"?"
            case let .removeWorktree(_, label, _): return "Remove worktree \"\(label)\"?"
            case let .forceRemoveWorktree(_, label, _): return "Worktree \"\(label)\" has uncommitted changes"
            case .abortMerge: return "Abort in-progress merge?"
            case .abortRebase: return "Abort in-progress rebase?"
            case let .dropStash(_, name): return "Drop \"\(name)\"?"
            case let .resetHard(branch, commit): return "Reset \"\(branch)\" to \(commit.prefix(7)) and discard changes?"
            case let .rebase(branch, commit): return "Rebase \"\(branch)\" onto \(commit.prefix(7))?"
            }
        }

        var message: String {
            switch self {
            case .discardFile:
                return "This will permanently revert your uncommitted changes to this file."
            case .deleteBranch:
                return "This will delete the local branch reference."
            case .forceDeleteBranch:
                return "It has commits that aren't in the checked-out branch. Deleting it removes the branch name, and those commits are lost unless they exist elsewhere. Git can often recover them from the reflog for a while."
            case .deleteRemoteBranch:
                return "This will delete the branch from the remote repository. The local branch of the same name, if any, is kept."
            case let .deleteTag(_, remote):
                return remote
                    ? "This will delete the tag locally and push the deletion to the remote repository."
                    : "This will remove the tag from your local repository."
            case let .removeWorktree(path, _, isActive):
                if isActive {
                    return "This will delete \"\(path)\" from disk and switch this tab to another checkout of this repository. Committed history on its branch is kept."
                }
                return "This will delete \"\(path)\" from disk. Committed history on its branch is kept."
            case let .forceRemoveWorktree(path, _, isActive):
                if isActive {
                    return "Modified, staged, or untracked files in \"\(path)\" will be permanently deleted, and this tab will switch to another checkout of this repository. Uncommitted changes can't be recovered from GitCraft."
                }
                return "Modified, staged, or untracked files in \"\(path)\" will be permanently deleted. Uncommitted changes can't be recovered from GitCraft."
            case .abortMerge:
                return "This will abort the current merge and restore the repository to its pre-merge state."
            case .abortRebase:
                return "This will stop the rebase and put your branch back as it was before the pull."
            case .dropStash:
                return "The stashed changes will be removed. This can't be undone from GitCraft."
            case .rebase:
                return "This replays the commits on your branch on top of the selected commit and rewrites their IDs. If you have already pushed this branch, you will need to force push afterwards."
            case .resetHard:
                return "Uncommitted changes to tracked files will be discarded, and commits after this one will leave the branch. Discarded changes can't be recovered from GitCraft."
            }
        }

        var confirmLabel: String {
            switch self {
            case .discardFile: return "Discard"
            case .deleteBranch, .deleteRemoteBranch, .deleteTag: return "Delete"
            case .forceDeleteBranch: return "Force Delete"
            case .removeWorktree: return "Remove"
            case .forceRemoveWorktree: return "Force Remove"
            case .abortMerge: return "Abort Merge"
            case .abortRebase: return "Abort Rebase"
            case .dropStash: return "Drop"
            case .resetHard: return "Reset"
            case .rebase: return "Rebase"
            }
        }
    }

    let id = UUID()
    let url: URL
    /// The repository's primary checkout, the folder that owns `.git`. It names the tab.
    var repoPath: String
    /// The checkout this tab shows: `repoPath` or one of its linked worktrees.
    @Published private(set) var activeCheckoutPath: String
    /// Every checkout of the repository, primary first.
    @Published private(set) var worktrees: [WorktreeInfo] = []
    /// Called after the shown checkout changes, so the window can save it for relaunch.
    var onCheckoutChanged: (() -> Void)?
    var name: String { URL(fileURLWithPath: repoPath).lastPathComponent }

    @Published var currentBranch = ""
    @Published var isMerging = false
    @Published var isRebasing = false
    @Published var hasConflicts = false
    @Published var stagedFiles: [FileChange] = []
    @Published var unstagedFiles: [FileChange] = []
    @Published var commits: [CommitRow] = []
    @Published var graphRevision = UUID()
    @Published var branches: [BranchInfo] = []
    @Published var tags: [TagInfo] = []
    @Published var stashes: [StashInfo] = []
    @Published var remotes: [RemoteInfo] = []
    @Published var selectedCommit: CommitRow?
    @Published var commitDetail: CommitDetail?
    @Published var diffRows: [DiffRow] = []
    @Published var selectedFilePath: String?
    @Published var selectedFileStaged = false
    @Published var scrollRequest: ScrollRequest?
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// A brief note over the commit graph for a no-op result, which isn't a failure.
    @Published var toast: Toast?

    @Published var pendingConfirmation: DestructiveAction?
    @Published var activeSheet: ActiveSheet?
    @Published var searchQuery = ""
    @Published var commitSummary = ""
    @Published var commitBody = ""
    /// Commit with `--no-verify`, so pre-commit and commit-msg hooks don't run.
    @Published var skipHooks = false
    /// Rewrite HEAD's commit instead of making a new one.
    @Published var amendCommit = false
    /// When true (default), the graph shows only the checked-out branch and the base branch,
    /// from their fork point. When false, it shows every branch.
    @Published var scopeToCurrentBranch = true

    var totalChangesCount: Int {
        Set(stagedFiles.map(\.path) + unstagedFiles.map(\.path)).count
    }

    var currentBranchBehindCount: Int {
        Int(branches.first(where: { $0.isHead && !$0.isRemote })?.behind ?? 0)
    }

    var currentBranchAheadCount: Int {
        Int(branches.first(where: { $0.isHead && !$0.isRemote })?.ahead ?? 0)
    }

    /// Trimmed search query passed to the Rust core, or `nil` when empty.
    var activeSearchQuery: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var session: RepoSession
    var isLoadingMore = false
    var hasMoreCommits = true
    let pageSize: UInt32 = 500
    var revealTask: Task<Void, Never>?
    /// Bumped whenever the commit list is replaced (refresh, search), so in-flight
    /// page fetches that started against the old list can detect they are stale.
    var graphGeneration = 0
    /// Search replacements still fetching their first page. While > 0, `commits` and
    /// `searchQuery` describe different lists, so paging must wait.
    var pendingSearchReplacements = 0
    var loadedDetailOid: String?

    private var watcherTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?
    private var worktreesRefreshTask: Task<Void, Never>?
    private var worktreesRefreshPending = false
    private var sortObserver: NSObjectProtocol?
    private var lastCommitSort = CommitSortPreference.current

    /// Resolves symlinks with POSIX `realpath` so checkout paths match `git worktree list`
    /// verbatim. Unlike `URL.resolvingSymlinksInPath()`, `realpath` preserves macOS's
    /// `/private` prefix on `/var` and `/tmp`.
    static func canonicalPath(for path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Resolves a user-entered path (including `~` or relative paths) against `basePath` so
    /// git commands and subsequent checkout switches refer to the exact same directory.
    static func resolvePath(_ path: String, relativeTo basePath: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: basePath, isDirectory: true))
        }
        return url.standardizedFileURL.path
    }

    init(url: URL) throws {
        let canonical = Self.canonicalPath(for: url.path)
        let session = try RepoSession(path: canonical)
        self.url = URL(fileURLWithPath: canonical)
        self.session = session
        self.activeCheckoutPath = canonical
        // Metadata-only lookup avoids running `git status` per checkout on the main actor;
        // `refresh()` fills in dirty counts asynchronously.
        let listed = (try? session.listWorktreeEntries()) ?? []
        self.worktrees = listed
        // Git lists the primary checkout first, so a tab opened on a linked worktree still
        // names the repository after its main folder.
        self.repoPath = listed.first?.path ?? canonical
    }

    /// Shows a failure in the banner, or a brief toast when the core reports a no-op.
    func showError(_ error: Error) {
        if error.isWarning {
            toast = Toast(message: error.displayMessage)
        } else {
            errorMessage = error.displayMessage
        }
    }

    // MARK: - Sheet Presentation

    func presentNewBranch(startPoint: String? = nil) {
        activeSheet = .newBranch(startPoint: startPoint)
    }

    func presentNewWorktree(source: WorktreeSource = .head) {
        activeSheet = .newWorktree(source: source)
    }

    /// Picks a surviving checkout to switch back to when removing `path`: the primary checkout
    /// when available, otherwise any other linked checkout that still exists on disk (for
    /// bare-backed repos). A locked worktree whose folder is gone is not prunable per git, so
    /// the folder check is needed too.
    func fallbackCheckoutPath(excluding path: String) -> String? {
        let canonical = Self.canonicalPath(for: path)
        func isSurviving(_ worktree: WorktreeInfo) -> Bool {
            worktree.path != canonical
                // A checkout nested inside the one being removed is deleted along with it.
                && !worktree.path.hasPrefix(canonical + "/")
                && !worktree.isPrunable
                && FileManager.default.fileExists(atPath: worktree.path)
        }
        if let main = worktrees.first(where: { $0.isMain && isSurviving($0) }) {
            return main.path
        }
        return worktrees.first(where: isSurviving)?.path
    }

    /// Whether `worktree` can be safely removed from this tab. Never allows removing the primary
    /// checkout, a locked worktree, or the sole remaining checkout of a bare-backed repository.
    func canRemoveWorktree(_ worktree: WorktreeInfo) -> Bool {
        guard !worktree.isMain, !worktree.isLocked else { return false }
        if activeCheckoutPath == worktree.path {
            return fallbackCheckoutPath(excluding: worktree.path) != nil
        }
        return true
    }

    func requestRemoveWorktree(_ worktree: WorktreeInfo) {
        guard canRemoveWorktree(worktree) else { return }
        let label = worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
        pendingConfirmation = .removeWorktree(
            path: worktree.path,
            label: label,
            isActive: activeCheckoutPath == worktree.path
        )
    }

    /// Opens the Checkout Commit sheet for `oid`. Checking out a commit detaches HEAD, as the sheet says.
    func requestCheckoutCommit(_ oid: String) {
        activeSheet = .checkoutCommit(oid: oid)
    }

    /// Opens the Merge sheet for `oid`.
    func requestMergeCommit(_ oid: String) {
        activeSheet = .mergeCommit(oid: oid)
    }

    func presentNewTag(target: String? = nil) {
        activeSheet = .newTag(target: target)
    }

    func presentNewStash() {
        activeSheet = .newStash
    }

    func presentRemotes(startsAdding: Bool) {
        activeSheet = .remotes(startsAdding: startsAdding)
    }

    // MARK: - Watcher & Refresh

    /// Background fetch on the interval chosen in Settings (never when set to 0). Failures
    /// such as being offline are ignored; manual Fetch still reports them.
    private func startAutoFetch() {
        autoFetchTask?.cancel()
        let session = self.session
        autoFetchTask = Task { [weak self] in
            var lastFetch = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { break }
                let minutes = AutoFetchInterval.currentMinutes
                guard minutes > 0,
                      Date().timeIntervalSince(lastFetch) >= Double(minutes) * 60,
                      let self, !self.isBusy
                else { continue }
                lastFetch = Date()
                let includeTags = GitPreferences.fetchIncludesTags
                let fetched: Bool = await Task.detached {
                    (try? session.fetch(includeTags: includeTags)) != nil
                }.value
                if fetched { self.refresh() }
            }
        }
    }

    func startWatcher() {
        startAutoFetch()
        observeCommitSortChanges()
        watcherTask?.cancel()
        let session = self.session
        watcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                // Refs/HEAD/config changes need the full reload; plain file edits in the
                // active checkout only need a status refresh; edits in inactive sibling
                // worktrees only refresh sidebar dirty counts.
                let (graphDirty, dirty, worktreesDirty) = await Task.detached {
                    (session.takeGraphDirty(), session.takeDirty(), session.takeWorktreesDirty())
                }.value
                if graphDirty {
                    self?.refresh()
                } else {
                    if dirty {
                        self?.refreshStatus()
                    }
                    if worktreesDirty {
                        self?.refreshWorktrees()
                    }
                }
            }
        }
    }

    /// Reloads the graph from the top when the sort order changes in Settings.
    private func observeCommitSortChanges() {
        guard sortObserver == nil else { return }
        lastCommitSort = CommitSortPreference.current
        sortObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = CommitSortPreference.current
                guard current != self.lastCommitSort else { return }
                self.lastCommitSort = current
                self.updateSearch(self.searchQuery)
            }
        }
    }

    func stopWatcher() {
        autoFetchTask?.cancel()
        autoFetchTask = nil
        if let sortObserver {
            NotificationCenter.default.removeObserver(sortObserver)
            self.sortObserver = nil
        }
        watcherTask?.cancel()
        watcherTask = nil
    }

    /// Whether `path` is one of this tab's checkouts (primary, active, or a sibling worktree).
    func contains(checkoutPath path: String) -> Bool {
        let canonical = Self.canonicalPath(for: path)
        return repoPath == canonical
            || activeCheckoutPath == canonical
            || worktrees.contains { $0.path == canonical }
    }

    /// Points this tab at another checkout of the same repository. Branches, tags, stashes and
    /// the graph are shared, so only the working state, the watchers and the selection change.
    func switchCheckout(to path: String) {
        let canonical = Self.canonicalPath(for: path)
        guard !isBusy, canonical != activeCheckoutPath else { return }
        if worktrees.first(where: { $0.path == canonical })?.isPrunable == true { return }
        let next: RepoSession
        do {
            next = try RepoSession(path: canonical)
        } catch {
            showError(error)
            return
        }
        attach(next, at: canonical)
    }

    /// Switches to a checkout whose session the caller already opened, so the switch itself
    /// can't fail. Removing the active worktree uses this: it opens the fallback before
    /// deleting anything, so the tab isn't left on a folder that no longer exists. It skips
    /// the busy check because it runs as the last step of that removal.
    func switchCheckout(to path: String, using next: RepoSession) {
        let canonical = Self.canonicalPath(for: path)
        guard canonical != activeCheckoutPath else { return }
        attach(next, at: canonical)
    }

    private func attach(_ next: RepoSession, at canonical: String) {
        watcherTask?.cancel()
        autoFetchTask?.cancel()
        revealTask?.cancel()
        revealTask = nil
        // Any in-flight sweep belongs to the old session; the new one starts fresh.
        worktreesRefreshTask?.cancel()
        worktreesRefreshTask = nil
        worktreesRefreshPending = false
        session = next
        activeCheckoutPath = canonical
        graphGeneration += 1
        currentBranch = worktrees.first(where: { $0.path == canonical })?.branch ?? ""
        isMerging = false
        isRebasing = false
        hasConflicts = false
        stagedFiles = []
        unstagedFiles = []
        selectedCommit = nil
        commitDetail = nil
        loadedDetailOid = nil
        diffRows = []
        selectedFilePath = nil
        selectedFileStaged = false
        scrollRequest = ScrollRequest(oidHex: nil)
        commitSummary = ""
        commitBody = ""
        amendCommit = false
        skipHooks = false
        pendingConfirmation = nil
        activeSheet = nil
        errorMessage = nil
        startWatcher()
        refresh()
        onCheckoutChanged?()
    }

    private func syncActiveWorktreeDirtyCount() {
        let activeDirty = UInt32(totalChangesCount)
        if let index = worktrees.firstIndex(where: { $0.path == activeCheckoutPath }),
           worktrees[index].dirtyCount != activeDirty {
            worktrees[index].dirtyCount = activeDirty
        }
    }

    func applyStatus(_ status: RepoStatus) {
        currentBranch = status.branch.components(separatedBy: "...").first ?? status.branch
        isMerging = status.isMerging
        isRebasing = status.isRebasing
        hasConflicts = status.hasConflicts
        if stagedFiles != status.stagedFiles { stagedFiles = status.stagedFiles }
        if unstagedFiles != status.unstagedFiles { unstagedFiles = status.unstagedFiles }
        syncActiveWorktreeDirtyCount()
    }

    /// Re-reads only the working-tree status (staged/unstaged lists and merge state).
    func refreshStatus() {
        let session = self.session
        Task {
            do {
                let status = try await Task.detached { try session.status() }.value
                guard self.session === session else { return }
                applyStatus(status)
                if selectedCommit == nil {
                    loadWorkingDiffSelection()
                }
            } catch {
                guard self.session === session else { return }
                showError(error)
            }
        }
    }

    /// Re-reads worktree metadata and per-checkout dirty counts independently so a slow
    /// sibling checkout never delays publishing the active checkout's status or graph.
    /// Requests made while a sweep is running coalesce into one rerun after it finishes, so
    /// the poller never stacks overlapping `git status` sweeps.
    func refreshWorktrees() {
        worktreesRefreshPending = true
        guard worktreesRefreshTask == nil else { return }
        runWorktreesRefresh()
    }

    private func runWorktreesRefresh() {
        worktreesRefreshPending = false
        let session = self.session
        worktreesRefreshTask = Task {
            // Non-fatal on failure: active checkout status and graph remain usable.
            let worktreeList = try? await Task.detached { try session.listWorktrees() }.value
            // A checkout switch already cleared the task slot for the new session.
            guard self.session === session else { return }
            worktreesRefreshTask = nil
            if let worktreeList {
                worktrees = worktreeList
                syncActiveWorktreeDirtyCount()
            }
            if worktreesRefreshPending {
                runWorktreesRefresh()
            }
        }
    }

    func refresh() {
        let session = self.session
        let query = activeSearchQuery
        // Reload at least everything already loaded: refreshing only the first page would
        // shrink the list under a user who has scrolled further down, yanking the table
        // back up (and the scroll-to-load-more would then immediately refetch).
        let limit = max(pageSize, UInt32(commits.count))
        let scoped = scopeToCurrentBranch

        refreshWorktrees()

        Task {
            do {
                async let statusTask = Task.detached { try session.status() }.value
                async let branchesTask = Task.detached { try session.listBranches() }.value
                async let tagsTask = Task.detached { try session.listTags() }.value
                async let stashesTask = Task.detached { try session.listStashes() }.value
                async let remotesTask = Task.detached { try session.listRemotes() }.value
                async let graphTask = Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: 0, limit: limit, query: query)
                }.value

                let (status, branchList, tagList, stashList, remoteList, graphRows) = try await (
                    statusTask,
                    branchesTask,
                    tagsTask,
                    stashesTask,
                    remotesTask,
                    graphTask
                )
                guard self.session === session else { return }
                applyStatus(status)
                branches = branchList
                // The core already returns tags newest-created first.
                tags = tagList
                stashes = stashList
                remotes = remoteList
                graphGeneration += 1
                commits = graphRows
                graphRevision = UUID()
                hasMoreCommits = graphRows.count >= Int(limit)

                if selectedCommit == nil {
                    loadWorkingDiffSelection()
                }
            } catch {
                guard self.session === session else { return }
                showError(error)
            }
        }
    }

    /// Runs `work` off the main thread, then refreshes. `onFailure` gets the first chance to
    /// handle an error; returning true means it did, so the error banner is skipped.
    func performMutation(
        _ work: @escaping @Sendable (RepoSession) throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil,
        onFailure: (@MainActor (Error) -> Bool)? = nil
    ) {
        let session = self.session
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await Task.detached {
                    try work(session)
                }.value
                isBusy = false
                onSuccess?()
                if self.session === session {
                    refresh()
                }
            } catch {
                if let onFailure, onFailure(error) { return }
                showError(error)
            }
        }
    }
}

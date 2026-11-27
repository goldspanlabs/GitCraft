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
        /// A finished action rather than a no-op or warning: drawn with a checkmark.
        var isSuccess = false
        /// A button on the note, such as Undo. Using it also closes the note.
        var action: ToastAction?
    }

    struct ToastAction {
        let title: String
        /// The undo step this button takes back, if it is an Undo button. It works only while
        /// that step is the latest, and the note goes once the step leaves the stack.
        var undoEntryID: UUID?
        /// The button's tooltip, such as its keyboard shortcut.
        var help: String?
        let perform: @MainActor () -> Void
    }

    enum LocalChangesHandling: String, CaseIterable, Identifiable {
        case doNotChange
        case stashAndReapply
        case discard

        var id: String { rawValue }
    }

    enum HistoryState {
        case loading, loaded, failed
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
    var name: String { repoPath.folderName }
    /// The folder of the checkout this tab shows: the repository's own folder, or a linked worktree's.
    var checkoutName: String { activeCheckoutPath.folderName }

    @Published var currentBranch = ""
    @Published var isMerging = false
    @Published var isRebasing = false
    @Published var isCherryPicking = false
    @Published var isReverting = false
    @Published var hasConflicts = false
    @Published var stagedFiles: [FileChange] = []
    @Published var unstagedFiles: [FileChange] = []
    @Published var commits: [CommitRow] = []
    /// Tells an empty `commits` apart: still being read, truly empty, or unreadable.
    @Published var historyState = HistoryState.loading
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
    @Published var isBusy = false {
        didSet { if !isBusy { busyLabel = nil } }
    }
    /// What the running mutation is doing, for the title-bar spinner. Nil when it isn't named.
    @Published var busyLabel: String?
    @Published var errorMessage: String?

    /// Brief notes over the commit graph, oldest first: finished actions, or no-op results,
    /// which aren't failures. Each clears itself; see `showToast`.
    @Published private(set) var toasts: [Toast] = []

    /// The most notes on screen at once; a new one past this pushes out the oldest.
    static let maxToasts = 3

    /// Actions that can be taken back, oldest first. Change it through `recordUndo` and
    /// `undo` (see Undo.swift).
    @Published var undoStack: [UndoEntry] = []
    /// Undone actions that Redo can do again, oldest first. Emptied by any new action.
    @Published var redoStack: [UndoEntry] = []
    /// Whether a text field or text view in this tab's window has the keyboard, which keeps
    /// ⌘Z and ⇧⌘Z for editing text. Set by the window controller.
    @Published var isEditingText = false

    @Published var pendingConfirmation: DestructiveAction?
    @Published var activeSheet: ActiveSheet?
    @Published var searchQuery = ""
    /// The commit message being typed. Only the composer's fields watch it.
    let commitDraft = CommitDraft()
    /// Whether the draft has no summary to commit, the one thing about the message that the
    /// rest of the tab's views depend on.
    @Published private(set) var isCommitSummaryBlank = true
    var commitSummary: String {
        get { commitDraft.summary }
        set {
            commitDraft.summary = newValue
            publish(newValue.trimmed.isEmpty, to: \.isCommitSummaryBlank)
        }
    }

    var commitBody: String {
        get { commitDraft.body }
        set { commitDraft.body = newValue }
    }
    /// Commit with `--no-verify`, so pre-commit and commit-msg hooks don't run.
    @Published var skipHooks = false
    /// Rewrite HEAD's commit instead of making a new one.
    @Published var amendCommit = false
    /// When true (default), the graph shows only the checked-out branch and the base branch,
    /// from their fork point. When false, it shows every branch.
    @Published var scopeToCurrentBranch = true
    @Published var showTags = true

    /// The remote that tag pushes go to: `origin` when there is one, else the first remote.
    /// Mirrors `resolve_default_remote` in the Rust core, which picks the remote for real.
    var defaultRemoteName: String {
        remotes.first(where: { $0.name == "origin" })?.name
            ?? remotes.first?.name
            ?? "origin"
    }

    var totalChangesCount: Int {
        Set(stagedFiles.map(\.path) + unstagedFiles.map(\.path)).count
    }

    /// The checked-out branch's name for labels, or "HEAD" before the status has loaded.
    var currentBranchLabel: String {
        currentBranch.isEmpty ? "HEAD" : currentBranch
    }

    /// Whether `branch`, as the status reports it, means no branch is checked out. The core
    /// reports a detached HEAD as "HEAD (detached)" (see `clean_branch_header`).
    nonisolated static func isDetachedHead(branch: String) -> Bool {
        branch.isEmpty || branch == "HEAD" || branch.hasPrefix("HEAD (") || branch.hasPrefix("(")
    }

    /// The checked-out local branch, or nil when HEAD is detached.
    var currentBranchInfo: BranchInfo? {
        branches.first(where: { $0.isHead && !$0.isRemote })
    }

    var currentBranchBehindCount: Int {
        Int(currentBranchInfo?.behind ?? 0)
    }

    var currentBranchAheadCount: Int {
        Int(currentBranchInfo?.ahead ?? 0)
    }

    /// Trimmed search query passed to the Rust core, or `nil` when empty.
    var activeSearchQuery: String? {
        let trimmed = searchQuery.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    var session: RepoSession
    var isLoadingMore = false
    var hasMoreCommits = true
    let pageSize: UInt32 = 500
    var revealTask: Task<Void, Never>?
    var searchDebounceTask: Task<Void, Never>?
    /// Bumped whenever the commit list is replaced (refresh, search), so in-flight
    /// page fetches that started against the old list can detect they are stale.
    var graphGeneration = 0
    var refreshInFlight = false
    var refreshRun = 0
    var refreshSession: RepoSession?
    var refreshPending = false
    /// Search replacements still fetching their first page. While > 0, `commits` and
    /// `searchQuery` describe different lists, so paging must wait.
    var pendingSearchReplacements = 0
    var loadedDetailOid: String?

    private var watcherTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?
    private var worktreesRefreshTask: Task<Void, Never>?
    private var worktreesRefreshPending = false
    /// The repository's shared Git directory, read when the tab opened. Every checkout of the
    /// repository has the same one, so it still identifies the repository after a linked
    /// worktree has been deleted or pruned.
    private let commonDir: String
    /// Set while a switch away from a checkout whose folder disappeared is being prepared.
    private var recoveringMissingCheckout = false
    private var recoveryTask: Task<Void, Never>?
    /// The missing checkout already reported in the banner, and the message shown for it, so
    /// the watcher doesn't repeat it and only clears its own message.
    private var reportedMissingCheckout: (path: String, message: String)?
    private var sortObserver: NSObjectProtocol?
    private var lastCommitSort = CommitSortPreference.current
    /// Mirrors the avatar preference so the commit table redraws its rows when it changes.
    @Published private(set) var showAvatars = AvatarPreference.isEnabled()

    /// Resolves symlinks with POSIX `realpath` so checkout paths match `git worktree list`
    /// verbatim. Unlike `URL.resolvingSymlinksInPath()`, `realpath` preserves macOS's
    /// `/private` prefix on `/var` and `/tmp`.
    nonisolated static func canonicalPath(for path: String) -> String {
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
        self.commonDir = session.commonDir()
        self.activeCheckoutPath = canonical
        // Metadata-only lookup avoids running `git status` per checkout on the main actor;
        // `refresh()` fills in dirty counts asynchronously.
        let listed = (try? session.listWorktreeEntries()) ?? []
        self.worktrees = listed
        // Git lists the primary checkout first, so a tab opened on a linked worktree still
        // names the repository after its main folder.
        self.repoPath = listed.first?.path ?? canonical
    }

    /// Adds a note below any already showing. The same text again moves that note to the
    /// bottom and restarts its timer, rather than showing it twice.
    func showToast(_ message: String, isSuccess: Bool = false, action: ToastAction? = nil) {
        toasts.removeAll { $0.message == message }
        toasts.append(Toast(message: message, isSuccess: isSuccess, action: action))
        if toasts.count > Self.maxToasts {
            toasts.removeFirst(toasts.count - Self.maxToasts)
        }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// Closes the note whose Undo button takes back `undoEntryID`.
    func dismissToasts(forUndo undoEntryID: UUID) {
        toasts.removeAll { $0.action?.undoEntryID == undoEntryID }
    }

    /// Whether `toast`'s button can be used now.
    func toastActionEnabled(_ toast: Toast) -> Bool {
        guard !isBusy, let action = toast.action else { return false }
        guard let undoID = action.undoEntryID else { return true }
        return undoID == latestUndo?.id
    }

    /// Shows a failure in the banner, or a brief toast when the core reports a no-op.
    func showError(_ error: Error) {
        if error.isWarning {
            showToast(error.displayMessage)
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
        Self.fallbackCheckoutPath(excluding: path, among: worktrees.map(FallbackCandidate.init))
    }

    /// The selection behind `fallbackCheckoutPath(excluding:)`, over a snapshot of the worktree
    /// list so it can run off the main actor: it resolves paths and touches the filesystem.
    nonisolated static func fallbackCheckoutPath(
        excluding path: String,
        among candidates: [FallbackCandidate]
    ) -> String? {
        let canonical = canonicalPath(for: path)
        func isSurviving(_ candidate: FallbackCandidate) -> Bool {
            candidate.path != canonical
                // A checkout nested inside the one being removed is deleted along with it.
                && !candidate.path.hasPrefix(canonical + "/")
                && !candidate.isPrunable
                && FileManager.default.fileExists(atPath: candidate.path)
        }
        if let main = candidates.first(where: { $0.isMain && isSurviving($0) }) {
            return main.path
        }
        return candidates.first(where: isSurviving)?.path
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
        // Worktrees are identified by their folder, as in the sidebar.
        let label = worktree.path.folderName
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

    func presentAddRemote() {
        activeSheet = .addRemote
    }

    func presentEditRemote(_ remote: RemoteInfo) {
        activeSheet = .editRemote(remote)
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
                // No reload here: the watcher asks for one if the fetch moved any ref.
                await Task.detached {
                    _ = try? session.fetch(includeTags: includeTags)
                }.value
            }
        }
    }

    func startWatcher() {
        startAutoFetch()
        observeCommitSortChanges()
        watcherTask?.cancel()
        let session = self.session
        let checkoutPath = activeCheckoutPath
        watcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                // The folder can disappear outside the app (deleted in Finder, an unmounted
                // volume). Every Git action would fail there, so move the tab elsewhere.
                let folderExists = await Task.detached {
                    FileManager.default.fileExists(atPath: checkoutPath)
                }.value
                // `stopWatcher()` may have run while the check was pending.
                if Task.isCancelled { break }
                if !folderExists {
                    self?.handleMissingCheckout(checkoutPath)
                    continue
                }
                if let self, let reported = self.reportedMissingCheckout, reported.path == checkoutPath {
                    // The folder came back (a volume was remounted, say): clear the banner.
                    self.reportedMissingCheckout = nil
                    if self.errorMessage == reported.message { self.errorMessage = nil }
                    self.refresh()
                }
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

    /// Switches the tab to another checkout of this repository after the shown checkout's
    /// folder has disappeared. Waits while an operation is running, since removing the active
    /// worktree deletes the folder on purpose and switches by itself. When there is nowhere
    /// to go, the banner says so once and the tab stays put in case the folder comes back.
    func handleMissingCheckout(_ path: String) {
        guard path == activeCheckoutPath, !isBusy, !recoveringMissingCheckout else { return }
        let name = path.folderName
        let candidates = worktrees.map(FallbackCandidate.init)
        let commonDir = self.commonDir
        recoveringMissingCheckout = true
        recoveryTask = Task { [weak self] in
            // Everything that can block stays off the main actor: choosing the fallback resolves
            // paths and checks the disk, opening it runs `git worktree list`, and a folder check
            // can hang on a dead volume. The fallback must belong to the same repository, and
            // the folder must still be missing once the session is open, since it may have come
            // back meanwhile.
            let outcome = await Task.detached { () -> RecoveryOutcome in
                guard let fallback = RepoTab.fallbackCheckoutPath(excluding: path, among: candidates) else {
                    return .noFallback
                }
                guard let next = try? RepoSession(path: fallback), next.commonDir() == commonDir else {
                    return .unusable
                }
                if FileManager.default.fileExists(atPath: path) { return .folderReturned }
                return .ready(next, fallback)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.recoveringMissingCheckout = false
            self.recoveryTask = nil
            // Only act if the tab is still on that checkout and nothing is running: a mutation
            // may have started, or another switch may have happened, while the session opened.
            guard path == self.activeCheckoutPath, !self.isBusy else { return }
            switch outcome {
            case .folderReturned:
                // The next watcher tick clears any banner and refreshes.
                return
            case .noFallback:
                self.reportMissingCheckout(path, "The folder for \"\(name)\" no longer exists, and there's "
                    + "no other checkout of this repository to switch to.")
            case .unusable:
                self.reportMissingCheckout(path, "The folder for \"\(name)\" no longer exists, and "
                    + "the tab couldn't switch to another checkout of this repository.")
            case let .ready(next, fallback):
                self.reportedMissingCheckout = nil
                // The primary checkout can be the one that vanished (bare-backed repositories
                // have no separate main folder), and `contains(checkoutPath:)` would keep
                // claiming that path. Removing a worktree does the same.
                if self.repoPath == path {
                    self.repoPath = fallback
                }
                self.switchCheckout(to: fallback, using: next)
                let target = fallback.folderName
                self.showToast("\"\(name)\" no longer exists, so this tab switched to \"\(target)\".")
            }
        }
    }

    private func reportMissingCheckout(_ path: String, _ message: String) {
        guard reportedMissingCheckout?.path != path else { return }
        reportedMissingCheckout = (path, message)
        errorMessage = message
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
                let avatarsOn = AvatarPreference.isEnabled()
                // The table reloads its rows when this changes. The graph generation is left
                // alone so in-flight searches still land.
                if avatarsOn != self.showAvatars { self.showAvatars = avatarsOn }
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
        cancelRecovery()
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveringMissingCheckout = false
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
        // A recovery in flight was preparing a switch from the old checkout.
        cancelRecovery()
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
        isCherryPicking = false
        isReverting = false
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
        publish(status.branch.components(separatedBy: "...").first ?? status.branch, to: \.currentBranch)
        publish(status.isMerging, to: \.isMerging)
        publish(status.isRebasing, to: \.isRebasing)
        publish(status.isCherryPicking, to: \.isCherryPicking)
        publish(status.isReverting, to: \.isReverting)
        publish(status.hasConflicts, to: \.hasConflicts)
        publish(status.stagedFiles, to: \.stagedFiles)
        publish(status.unstagedFiles, to: \.unstagedFiles)
        syncActiveWorktreeDirtyCount()
    }

    /// Assigns only a different value: every assignment to a published property redraws the
    /// views watching this tab, even when nothing changed.
    func publish<Value: Equatable>(_ value: Value, to keyPath: ReferenceWritableKeyPath<RepoTab, Value>) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Re-reads only the working-tree status (staged/unstaged lists and merge state).
    func refreshStatus() {
        loadInBackground({ try $0.status() }, apply: { [self] status in
            applyStatus(status)
            if selectedCommit == nil {
                loadWorkingDiffSelection()
            }
        })
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
            let worktreeList = try? await Task.detached {
                try session.listWorktreesWithSiblingCounts()
            }.value
            // A checkout switch already cleared the task slot for the new session.
            guard self.session === session else { return }
            worktreesRefreshTask = nil
            if var worktreeList {
                // The shown checkout isn't counted by the sweep: its status already says.
                if let index = worktreeList.firstIndex(where: { $0.path == activeCheckoutPath }) {
                    worktreeList[index].dirtyCount = UInt32(totalChangesCount)
                }
                publish(worktreeList, to: \.worktrees)
            }
            if worktreesRefreshPending {
                runWorktreesRefresh()
            }
        }
    }

    /// Reloads everything. A request made while a reload is running doesn't start a second
    /// one alongside it: it queues one more pass after the current one, so a mutation's own
    /// refresh and the watcher's refresh of the same change collapse into one or two ordered
    /// passes instead of overlapping and finishing in either order.
    /// A reload still running for a previous session (after the tab switched checkouts) doesn't
    /// hold up the new one: only a reload of the current session absorbs the request.
    func refresh() {
        if refreshInFlight, refreshSession === session {
            refreshPending = true
            return
        }
        runRefresh()
    }

    private func runRefresh() {
        refreshPending = false
        refreshInFlight = true
        refreshRun += 1
        let run = refreshRun
        let session = self.session
        refreshSession = session
        let generation = graphGeneration
        let query = activeSearchQuery
        // Reload at least everything already loaded: refreshing only the first page would
        // shrink the list under a user who has scrolled further down, yanking the table
        // back up (and the scroll-to-load-more would then immediately refetch).
        let limit = max(pageSize, UInt32(commits.count))
        let scoped = scopeToCurrentBranch

        refreshWorktrees()

        Task {
            defer {
                // A newer reload (for another session) owns the flags now.
                if refreshRun == run {
                    refreshInFlight = false
                    refreshSession = nil
                    if refreshPending { runRefresh() }
                }
            }
            do {
                async let statusTask = Task.detached { try session.status() }.value
                async let branchesTask = Task.detached { try session.listBranches() }.value
                async let tagsTask = Task.detached { try session.listTags() }.value
                async let stashesTask = Task.detached { try session.listStashes() }.value
                async let remotesTask = Task.detached { try session.listRemotes() }.value
                async let graphTask = Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: 0, limit: limit, query: query)
                }.value

                // The history goes up as soon as it is ready. The sidebar lists and status can
                // take much longer on large repositories and fill in afterwards.
                let graphRows = try await graphTask
                guard self.session === session else { return }
                // Paging appends rows without changing the generation, so a list that grew past
                // what this reload asked for also counts as changed.
                if generation == graphGeneration, commits.count <= Int(limit) {
                    replaceCommits(with: graphRows, requested: limit)
                } else {
                    // A search or page load changed the list while this reload ran, so these rows
                    // may be for an older query or too few. Reload once more instead of applying them.
                    refreshPending = true
                }

                // The changed files don't wait for the sidebar lists either.
                let status = try await statusTask
                guard self.session === session else { return }
                applyStatus(status)
                if selectedCommit == nil {
                    loadWorkingDiffSelection()
                }

                let (branchList, tagList, stashList, remoteList) = try await (
                    branchesTask,
                    tagsTask,
                    stashesTask,
                    remotesTask
                )
                guard self.session === session else { return }
                branches = branchList
                // The core already returns tags newest-created first.
                tags = tagList
                stashes = stashList
                remotes = remoteList
                pruneUndoStack()
            } catch {
                guard self.session === session else { return }
                // A failure after the history arrived leaves it showing as loaded.
                if historyState == .loading { historyState = .failed }
                showError(error)
            }
        }
    }

    /// Runs the read-only `work` off the main thread and hands its result to `apply`. A result
    /// or error that arrives after the tab has moved to another checkout is dropped. On an
    /// error, `onFailure` runs before the error is shown. `always` runs last in every case,
    /// including when the result is dropped.
    func loadInBackground<Value: Sendable>(
        _ work: @escaping @Sendable (RepoSession) throws -> Value,
        apply: @escaping @MainActor (Value) -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil,
        always: (@MainActor () -> Void)? = nil
    ) {
        let session = self.session
        Task {
            defer { always?() }
            do {
                let value = try await Task.detached { try work(session) }.value
                guard self.session === session else { return }
                apply(value)
            } catch {
                guard self.session === session else { return }
                onFailure?(error)
                showError(error)
            }
        }
    }

    /// Runs `work` off the main thread, then refreshes. `onFailure` gets the first chance to
    /// handle an error; returning true means it did, so the error banner is skipped.
    /// `busyLabel` names the work for the title-bar spinner while it runs.
    func performMutation(
        busyLabel: String? = nil,
        _ work: @escaping @Sendable (RepoSession) throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil,
        onFailure: (@MainActor (Error) -> Bool)? = nil
    ) {
        let session = self.session
        isBusy = true
        self.busyLabel = busyLabel
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

/// The parts of a worktree entry needed to choose a fallback checkout, copied so the choice can
/// run off the main actor.
struct FallbackCandidate: Sendable {
    let path: String
    let isMain: Bool
    let isPrunable: Bool

    init(_ worktree: WorktreeInfo) {
        path = worktree.path
        isMain = worktree.isMain
        isPrunable = worktree.isPrunable
    }
}

/// What preparing a switch away from a missing checkout found, computed off the main actor.
private enum RecoveryOutcome: @unchecked Sendable {
    case noFallback
    case unusable
    case folderReturned
    case ready(RepoSession, String)
}

/// The commit message being typed, apart from the tab so that a keystroke doesn't redraw
/// everything watching the tab. Set the summary through `RepoTab.commitSummary`.
final class CommitDraft: ObservableObject {
    @Published fileprivate(set) var summary = ""
    @Published var body = ""
}

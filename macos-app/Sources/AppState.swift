import AppKit
import SwiftUI

enum RemoteOperation {
    case fetch, pull, push
}

/// App-wide state shared by every repository window. Each repository lives in its own
/// `RepoWindowController` window; macOS groups those windows into native tabs.
@MainActor
final class WorkspaceState: ObservableObject {
    static let shared = WorkspaceState()

    @Published var recentPaths: [String] = []
    @Published var openError: String?

    /// Set to true by the app delegate when quitting, so windows closing during
    /// shutdown don't erase the saved list of open repositories.
    static var isTerminating = false

    private static let recentKey = "recentRepositories"
    private static let openTabsKey = "openRepositoryTabs"

    private var repoControllers: [RepoWindowController] = []
    private var welcomeControllers: [WelcomeWindowController] = []

    /// The repository shown in the frontmost GitCraft window.
    var activeTab: RepoTab? {
        (NSApp.keyWindow?.windowController as? RepoWindowController)?.tab
    }

    init() {
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if let legacy = UserDefaults.standard.string(forKey: "recentRepository"),
           !recentPaths.contains(legacy)
        {
            recentPaths.insert(legacy, at: 0)
        }
    }

    /// Reopens the repositories that were open when the app last quit.
    /// Returns true if it opened any.
    func restoreTabs() -> Bool {
        let saved = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        var opened = false
        for path in saved where FileManager.default.fileExists(atPath: path) {
            if openRepository(at: URL(fileURLWithPath: path)) { opened = true }
        }
        return opened
    }

    @discardableResult
    func chooseRepository() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return openRepository(at: url)
    }

    /// Opens `url` in a new tab, or brings its existing tab to the front.
    @discardableResult
    func openRepository(at url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if let existing = repoControllers.first(where: { $0.tab.url.standardizedFileURL == standardized }) {
            existing.reveal()
            return true
        }
        do {
            let tab = try RepoTab(url: standardized)
            openError = nil
            recordRecent(path: standardized.path)
            let controller = RepoWindowController(tab: tab, workspace: self)
            repoControllers.append(controller)
            saveOpenTabs()
            tab.startWatcher()
            tab.refresh()
            controller.showInTabs()
            return true
        } catch {
            openError = "Unable to open \(standardized.lastPathComponent): \(error.displayMessage)"
            return false
        }
    }

    func openWelcome() {
        let controller = WelcomeWindowController(workspace: self)
        welcomeControllers.append(controller)
        controller.showInTabs()
    }

    func windowClosed(_ controller: RepoWindowController) {
        controller.tab.stopWatcher()
        repoControllers.removeAll { $0 === controller }
        if !Self.isTerminating {
            saveOpenTabs()
        }
    }

    func welcomeClosed(_ controller: WelcomeWindowController) {
        welcomeControllers.removeAll { $0 === controller }
    }

    private func recordRecent(path: String) {
        var updated = recentPaths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > 8 {
            updated = Array(updated.prefix(8))
        }
        recentPaths = updated
        UserDefaults.standard.set(updated, forKey: Self.recentKey)
    }

    private func saveOpenTabs() {
        UserDefaults.standard.set(repoControllers.map { $0.tab.url.path }, forKey: Self.openTabsKey)
    }
}

@MainActor
final class RepoTab: ObservableObject, Identifiable {
    struct ScrollRequest: Equatable {
        let id = UUID()
        let oidHex: String?
    }

    enum DestructiveAction: Identifiable {
        case discardFile(path: String)
        case deleteBranch(name: String, force: Bool)
        case forceDeleteBranch(name: String)
        case deleteRemoteBranch(name: String)
        case deleteTag(name: String, deleteRemote: Bool)
        case abortMerge
        case abortRebase
        case dropStash(index: UInt32, name: String)

        var id: String {
            switch self {
            case let .discardFile(path): return "discard-\(path)"
            case let .deleteBranch(name, force): return "del-branch-\(name)-\(force)"
            case let .forceDeleteBranch(name): return "force-del-branch-\(name)"
            case let .deleteRemoteBranch(name): return "del-remote-branch-\(name)"
            case let .deleteTag(name, remote): return "del-tag-\(name)-\(remote)"
            case .abortMerge: return "abort-merge"
            case .abortRebase: return "abort-rebase"
            case let .dropStash(index, _): return "drop-stash-\(index)"
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
            case .abortMerge: return "Abort in-progress merge?"
            case .abortRebase: return "Abort in-progress rebase?"
            case let .dropStash(_, name): return "Drop \"\(name)\"?"
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
            case .abortMerge:
                return "This will abort the current merge and restore the repository to its pre-merge state."
            case .abortRebase:
                return "This will stop the rebase and put your branch back as it was before the pull."
            case .dropStash:
                return "The stashed changes will be removed. This can't be undone from GitCraft."
            }
        }

        var confirmLabel: String {
            switch self {
            case .discardFile: return "Discard"
            case .deleteBranch, .deleteRemoteBranch, .deleteTag: return "Delete"
            case .forceDeleteBranch: return "Force Delete"
            case .abortMerge: return "Abort Merge"
            case .abortRebase: return "Abort Rebase"
            case .dropStash: return "Drop"
            }
        }
    }

    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }

    @Published private(set) var currentBranch = ""
    @Published private(set) var isMerging = false
    @Published private(set) var isRebasing = false
    @Published private(set) var hasConflicts = false
    @Published private(set) var stagedFiles: [FileChange] = []
    @Published private(set) var unstagedFiles: [FileChange] = []
    @Published private(set) var commits: [CommitRow] = []
    @Published private(set) var graphRevision = UUID()
    @Published private(set) var branches: [BranchInfo] = []
    @Published private(set) var tags: [TagInfo] = []
    @Published private(set) var stashes: [StashInfo] = []
    @Published private(set) var remotes: [RemoteInfo] = []
    @Published private(set) var selectedCommit: CommitRow?
    @Published private(set) var commitDetail: CommitDetail?
    @Published private(set) var diffRows: [DiffRow] = []
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var selectedFileStaged = false
    @Published private(set) var scrollRequest: ScrollRequest?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var pendingConfirmation: DestructiveAction?
    @Published var searchQuery = ""
    @Published var commitSummary = ""
    @Published var commitBody = ""
    /// Commit with `--no-verify`, so pre-commit and commit-msg hooks don't run.
    @Published var skipHooks = false
    /// Rewrite HEAD's commit instead of making a new one.
    @Published private(set) var amendCommit = false
    @Published var isShowingNewBranchSheet = false
    @Published var newBranchStartPoint: String?
    @Published var isShowingCheckoutCommitSheet = false
    @Published var checkoutCommitOid: String?
    @Published var isShowingNewTagSheet = false
    @Published var newTagTarget: String?
    @Published var isShowingStashSheet = false
    @Published var isShowingRemotesSheet = false
    @Published var remotesSheetStartsAdding = false
    /// When true (default), the graph shows only the checked-out branch and the base branch,
    /// from their fork point. When false, it shows every branch.
    @Published private(set) var scopeToCurrentBranch = true

    var totalChangesCount: Int {
        Set(stagedFiles.map(\.path) + unstagedFiles.map(\.path)).count
    }

    var currentBranchBehindCount: Int {
        Int(branches.first(where: { $0.isHead && !$0.isRemote })?.behind ?? 0)
    }

    var currentBranchAheadCount: Int {
        Int(branches.first(where: { $0.isHead && !$0.isRemote })?.ahead ?? 0)
    }

    private let session: RepoSession
    private var isLoadingMore = false
    private var hasMoreCommits = true
    private let pageSize: UInt32 = 500
    private var watcherTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?
    private var sortObserver: NSObjectProtocol?
    private var lastCommitSort = CommitSortPreference.current
    private var revealTask: Task<Void, Never>?
    /// Bumped whenever the commit list is replaced (refresh, search), so in-flight
    /// page fetches that started against the old list can detect they are stale.
    private var graphGeneration = 0
    /// Search replacements still fetching their first page. While > 0, `commits` and
    /// `searchQuery` describe different lists, so paging must wait.
    private var pendingSearchReplacements = 0
    private var loadedDetailOid: String?

    init(url: URL) throws {
        self.url = url
        self.session = try RepoSession(path: url.path)
    }

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
                // Refs/HEAD/config changes need the full reload; plain file edits (including
                // build output) only need a status refresh, which is far cheaper.
                let (graphDirty, dirty) = await Task.detached {
                    (session.takeGraphDirty(), session.takeDirty())
                }.value
                if graphDirty {
                    self?.refresh()
                } else if dirty {
                    self?.refreshStatus()
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

    func toggleScopeToCurrentBranch() {
        scopeToCurrentBranch.toggle()
        updateSearch(searchQuery)  // reload the graph from the top with the new scope
    }

    private nonisolated static func graphPage(
        _ session: RepoSession,
        scoped: Bool,
        offset: UInt32,
        limit: UInt32,
        query: String?
    ) throws -> [CommitRow] {
        session.setCommitSort(sort: CommitSortPreference.current.core)
        if scoped {
            return try session.getBranchGraph(offset: offset, limit: limit, searchQuery: query)
        }
        return try session.getCommitGraph(offset: offset, limit: limit, searchQuery: query)
    }

    /// Hides git's plumbing header lines (`index`, `---`, `+++`, mode lines). When the diff
    /// spans several files, each file's `diff --git` line is kept as a plain file name so
    /// the files stay distinguishable; a single-file diff needs no header at all.
    nonisolated static func displayRows(_ rows: [DiffRow]) -> [DiffRow] {
        let fileCount = rows.reduce(0) { $0 + ($1.kind == "header" && $1.text.hasPrefix("diff --git ") ? 1 : 0) }
        return rows.compactMap { row in
            guard row.kind == "header" else { return row }
            guard fileCount > 1, row.text.hasPrefix("diff --git ") else { return nil }
            var shown = row
            if let range = row.text.range(of: " b/", options: .backwards) {
                shown.text = String(row.text[range.upperBound...])
            }
            return shown
        }
    }

    /// Re-reads only the working-tree status (staged/unstaged lists and merge state).
    func refreshStatus() {
        let session = self.session
        Task {
            do {
                let status = try await Task.detached { try session.status() }.value
                currentBranch = status.branch.components(separatedBy: "...").first ?? status.branch
                isMerging = status.isMerging
                isRebasing = status.isRebasing
                hasConflicts = status.hasConflicts
                if stagedFiles != status.stagedFiles { stagedFiles = status.stagedFiles }
                if unstagedFiles != status.unstagedFiles { unstagedFiles = status.unstagedFiles }
                if selectedCommit == nil {
                    loadWorkingDiffSelection()
                }
            } catch {
                errorMessage = error.displayMessage
            }
        }
    }

    func refresh() {
        let session = self.session
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery
        // Reload at least everything already loaded: refreshing only the first page would
        // shrink the list under a user who has scrolled further down, yanking the table
        // back up (and the scroll-to-load-more would then immediately refetch).
        let limit = max(pageSize, UInt32(commits.count))
        let scoped = scopeToCurrentBranch

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
                currentBranch = status.branch.components(separatedBy: "...").first ?? status.branch
                isMerging = status.isMerging
                isRebasing = status.isRebasing
                hasConflicts = status.hasConflicts
                stagedFiles = status.stagedFiles
                unstagedFiles = status.unstagedFiles
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
                errorMessage = error.displayMessage
            }
        }
    }

    func loadMoreCommits() {
        guard !isLoadingMore, hasMoreCommits else { return }
        isLoadingMore = true
        let session = self.session
        let offset = UInt32(commits.count)
        let limit = pageSize
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery
        let generation = graphGeneration
        let scoped = scopeToCurrentBranch

        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: offset, limit: limit, query: query)
                }.value
                // The list was replaced while we fetched; this page belongs to the old one.
                guard generation == graphGeneration else { return }
                if nextPage.count < Int(limit) {
                    hasMoreCommits = false
                }
                commits.append(contentsOf: nextPage)
                graphRevision = UUID()
            } catch {
                errorMessage = error.displayMessage
            }
        }
    }

    func updateSearch(_ query: String) {
        searchQuery = query
        graphGeneration += 1  // in-flight page fetches used the old query
        pendingSearchReplacements += 1
        let session = self.session
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q: String? = trimmed.isEmpty ? nil : trimmed
        let limit = pageSize
        let scoped = scopeToCurrentBranch

        Task {
            defer { pendingSearchReplacements -= 1 }
            do {
                let graphRows = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: 0, limit: limit, query: q)
                }.value
                graphGeneration += 1
                commits = graphRows
                graphRevision = UUID()
                hasMoreCommits = graphRows.count >= Int(limit)
            } catch {
                errorMessage = error.displayMessage
            }
        }
    }

    func scrollToCommit(oidHex: String) {
        revealTask?.cancel()
        revealTask = nil
        if let commit = commits.first(where: { $0.oidHex == oidHex }) {
            scrollRequest = ScrollRequest(oidHex: oidHex)
            // Update the detail/diff panes directly rather than relying on the table
            // selection callback, which fires from inside a SwiftUI view update.
            selectCommit(commit)
            return
        }
        // Tip is beyond the loaded page(s): page in more history until it shows up.
        revealTask = Task { await revealCommit(oidHex: oidHex) }
    }

    private func revealCommit(oidHex: String) async {
        while isLoadingMore {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let session = self.session
        // Each graph call re-walks history from the tips (cost ~ offset + limit), so
        // grow the page geometrically: O(log n) calls instead of n / pageSize.
        var limit = pageSize

        while !Task.isCancelled {
            // The new query's first page isn't installed yet: the old list's offset and
            // pagination state don't apply to it, so wait and re-evaluate.
            if pendingSearchReplacements > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            if let commit = commits.first(where: { $0.oidHex == oidHex }) {
                scrollRequest = ScrollRequest(oidHex: oidHex)
                selectCommit(commit)
                return
            }
            guard hasMoreCommits else { break }
            // Re-read offset/query each round: refresh or search may have replaced the list.
            let offset = UInt32(commits.count)
            let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : searchQuery
            let generation = graphGeneration
            let scoped = scopeToCurrentBranch
            do {
                let nextPage = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: offset, limit: limit, query: query)
                }.value
                if Task.isCancelled { return }
                // Stale page (list replaced mid-fetch): drop it and look again.
                if generation != graphGeneration { continue }
                if nextPage.count < Int(limit) { hasMoreCommits = false }
                commits.append(contentsOf: nextPage)
                graphRevision = UUID()
                limit = min(limit * 2, 64_000)
            } catch {
                errorMessage = error.displayMessage
                return
            }
        }
        if Task.isCancelled { return }
        if scopeToCurrentBranch {
            // Outside the Branch view (e.g. another branch picked in the sidebar): switch to
            // All, which reloads the list from the top, then look for the commit again.
            toggleScopeToCurrentBranch()
            revealTask = Task { await self.revealCommit(oidHex: oidHex) }
            return
        }
        // Not reachable in the current graph (e.g. hidden by the search filter): don't
        // leave the panes showing an unrelated commit.
        errorMessage = "That commit isn't in the current commit list."
        // Go through the same path as the sidebar's Working Changes so the table
        // highlight moves with the detail pane.
        scrollToWorkingChanges()
    }

    func scrollToWorkingChanges() {
        revealTask?.cancel()
        revealTask = nil
        scrollRequest = ScrollRequest(oidHex: nil)
        selectCommit(nil)
    }

    /// Selection coming from the commit table (user click/arrow keys, or the table
    /// echoing a programmatic selection). Either way it supersedes a pending reveal:
    /// programmatic table selections only happen after a reveal has finished.
    func selectCommitFromTable(_ commit: CommitRow?) {
        revealTask?.cancel()
        revealTask = nil
        selectCommit(commit)
    }

    func selectCommit(_ commit: CommitRow?) {
        if let commit {
            // Always keep the freshest row (refs/lanes may have changed), but only
            // reload when this oid's detail is already loaded or in flight; a failed
            // load clears the marker so re-clicking the commit retries.
            selectedCommit = commit
            if loadedDetailOid == commit.oidHex { return }
            loadedDetailOid = commit.oidHex
            loadCommitDetails(commit)
        } else {
            guard selectedCommit != nil else { return }
            selectedCommit = nil
            loadedDetailOid = nil
            commitDetail = nil
            loadWorkingDiffSelection()
        }
    }

    func selectWorkingFile(_ file: FileChange) {
        selectedFilePath = file.path
        selectedFileStaged = file.staged
        loadWorkingDiff(path: file.path, staged: file.staged)
    }

    func selectCommitFile(_ path: String?) {
        guard let oid = selectedCommit?.oidHex else { return }
        selectedFilePath = path
        selectedFileStaged = false
        loadCommitDiff(oidHex: oid, path: path)
    }

    private func loadWorkingDiffSelection() {
        if let path = selectedFilePath {
            if selectedFileStaged, stagedFiles.contains(where: { $0.path == path }) {
                loadWorkingDiff(path: path, staged: true)
                return
            }
            if !selectedFileStaged, unstagedFiles.contains(where: { $0.path == path }) {
                loadWorkingDiff(path: path, staged: false)
                return
            }
        }
        if let first = unstagedFiles.first {
            selectWorkingFile(first)
        } else if let firstStaged = stagedFiles.first {
            selectWorkingFile(firstStaged)
        } else {
            selectedFilePath = nil
            diffRows = []
        }
    }

    private func loadWorkingDiff(path: String, staged: Bool) {
        let session = self.session
        Task {
            do {
                let rows = try await Task.detached {
                    try session.getWorkingDiff(path: path, staged: staged)
                }.value
                if selectedCommit == nil && selectedFilePath == path && selectedFileStaged == staged {
                    diffRows = Self.displayRows(rows)
                }
            } catch {
                errorMessage = error.displayMessage
            }
        }
    }

    private func loadCommitDetails(_ commit: CommitRow) {
        let session = self.session
        let oid = commit.oidHex
        Task {
            do {
                let detail = try await Task.detached {
                    try session.getCommitDetail(oidHex: oid)
                }.value
                guard selectedCommit?.oidHex == oid else { return }
                commitDetail = detail
                let firstPath = detail.files.first?.path
                selectedFilePath = firstPath
                loadCommitDiff(oidHex: oid, path: firstPath)
            } catch {
                if loadedDetailOid == oid { loadedDetailOid = nil }
                errorMessage = error.displayMessage
            }
        }
    }

    private func loadCommitDiff(oidHex: String, path: String?) {
        let session = self.session
        Task {
            do {
                let rows = try await Task.detached {
                    try session.getCommitDiff(oidHex: oidHex, path: path)
                }.value
                if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                    diffRows = Self.displayRows(rows)
                }
            } catch {
                // Only react if this request is still the current one (same commit and file);
                // a late failure for a file the user already moved off must not wipe the
                // newer file's diff.
                if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                    // Don't leave the previous diff showing, and let re-selecting
                    // this commit retry the load.
                    diffRows = []
                    loadedDetailOid = nil
                }
                errorMessage = error.displayMessage
            }
        }
    }

    // MARK: - Git Mutations

    func stageFile(_ path: String) {
        performMutation { session in
            try session.stage(path: path)
        }
    }

    func unstageFile(_ path: String) {
        performMutation { session in
            try session.unstage(path: path)
        }
    }

    func stageAll() {
        performMutation { session in
            try session.stageAll()
        }
    }

    func unstageAll() {
        performMutation { session in
            try session.unstageAll()
        }
    }

    func discardFile(_ path: String) {
        performMutation { session in
            try session.discardFile(path: path)
        }
    }

    func ignorePath(_ path: String, localOnly: Bool) {
        performMutation { session in
            try session.ignorePath(path: path, localOnly: localOnly)
        }
    }

    /// Runs a remote mutation and reports success/failure to the caller (used by the
    /// remotes sheet so it can keep the form open on error).
    func addRemote(name: String, url: String, onSuccess: (@MainActor () -> Void)? = nil) {
        performMutation { session in try session.addRemote(name: name, url: url) } onSuccess: { onSuccess?() }
    }

    /// Applies a URL change and/or rename in one mutation so the two steps stay ordered.
    func updateRemote(_ remote: RemoteInfo, newName: String, newURL: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        performMutation { session in
            if url != remote.fetchUrl || url != remote.pushUrl {
                try session.setRemoteUrl(name: remote.name, url: url)
            }
            if name != remote.name {
                try session.renameRemote(oldName: remote.name, newName: name)
            }
        }
    }

    func removeRemote(_ name: String) {
        performMutation { session in try session.removeRemote(name: name) }
    }

    func fetchRemote(_ name: String) {
        let includeTags = GitPreferences.fetchIncludesTags
        performMutation { session in try session.fetchRemote(name: name, includeTags: includeTags) }
    }

    /// Turns Amend on or off. Turning it on fills an empty message with HEAD's message.
    func setAmend(_ on: Bool) {
        amendCommit = on
        guard on, commitSummary.isEmpty, commitBody.isEmpty else { return }
        let session = self.session
        Task {
            guard let message = try? await Task.detached { try session.headCommitMessage() }.value,
                  self.amendCommit, self.commitSummary.isEmpty, self.commitBody.isEmpty else { return }
            let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            self.commitSummary = String(lines.first ?? "")
            self.commitBody = lines.count > 1
                ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        }
    }

    func commitChanges() {
        let summary = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        let body = commitBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullMessage = body.isEmpty ? summary : "\(summary)\n\n\(body)"
        // Hand-picked staging wins: auto-staging only fills in when nothing is staged.
        let autoStage = GitPreferences.shouldStageAll(
            autoStage: GitPreferences.autoStageOnCommit,
            stagedCount: stagedFiles.count
        )
        let skip = skipHooks
        let amend = amendCommit

        // One mutation, so staging and committing happen together and the UI sees a single step.
        performMutation { session in
            if autoStage {
                try session.stageAll()
            }
            try session.commitWithOptions(message: fullMessage, skipHooks: skip, amend: amend)
        } onSuccess: { [weak self] in
            self?.commitSummary = ""
            self?.commitBody = ""
            self?.amendCommit = false
            self?.skipHooks = false
            if GitPreferences.pushOnCommit {
                // Hop to the next run-loop turn so this mutation finishes (and clears
                // `isBusy`) before the push starts its own.
                DispatchQueue.main.async { self?.runRemote(.push) }
            }
        }
    }

    /// Opens the Checkout Commit sheet for `oid`. Checking out a commit detaches HEAD, as the sheet says.
    func requestCheckoutCommit(_ oid: String) {
        checkoutCommitOid = oid
        isShowingCheckoutCommitSheet = true
    }

    /// Detached checkout of `oid`, handling local changes the same way creating a branch does.
    func checkoutCommit(_ oid: String, localChanges: LocalChangesHandling = .doNotChange) {
        let hasLocalChanges = totalChangesCount > 0
        performMutation { session in
            if hasLocalChanges {
                switch localChanges {
                case .doNotChange:
                    try session.checkoutBranch(branchName: oid)
                case .stashAndReapply:
                    try session.stashPush(message: "Auto-stash before checking out \(oid.prefix(7))", includeUntracked: true)
                    do {
                        try session.checkoutBranch(branchName: oid)
                    } catch {
                        try? session.stashPop(index: 0)
                        throw error
                    }
                    try session.stashPop(index: 0)
                case .discard:
                    for file in try session.status().files {
                        try session.discardFile(path: file)
                    }
                    try session.checkoutBranch(branchName: oid)
                }
            } else {
                try session.checkoutBranch(branchName: oid)
            }
        }
    }

    func checkoutBranch(_ branchName: String) {
        performMutation { session in
            try session.checkoutBranch(branchName: branchName)
        }
    }

    enum LocalChangesHandling: String, CaseIterable, Identifiable {
        case doNotChange
        case stashAndReapply
        case discard

        var id: String { rawValue }
    }

    func createBranch(
        name: String,
        startPoint: String?,
        checkout: Bool,
        localChanges: LocalChangesHandling = .doNotChange
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hasLocalChanges = totalChangesCount > 0
        performMutation { session in
            if checkout && hasLocalChanges {
                switch localChanges {
                case .doNotChange:
                    try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: true)
                case .stashAndReapply:
                    try session.stashPush(message: "Auto-stash before creating \(trimmed)", includeUntracked: true)
                    do {
                        try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: true)
                    } catch {
                        try? session.stashPop(index: 0)
                        throw error
                    }
                    try session.stashPop(index: 0)
                case .discard:
                    for file in try session.status().files {
                        try session.discardFile(path: file)
                    }
                    try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: true)
                }
            } else {
                try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: checkout)
            }
        }
    }

    func deleteBranch(_ branchName: String, force: Bool) {
        performMutation({ session in
            try session.deleteBranch(branchName: branchName, force: force)
        }, onFailure: { [weak self] error in
            // A safe delete refused because the branch has unmerged commits: ask before forcing.
            guard !force, error.displayMessage.contains("is not fully merged") else { return false }
            self?.pendingConfirmation = .forceDeleteBranch(name: branchName)
            return true
        })
    }

    func deleteRemoteBranch(_ branchName: String) {
        performMutation { session in
            try session.deleteRemoteBranch(branchName: branchName)
        }
    }

    func mergeBranch(_ branchName: String) {
        performMutation { session in
            try session.mergeBranch(branchName: branchName)
        }
    }

    func abortRebase() {
        performMutation { session in
            try session.abortRebase()
        }
    }

    func continueRebase() {
        performMutation { session in
            try session.continueRebase()
        }
    }

    func abortMerge() {
        performMutation { session in
            try session.abortMerge()
        }
    }

    func executeConfirmed(_ action: DestructiveAction) {
        pendingConfirmation = nil
        switch action {
        case let .discardFile(path):
            discardFile(path)
        case let .deleteBranch(name, force):
            deleteBranch(name, force: force)
        case let .forceDeleteBranch(name):
            deleteBranch(name, force: true)
        case let .deleteRemoteBranch(name):
            deleteRemoteBranch(name)
        case let .deleteTag(name, deleteRemote):
            deleteTag(name, deleteRemote: deleteRemote)
        case .abortMerge:
            abortMerge()
        case .abortRebase:
            abortRebase()
        case let .dropStash(index, _):
            stashDrop(index)
        }
    }

    func createTag(name: String, target: String?, message: String?, pushToRemote: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMsg = (msg?.isEmpty == false) ? msg : nil
        performMutation { session in
            try session.createTag(
                tagName: trimmed,
                target: target,
                message: finalMsg,
                pushToRemote: pushToRemote
            )
        }
    }

    func deleteTag(_ tagName: String, deleteRemote: Bool) {
        performMutation { session in
            try session.deleteTag(tagName: tagName, deleteRemote: deleteRemote)
        }
    }

    func pushTag(_ tagName: String) {
        performMutation { session in
            try session.pushTag(tagName: tagName)
        }
    }

    func stashPush(message: String?, includeUntracked: Bool) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = (trimmed?.isEmpty == false) ? trimmed : nil
        performMutation { session in
            try session.stashPush(message: msg, includeUntracked: includeUntracked)
        }
    }

    func stashApply(_ index: UInt32) {
        performMutation { session in
            try session.stashApply(index: index)
        }
    }

    func stashPop(_ index: UInt32) {
        performMutation { session in
            try session.stashPop(index: index)
        }
    }

    func stashDrop(_ index: UInt32) {
        performMutation { session in
            try session.stashDrop(index: index)
        }
    }

    func runRemote(_ operation: RemoteOperation) {
        let pullStrategy = PullStrategyPreference.current.core
        let includeTags = GitPreferences.fetchIncludesTags
        performMutation { session in
            switch operation {
            case .fetch: try session.fetch(includeTags: includeTags)
            case .pull: try session.pull(strategy: pullStrategy)
            case .push: try session.push()
            }
        }
    }

    func copyOid(_ oid: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(oid, forType: .string)
    }

    /// Runs `work` off the main thread, then refreshes. `onFailure` gets the first chance to
    /// handle an error; returning true means it did, so the error banner is skipped.
    private func performMutation(
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
                onSuccess?()
                refresh()
            } catch {
                if let onFailure, onFailure(error) { return }
                errorMessage = error.displayMessage
            }
        }
    }
}


extension Error {
    /// The text to show a person for an error. Errors from the Rust core wrap git's own
    /// message in `GitCraftError.Message(msg:)`, whose default description is noisy.
    var displayMessage: String {
        if let error = self as? GitCraftError {
            switch error {
            case let .Message(msg):
                return msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return localizedDescription
    }
}

/// Splits an error message into a one-line summary for the banner and the full text for
/// the details sheet.
struct ErrorSummary: Equatable {
    /// Banner text: the line that reports the error, cut to a readable length.
    let summary: String
    /// The whole message, shown in the details sheet.
    let full: String
    /// True when the banner can't show everything (several lines, or a long line).
    let hasDetails: Bool

    static let maxSummaryLength = 140

    /// Lines such as "error: ..." or "fatal: ..." name the failure. Hook and step banners
    /// ("pre-push: cargo clippy") come before it, so the first line alone can mislead.
    private static func isErrorLine(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("error") || lowered.hasPrefix("fatal")
    }

    init(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        let first = lines.first(where: Self.isErrorLine) ?? lines.first ?? trimmed
        full = trimmed
        if first.count > Self.maxSummaryLength {
            summary = String(first.prefix(Self.maxSummaryLength)) + "…"
            hasDetails = true
        } else {
            summary = first
            hasDetails = lines.count > 1
        }
    }
}

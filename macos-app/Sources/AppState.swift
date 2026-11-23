import AppKit
import SwiftUI

enum RemoteOperation {
    case fetch, pull, push
}

@MainActor
final class WorkspaceState: ObservableObject {
    @Published var tabs: [RepoTab] = []
    @Published var selectedTabID: UUID?
    @Published var recentPaths: [String] = []
    @Published var openError: String?

    private static let recentKey = "recentRepositories"
    private static let openTabsKey = "openRepositoryTabs"

    var activeTab: RepoTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    init() {
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if let legacy = UserDefaults.standard.string(forKey: "recentRepository"),
           !recentPaths.contains(legacy)
        {
            recentPaths.insert(legacy, at: 0)
        }
    }

    func restoreTabs() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        for path in saved where FileManager.default.fileExists(atPath: path) {
            openRepository(at: URL(fileURLWithPath: path), persist: false)
        }
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openRepository(at: url)
    }

    func openRepository(at url: URL, persist: Bool = true) {
        let standardized = url.standardizedFileURL
        if let existing = tabs.first(where: { $0.url.standardizedFileURL == standardized }) {
            selectedTabID = existing.id
            return
        }

        do {
            let tab = try RepoTab(url: standardized)
            tabs.append(tab)
            selectedTabID = tab.id
            openError = nil
            recordRecent(path: standardized.path)
            if persist {
                saveOpenTabs()
            }
            tab.startWatcher()
            tab.refresh()
        } catch {
            openError = "Unable to open \(standardized.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: idx)
        removed.stopWatcher()

        if selectedTabID == id {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let nextIdx = min(idx, tabs.count - 1)
                selectedTabID = tabs[nextIdx].id
            }
        }
        saveOpenTabs()
    }

    func closeActiveTab() {
        if let id = selectedTabID {
            closeTab(id)
        }
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
        let paths = tabs.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: Self.openTabsKey)
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
        case deleteTag(name: String, deleteRemote: Bool)
        case abortMerge

        var id: String {
            switch self {
            case let .discardFile(path): return "discard-\(path)"
            case let .deleteBranch(name, force): return "del-branch-\(name)-\(force)"
            case let .deleteTag(name, remote): return "del-tag-\(name)-\(remote)"
            case .abortMerge: return "abort-merge"
            }
        }

        var title: String {
            switch self {
            case let .discardFile(path): return "Discard changes to \"\(path)\"?"
            case let .deleteBranch(name, _): return "Delete branch \"\(name)\"?"
            case let .deleteTag(name, remote):
                return remote ? "Delete tag \"\(name)\" locally and from remote?" : "Delete local tag \"\(name)\"?"
            case .abortMerge: return "Abort in-progress merge?"
            }
        }

        var message: String {
            switch self {
            case .discardFile:
                return "This will permanently revert your uncommitted changes to this file."
            case .deleteBranch:
                return "This will delete the local branch reference."
            case let .deleteTag(_, remote):
                return remote
                    ? "This will delete the tag locally and push the deletion to the remote repository."
                    : "This will remove the tag from your local repository."
            case .abortMerge:
                return "This will abort the current merge and restore the repository to its pre-merge state."
            }
        }

        var confirmLabel: String {
            switch self {
            case .discardFile: return "Discard"
            case .deleteBranch, .deleteTag: return "Delete"
            case .abortMerge: return "Abort Merge"
            }
        }
    }

    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }

    @Published private(set) var currentBranch = ""
    @Published private(set) var isMerging = false
    @Published private(set) var hasConflicts = false
    @Published private(set) var stagedFiles: [FileChange] = []
    @Published private(set) var unstagedFiles: [FileChange] = []
    @Published private(set) var commits: [CommitRow] = []
    @Published private(set) var graphRevision = UUID()
    @Published private(set) var branches: [BranchInfo] = []
    @Published private(set) var tags: [TagInfo] = []
    @Published private(set) var stashes: [StashInfo] = []
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
    @Published var isShowingNewBranchSheet = false
    @Published var newBranchStartPoint: String?
    @Published var isShowingNewTagSheet = false
    @Published var newTagTarget: String?
    @Published var isShowingStashSheet = false

    var totalChangesCount: Int {
        Set(stagedFiles.map(\.path) + unstagedFiles.map(\.path)).count
    }

    private let session: RepoSession
    private var isLoadingMore = false
    private var hasMoreCommits = true
    private let pageSize: UInt32 = 500
    private var watcherTask: Task<Void, Never>?

    init(url: URL) throws {
        self.url = url
        self.session = try RepoSession(path: url.path)
    }

    func startWatcher() {
        watcherTask?.cancel()
        let session = self.session
        watcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                let dirty = await Task.detached { session.takeDirty() }.value
                if dirty {
                    self?.refresh()
                }
            }
        }
    }

    func stopWatcher() {
        watcherTask?.cancel()
        watcherTask = nil
    }

    func refresh() {
        let session = self.session
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery
        let limit = pageSize

        Task {
            do {
                async let statusTask = Task.detached { try session.status() }.value
                async let branchesTask = Task.detached { try session.listBranches() }.value
                async let tagsTask = Task.detached { try session.listTags() }.value
                async let stashesTask = Task.detached { try session.listStashes() }.value
                async let graphTask = Task.detached {
                    try session.getCommitGraph(offset: 0, limit: limit, searchQuery: query)
                }.value

                let (status, branchList, tagList, stashList, graphRows) = try await (
                    statusTask,
                    branchesTask,
                    tagsTask,
                    stashesTask,
                    graphTask
                )
                currentBranch = status.branch.components(separatedBy: "...").first ?? status.branch
                isMerging = status.isMerging
                hasConflicts = status.hasConflicts
                stagedFiles = status.stagedFiles
                unstagedFiles = status.unstagedFiles
                branches = branchList
                tags = tagList
                stashes = stashList
                commits = graphRows
                graphRevision = UUID()
                hasMoreCommits = graphRows.count >= Int(limit)

                if selectedCommit == nil {
                    loadWorkingDiffSelection()
                }
            } catch {
                errorMessage = error.localizedDescription
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

        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = try await Task.detached {
                    try session.getCommitGraph(offset: offset, limit: limit, searchQuery: query)
                }.value
                if nextPage.count < Int(limit) {
                    hasMoreCommits = false
                }
                commits.append(contentsOf: nextPage)
                graphRevision = UUID()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateSearch(_ query: String) {
        searchQuery = query
        let session = self.session
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q: String? = trimmed.isEmpty ? nil : trimmed
        let limit = pageSize

        Task {
            do {
                let graphRows = try await Task.detached {
                    try session.getCommitGraph(offset: 0, limit: limit, searchQuery: q)
                }.value
                commits = graphRows
                graphRevision = UUID()
                hasMoreCommits = graphRows.count >= Int(limit)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func scrollToCommit(oidHex: String) {
        scrollRequest = ScrollRequest(oidHex: oidHex)
        // Update the detail/diff panes directly rather than relying on the table
        // selection callback, which fires from inside a SwiftUI view update.
        if let commit = commits.first(where: { $0.oidHex == oidHex }) {
            selectCommit(commit)
        }
    }

    func scrollToWorkingChanges() {
        scrollRequest = ScrollRequest(oidHex: nil)
        selectCommit(nil)
    }

    func selectCommit(_ commit: CommitRow?) {
        if let commit, selectedCommit?.oidHex == commit.oidHex { return }
        selectedCommit = commit
        if let commit {
            loadCommitDetails(commit)
        } else {
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
                    diffRows = rows
                }
            } catch {
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
                    diffRows = rows
                }
            } catch {
                errorMessage = error.localizedDescription
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

    func commitChanges() {
        let summary = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        let body = commitBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullMessage = body.isEmpty ? summary : "\(summary)\n\n\(body)"

        performMutation { session in
            try session.commit(message: fullMessage)
        } onSuccess: { [weak self] in
            self?.commitSummary = ""
            self?.commitBody = ""
        }
    }

    func checkoutBranch(_ branchName: String) {
        performMutation { session in
            try session.checkoutBranch(branchName: branchName)
        }
    }

    func createBranch(name: String, startPoint: String?, checkout: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performMutation { session in
            try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: checkout)
        }
    }

    func deleteBranch(_ branchName: String, force: Bool) {
        performMutation { session in
            try session.deleteBranch(branchName: branchName, force: force)
        }
    }

    func mergeBranch(_ branchName: String) {
        performMutation { session in
            try session.mergeBranch(branchName: branchName)
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
        case let .deleteTag(name, deleteRemote):
            deleteTag(name, deleteRemote: deleteRemote)
        case .abortMerge:
            abortMerge()
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
        performMutation { session in
            switch operation {
            case .fetch: try session.fetch()
            case .pull: try session.pull()
            case .push: try session.push()
            }
        }
    }

    func copyOid(_ oid: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(oid, forType: .string)
    }

    private func performMutation(
        _ work: @escaping @Sendable (RepoSession) throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
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
                errorMessage = error.localizedDescription
            }
        }
    }
}

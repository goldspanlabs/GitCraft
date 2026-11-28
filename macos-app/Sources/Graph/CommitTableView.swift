import AppKit
import SwiftUI

/// Git operations offered from a commit's context menu.
enum CommitAction {
    case merge
    case rebase
    case reset(ResetMode)
    case cherryPick
    case revert
}

extension Notification.Name {
    /// Posted to move keyboard focus (arrow keys) back to the commit list.
    static let focusCommitTable = Notification.Name("GitCraft.focusCommitTable")
}

struct CommitTableView: NSViewRepresentable {
    let rows: [CommitRow]
    let totalCommitCount: Int
    let isSearchActive: Bool
    let graphRevision: UUID
    let graphGeneration: Int
    let workingChangesCount: Int
    /// Hosting service per remote name, for the icon on remote-branch chips.
    let remoteHosts: [String: RemoteHost]
    let worktrees: [WorktreeInfo]
    let showTags: Bool
    let showAvatars: Bool
    let isBusy: Bool
    let scrollRequest: RepoTab.ScrollRequest?
    let onLoadMore: () -> Void
    let onFetchWindow: (Int, Int) async throws -> [CommitRow]
    /// Reads rows straight from the commit index, or nil when it can't answer right away.
    var onCachedWindow: (Int, Int) -> [CommitRow]? = { _, _ in nil }
    /// The selected commits in list order: none for Working Changes or no selection.
    let onSelectCommits: ([CommitRow]) -> Void
    let onCopyOid: (String) -> Void
    let onCopyOids: ([String]) -> Void
    /// Whether the multi-selection can be squashed.
    let squashCheck: SquashCheck
    let onSquash: (SquashPreview) -> Void
    let onCreateBranchAtCommit: (String) -> Void
    let onCreateTagAtCommit: (String) -> Void
    let onCreateWorktreeAtCommit: (String) -> Void
    let canRemoveWorktree: (WorktreeInfo) -> Bool
    let onRemoveWorktree: (WorktreeInfo) -> Void
    let onCheckoutCommit: (String) -> Void
    /// The checked-out branch's name; empty when HEAD is detached.
    let currentBranch: String
    let onCommitAction: (CommitAction, String) -> Void
    var onClickWorkingChanges: () -> Void = {}
    var workingChangesMenu: () -> [MenuEntry] = { [] }
    var onMakeGitDrag: ([String]) -> GitDragPayload? = { _ in nil }
    var onValidateGitDrop: (GitDragPayload, GitDropTarget, Bool) -> Bool = { _, _, _ in false }
    var onGitDrop: (GitDragPayload, GitDropTarget, Bool) -> Void = { _, _, _ in }
    var onEndGitDrag: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            totalCommitCount: totalCommitCount,
            isSearchActive: isSearchActive,
            workingChangesCount: workingChangesCount,
            onLoadMore: onLoadMore,
            onFetchWindow: onFetchWindow,
            onSelectCommits: onSelectCommits,
            onCopyOid: onCopyOid,
            onCreateBranchAtCommit: onCreateBranchAtCommit,
            onCreateTagAtCommit: onCreateTagAtCommit,
            onCreateWorktreeAtCommit: onCreateWorktreeAtCommit,
            canRemoveWorktree: canRemoveWorktree,
            onRemoveWorktree: onRemoveWorktree,
            onCheckoutCommit: onCheckoutCommit
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let table = CommitNSTableView()
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.backgroundColor = .textBackgroundColor
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([GitDragPayload.pasteboardType])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.oidsForCopy = { [weak table, weak coordinator = context.coordinator] in
            guard let table, let coordinator else { return [] }
            return table.selectedRowIndexes.compactMap { coordinator.commitOid(atRow: $0) }
        }
        table.onExitGitDrop = { [weak coordinator = context.coordinator] in coordinator?.onEndGitDrag() }
        table.onCopy = { [weak coordinator = context.coordinator] in coordinator?.onCopyOids($0) }
        table.onClickWorkingChanges = { [weak coordinator = context.coordinator] in coordinator?.onClickWorkingChanges() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        scrollView.documentView = table
        PaneScrollerVisibility.install(on: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.tableView = table
        context.coordinator.observeScroll(scrollView.contentView)
        context.coordinator.observeFocusRequests()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let newWorktreeBranches = Set(worktrees.filter { !$0.isPrunable }.compactMap(\.branch))
        let revisionChanged = coordinator.lastGraphRevision != graphRevision
        let metadataChanged = coordinator.workingChangesCount != workingChangesCount
            || coordinator.remoteHosts != remoteHosts
            || coordinator.worktreeBranches != newWorktreeBranches
            || coordinator.showTags != showTags
            || coordinator.showAvatars != showAvatars
        let dataChanged = revisionChanged || metadataChanged

        let oldTotalCount = max(coordinator.rows.count, coordinator.totalCommitCount)
        let newTotalCount = max(rows.count, totalCommitCount)
        let sameGeneration = coordinator.lastGraphRevision != nil
            && coordinator.lastGraphGeneration == graphGeneration
        let isAppendOnly = revisionChanged
            && !metadataChanged
            && sameGeneration
            && newTotalCount > oldTotalCount
            && table.numberOfRows == 1 + oldTotalCount
        let isEmptyAppend = revisionChanged
            && !metadataChanged
            && sameGeneration
            && newTotalCount == oldTotalCount
            && table.numberOfRows == 1 + oldTotalCount

        // Remember what is selected (by commit, not row index) before the data is swapped.
        let selectedRowsBefore = table.selectedRowIndexes
        let selectedOidsBefore = Set(selectedRowsBefore.compactMap { coordinator.commitOid(atRow: $0) })

        if revisionChanged {
            coordinator.lastGraphRevision = graphRevision
            coordinator.lastGraphGeneration = graphGeneration
        }
        if !sameGeneration {
            coordinator.clearWindowCache()
        }
        coordinator.rows = rows
        coordinator.totalCommitCount = totalCommitCount
        coordinator.isSearchActive = isSearchActive
        coordinator.workingChangesCount = workingChangesCount
        coordinator.remoteHosts = remoteHosts
        coordinator.worktrees = worktrees
        coordinator.worktreeBranches = newWorktreeBranches
        coordinator.showTags = showTags
        coordinator.showAvatars = showAvatars
        coordinator.isBusy = isBusy
        coordinator.onLoadMore = onLoadMore
        coordinator.onFetchWindow = onFetchWindow
        coordinator.onCachedWindow = onCachedWindow
        coordinator.onSelectCommits = onSelectCommits
        coordinator.onCopyOid = onCopyOid
        coordinator.onCopyOids = onCopyOids
        coordinator.squashCheck = squashCheck
        coordinator.onSquash = onSquash
        coordinator.onCreateBranchAtCommit = onCreateBranchAtCommit
        coordinator.onCreateTagAtCommit = onCreateTagAtCommit
        coordinator.onCreateWorktreeAtCommit = onCreateWorktreeAtCommit
        coordinator.canRemoveWorktree = canRemoveWorktree
        coordinator.onRemoveWorktree = onRemoveWorktree
        coordinator.onCheckoutCommit = onCheckoutCommit
        coordinator.currentBranch = currentBranch
        coordinator.onCommitAction = onCommitAction
        coordinator.onClickWorkingChanges = onClickWorkingChanges
        coordinator.workingChangesMenu = workingChangesMenu
        coordinator.onMakeGitDrag = onMakeGitDrag
        coordinator.onValidateGitDrop = onValidateGitDrop
        coordinator.onGitDrop = onGitDrop
        coordinator.onEndGitDrag = onEndGitDrag

        if isAppendOnly {
            // Pagination or background indexing only grows the list at the bottom; inserting
            // the new rows leaves existing visible cells (and selection) untouched without flickering.
            let inserted = IndexSet(integersIn: (1 + oldTotalCount)..<(1 + newTotalCount))
            table.insertRows(at: inserted, withAnimation: [])
        } else if dataChanged && !isEmptyAppend {
            // Reload/restore is not a user selection: keep it from reaching the model, where
            // it would cancel a pending branch reveal or deselect the current commit.
            coordinator.isRestoringSelection = true
            table.reloadData()
            // The model drops commits that vanished from a multi-selection (`reconcileSelection`),
            // so this only has to put the survivors back.
            Coordinator.restoreSelection(
                in: table,
                oids: rows.map(\.oidHex),
                selected: selectedOidsBefore,
                workingChanges: selectedRowsBefore.contains(0)
            )
            coordinator.isRestoringSelection = false
        }

        if let request = scrollRequest, coordinator.lastHandledScrollID != request.id {
            coordinator.lastHandledScrollID = request.id
            if let offset = request.prefetchedOffset, let prefetched = request.prefetchedRows {
                coordinator.insertIntoWindowCache(offset: offset, fetched: prefetched)
            }
            let requestedOid = request.oidHex
            let requestedRowIndex = request.rowIndex
            // Defer: selecting fires the delegate, which publishes state, and that
            // must not happen during a SwiftUI view update (the change can be dropped).
            // Resolve the row inside the block so a graph refresh in between can't
            // leave us with a stale index.
            DispatchQueue.main.async { [weak table, weak coordinator] in
                guard let table, let coordinator else { return }
                let targetRow: Int
                if let rowIdx = requestedRowIndex {
                    targetRow = rowIdx + 1
                } else if let oid = requestedOid {
                    if let idx = coordinator.rows.firstIndex(where: { $0.oidHex == oid }) {
                        targetRow = idx + 1
                    } else if let idx = coordinator.windowCache.first(where: { $0.value.oidHex == oid })?.key {
                        targetRow = idx + 1
                    } else {
                        return
                    }
                } else {
                    targetRow = 0
                }
                guard targetRow < coordinator.numberOfRows(in: table) else { return }
                table.scrollRowToVisible(targetRow)
                table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var rows: [CommitRow]
        var totalCommitCount: Int
        var isSearchActive: Bool
        var workingChangesCount: Int
        var remoteHosts: [String: RemoteHost] = [:]
        var worktrees: [WorktreeInfo] = []
        /// Branches checked out in some worktree. Cached here rather than recomputed per row.
        var worktreeBranches: Set<String> = []
        var showTags = true
        var showAvatars = AvatarPreference.isEnabled()
        var isBusy = false
        var lastGraphRevision: UUID?
        var lastGraphGeneration: Int?
        var onLoadMore: () -> Void
        var onFetchWindow: (Int, Int) async throws -> [CommitRow]
        var onCachedWindow: (Int, Int) -> [CommitRow]? = { _, _ in nil }
        var onSelectCommits: ([CommitRow]) -> Void
        var onCopyOid: (String) -> Void
        var onCopyOids: ([String]) -> Void = { _ in }
        var squashCheck = SquashCheck.checking
        var onSquash: (SquashPreview) -> Void = { _ in }
        var onCreateBranchAtCommit: (String) -> Void
        var onCreateTagAtCommit: (String) -> Void
        var onCreateWorktreeAtCommit: (String) -> Void
        var canRemoveWorktree: (WorktreeInfo) -> Bool
        var onRemoveWorktree: (WorktreeInfo) -> Void
        var onCheckoutCommit: (String) -> Void
        var currentBranch = ""
        var onCommitAction: (CommitAction, String) -> Void = { _, _ in }
        var onClickWorkingChanges: () -> Void = {}
        var workingChangesMenu: () -> [MenuEntry] = { [] }
        var onMakeGitDrag: ([String]) -> GitDragPayload? = { _ in nil }
        var onValidateGitDrop: (GitDragPayload, GitDropTarget, Bool) -> Bool = { _, _, _ in false }
        var onGitDrop: (GitDragPayload, GitDropTarget, Bool) -> Void = { _, _, _ in }
        var onEndGitDrag: () -> Void = {}

        var lastHandledScrollID: UUID?
        var isRestoringSelection = false
        weak var tableView: NSTableView?
        private var boundsObserver: NSObjectProtocol?
        private var focusObserver: NSObjectProtocol?

        /// Sparse cache of materialized rows for indices beyond `rows.count` (virtualized mode).
        var windowCache: [Int: CommitRow] = [:]
        private var windowFetchTask: Task<Void, Never>?
        private static let maxCachedWindowRows = 4_000
        private static let windowPadding = 120
        /// Rows read per synchronous index lookup: a few screens, and quick enough mid-scroll.
        private static let cachedChunkSize = 128

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("CommitRowCell")

        init(
            rows: [CommitRow],
            totalCommitCount: Int,
            isSearchActive: Bool,
            workingChangesCount: Int,
            onLoadMore: @escaping () -> Void,
            onFetchWindow: @escaping (Int, Int) async throws -> [CommitRow],
            onSelectCommits: @escaping ([CommitRow]) -> Void,
            onCopyOid: @escaping (String) -> Void,
            onCreateBranchAtCommit: @escaping (String) -> Void,
            onCreateTagAtCommit: @escaping (String) -> Void,
            onCreateWorktreeAtCommit: @escaping (String) -> Void,
            canRemoveWorktree: @escaping (WorktreeInfo) -> Bool,
            onRemoveWorktree: @escaping (WorktreeInfo) -> Void,
            onCheckoutCommit: @escaping (String) -> Void
        ) {
            self.rows = rows
            self.totalCommitCount = totalCommitCount
            self.isSearchActive = isSearchActive
            self.workingChangesCount = workingChangesCount
            self.onLoadMore = onLoadMore
            self.onFetchWindow = onFetchWindow
            self.onSelectCommits = onSelectCommits
            self.onCopyOid = onCopyOid
            self.onCreateBranchAtCommit = onCreateBranchAtCommit
            self.onCreateTagAtCommit = onCreateTagAtCommit
            self.onCreateWorktreeAtCommit = onCreateWorktreeAtCommit
            self.canRemoveWorktree = canRemoveWorktree
            self.onRemoveWorktree = onRemoveWorktree
            self.onCheckoutCommit = onCheckoutCommit
        }

        func clearWindowCache() {
            windowFetchTask?.cancel()
            windowFetchTask = nil
            windowCache.removeAll(keepingCapacity: true)
        }

        func insertIntoWindowCache(offset: Int, fetched: [CommitRow], anchor: Int? = nil) {
            for (i, commit) in fetched.enumerated() {
                windowCache[offset + i] = commit
            }
            if windowCache.count > Self.maxCachedWindowRows {
                let center = anchor ?? (offset + fetched.count / 2)
                // Trim well below the cap so scrolling doesn't sort the cache on every insert.
                let excess = windowCache.count - Self.maxCachedWindowRows * 3 / 4
                let toEvict = windowCache.keys
                    .sorted { abs($0 - center) > abs($1 - center) }
                    .prefix(excess)
                for key in toEvict {
                    windowCache.removeValue(forKey: key)
                }
            }
        }

        /// The commit shown in table row `row`. Row 0 is Working Changes, so it has none.
        func commit(atRow row: Int) -> CommitRow? {
            guard row > 0 else { return nil }
            let idx = row - 1
            if idx < rows.count {
                return rows[idx]
            }
            return windowCache[idx]
        }

        func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet,
                       to pasteboard: NSPasteboard) -> Bool {
            guard !isBusy, !rowIndexes.contains(0) else { return false }
            let oids = rowIndexes.compactMap { commitOid(atRow: $0) }
            guard oids.count == rowIndexes.count, let payload = onMakeGitDrag(oids),
                  let data = payload.data else { return false }
            pasteboard.declareTypes([GitDragPayload.pasteboardType], owner: nil)
            return pasteboard.setData(data, forType: GitDragPayload.pasteboardType)
        }

        private func dropTarget(_ table: NSTableView, info: NSDraggingInfo) -> (Int, GitDropTarget)? {
            let row = table.row(at: table.convert(info.draggingLocation, from: nil))
            if row == 0 { return (row, .head) }
            guard let oid = commitOid(atRow: row) else { return nil }
            return (row, .commit(oid))
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let payload = GitDragPayload.read(from: info.draggingPasteboard),
                  let (targetRow, target) = dropTarget(tableView, info: info) else {
                onEndGitDrag()
                return []
            }
            let option = NSEvent.modifierFlags.contains(.option)
            guard onValidateGitDrop(payload, target, option) else { return [] }
            tableView.setDropRow(targetRow, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let payload = GitDragPayload.read(from: info.draggingPasteboard),
                  let (_, target) = dropTarget(tableView, info: info) else { return false }
            let option = NSEvent.modifierFlags.contains(.option)
            guard onValidateGitDrop(payload, target, option) else { onEndGitDrag(); return false }
            onGitDrop(payload, target, option)
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onEndGitDrag()
        }

        func commitOid(atRow row: Int) -> String? {
            commit(atRow: row)?.oidHex
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            if tableView.clickedRow == 0 {
                menu.populate(with: workingChangesMenu())
                return
            }
            guard let commit = commit(atRow: tableView.clickedRow) else { return }
            let selected = tableView.selectedRowIndexes
            if selected.count > 1, selected.contains(tableView.clickedRow) {
                menu.populate(with: multiSelectionEntries(selected.compactMap { commitOid(atRow: $0) }))
                return
            }
            let oid = commit.oidHex
            let branch = currentBranch
            // Detached HEAD has no branch to merge into, rebase or reset.
            let isDetached = RepoTab.isDetachedHead(branch: branch)

            var entries: [MenuEntry] = []

            // Acting on the checked-out branch.
            if !isDetached {
                // Off while another action runs, so two history changes can't overlap.
                entries.append(.item("Merge into '\(branch)'…", enabled: !isBusy) { [weak self] in self?.onCommitAction(.merge, oid) })
                entries.append(.item("Rebase '\(branch)' to Here…", enabled: !isBusy) { [weak self] in self?.onCommitAction(.rebase, oid) })
                entries.append(.submenu("Reset '\(branch)' to Here…", [
                    .item("Soft — keep changes staged", enabled: !isBusy) { [weak self] in self?.onCommitAction(.reset(.soft), oid) },
                    .item("Mixed — keep changes unstaged", enabled: !isBusy) { [weak self] in self?.onCommitAction(.reset(.mixed), oid) },
                    .item("Hard — discard uncommitted changes…", enabled: !isBusy) { [weak self] in self?.onCommitAction(.reset(.hard), oid) },
                ]))
                entries.append(.separator)
            }

            // Working with the commit itself.
            entries.append(.item("Cherry Pick Commit", enabled: !isBusy) { [weak self] in self?.onCommitAction(.cherryPick, oid) })
            entries.append(.item("Revert Commit", enabled: !isBusy) { [weak self] in self?.onCommitAction(.revert, oid) })
            entries.append(.separator)

            // Creating references or checkouts that point at the commit.
            entries.append(.item("New Branch…") { [weak self] in self?.onCreateBranchAtCommit(oid) })
            entries.append(.item("New Tag…") { [weak self] in self?.onCreateTagAtCommit(oid) })
            entries.append(.item("New Worktree from Commit…", enabled: !isBusy) { [weak self] in
                self?.onCreateWorktreeAtCommit(oid)
            })
            entries.append(.item("Checkout Commit…") { [weak self] in self?.onCheckoutCommit(oid) })

            // Conditionally offer worktree removal when a linked worktree sits at this commit.
            let linkedHere = worktrees.filter { !$0.isMain && $0.headOidHex == oid }
            if linkedHere.count == 1, let worktree = linkedHere.first {
                let folder = worktree.path.folderName
                entries.append(.item("Remove Worktree '\(folder)'…", enabled: !isBusy && canRemoveWorktree(worktree)) { [weak self] in
                    self?.onRemoveWorktree(worktree)
                })
            } else if linkedHere.count > 1 {
                entries.append(.submenu("Remove Worktree…", linkedHere.map { worktree in
                    let folder = worktree.path.folderName
                    return .item("'\(folder)'…", enabled: !isBusy && canRemoveWorktree(worktree)) { [weak self] in
                        self?.onRemoveWorktree(worktree)
                    }
                }))
            }
            entries.append(.separator)

            entries.append(.item("Copy Commit SHA (\(commit.shortOid))") { [weak self] in self?.onCopyOid(oid) })

            menu.populate(with: entries)
        }

        /// The menu for a right-click inside a multi-selection: only what acts on all of it.
        private func multiSelectionEntries(_ oids: [String]) -> [MenuEntry] {
            var preview: SquashPreview?
            if case let .allowed(allowed) = squashCheck { preview = allowed }
            let title = RepoTab.squashMenuTitle(check: squashCheck)
            return [
                .item(title, enabled: !isBusy && preview != nil) { [weak self] in
                    if let preview { self?.onSquash(preview) }
                },
                .separator,
                .item("Copy \(oids.count) Commit SHAs") { [weak self] in self?.onCopyOids(oids) },
            ]
        }

        deinit {
            windowFetchTask?.cancel()
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
        }

        /// Lets other views hand keyboard focus back to the commit list (see `.focusCommitTable`).
        /// Only the key window's table responds: other repository windows and background tabs
        /// keep whatever they had focused.
        func observeFocusRequests() {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .focusCommitTable,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let table = self?.tableView, let window = table.window,
                      window.isKeyWindow, !table.isHiddenOrHasHiddenAncestor
                else { return }
                window.makeFirstResponder(table)
            }
        }

        func observeScroll(_ clipView: NSClipView) {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.checkScrollNearBottom()
            }
        }

        private func checkScrollNearBottom() {
            guard let tableView else { return }
            let effectiveCount = max(rows.count, totalCommitCount)
            // In virtualized mode (totalCommitCount > rows.count), rows are fetched on demand
            // by `scheduleWindowFetch` as they enter the viewport. Only trigger `onLoadMore`
            // when paginating search results or when scrolled past the indexed prefix.
            guard isSearchActive || rows.count >= totalCommitCount else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.location + visible.length >= max(0, effectiveCount - 40) {
                onLoadMore()
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            // Row 0 is pinned as synthetic "Working Changes".
            1 + max(rows.count, totalCommitCount)
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? CommitRowCellView)
                ?? CommitRowCellView(identifier: Self.cellIdentifier)

            if row == 0 {
                cell.configureWorkingChanges(fileCount: workingChangesCount)
                return cell
            }
            loadCachedRows(around: row - 1)
            if let commit = commit(atRow: row) {
                configure(cell, with: commit, atRow: row)
            } else {
                cell.configurePlaceholder()
                scheduleWindowFetch(around: row - 1)
            }
            return cell
        }

        private func configure(_ cell: CommitRowCellView, with commit: CommitRow, atRow row: Int) {
            cell.configure(
                commit: commit,
                hasIncomingLine: hasIncomingLane(at: row - 1),
                otherWorktreeBranches: worktreeBranches,
                remoteHosts: remoteHosts,
                showTags: showTags
            )
        }

        /// Fills the cache around commit `index` from the index, before the row is drawn, so
        /// scrolling shows commits rather than blank rows. The row above comes along because
        /// the incoming lane line depends on it.
        private func loadCachedRows(around index: Int) {
            guard !isSearchActive, index >= rows.count else { return }
            let previousIsMissing = index > rows.count && windowCache[index - 1] == nil
            guard windowCache[index] == nil || previousIsMissing else { return }
            let chunk = Self.cachedChunkSize
            let start = max(0, index / chunk * chunk - 1)
            guard let fetched = onCachedWindow(start, chunk + 1) else { return }
            insertIntoWindowCache(offset: start, fetched: fetched, anchor: index)
        }

        /// The background fallback for rows the index can't serve right away. One fetch runs at
        /// a time and is never cancelled by further scrolling; whatever is still blank when it
        /// lands is fetched next.
        private func scheduleWindowFetch(around index: Int) {
            let effectiveCount = max(rows.count, totalCommitCount)
            guard windowFetchTask == nil, index >= 0, index < effectiveCount else { return }

            // Starting before `index` also fetches the previous row for `hasIncomingLane`.
            let fetchStart = max(0, index - Self.windowPadding)
            let fetchEnd = min(effectiveCount, index + Self.windowPadding)
            let generation = lastGraphGeneration
            let fetch = onFetchWindow

            windowFetchTask = Task { @MainActor [weak self] in
                let fetched = try? await fetch(fetchStart, fetchEnd - fetchStart)
                // A cancelled fetch belongs to a replaced list, which may have its own running.
                guard !Task.isCancelled, let self else { return }
                self.windowFetchTask = nil
                guard self.lastGraphGeneration == generation, let fetched, !fetched.isEmpty else { return }
                self.insertIntoWindowCache(offset: fetchStart, fetched: fetched, anchor: index)
                self.fillPlaceholders()
            }
        }

        /// Reconfigures placeholder cells in place, including those prepared just off screen
        /// (`reloadData(forRowIndexes:)` would tear down and flash them).
        private func fillPlaceholders() {
            guard let tableView else { return }
            var stillMissing: [Int] = []
            tableView.enumerateAvailableRowViews { rowView, row in
                guard row > 0, rowView.numberOfColumns > 0,
                      let cell = rowView.view(atColumn: 0) as? CommitRowCellView,
                      cell.isPlaceholder
                else { return }
                if let commit = self.commit(atRow: row) {
                    self.configure(cell, with: commit, atRow: row)
                } else {
                    stillMissing.append(row)
                }
            }
            let visible = tableView.rows(in: tableView.visibleRect)
            if let row = stillMissing.first(where: { NSLocationInRange($0, visible) }) {
                scheduleWindowFetch(around: row - 1)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isRestoringSelection, let table = notification.object as? NSTableView else { return }
            onSelectCommits(table.selectedRowIndexes.compactMap { commit(atRow: $0) })
        }

        func tableView(_: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            Self.allowedSelection(proposed)
        }

        /// Selects the rows now showing the `selected` commits (`oids` lists the commits in row
        /// order, after Working Changes). With none left the selection is cleared: a reload
        /// keeps row numbers, which would highlight other commits.
        static func restoreSelection(in table: NSTableView, oids: [String], selected: Set<String>, workingChanges: Bool) {
            var restored = workingChanges ? IndexSet(integer: 0) : IndexSet()
            for (index, oid) in oids.enumerated() where selected.contains(oid) {
                restored.insert(index + 1)
            }
            table.selectRowIndexes(restored, byExtendingSelection: false)
        }

        /// Working Changes (row 0) can only be selected on its own.
        static func allowedSelection(_ proposed: IndexSet) -> IndexSet {
            guard proposed.count > 1 else { return proposed }
            var commits = proposed
            commits.remove(0)
            return commits
        }

        private func hasIncomingLane(at commitIndex: Int) -> Bool {
            guard commitIndex > 0 else { return false }
            guard let current = commit(atRow: commitIndex + 1),
                  let prev = commit(atRow: commitIndex)
            else { return false }
            return prev.edges.contains { $0.toLane == current.lane }
        }
    }
}

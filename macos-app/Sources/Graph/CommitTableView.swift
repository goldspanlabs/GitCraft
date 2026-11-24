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

struct CommitTableView: NSViewRepresentable {
    let rows: [CommitRow]
    let graphRevision: UUID
    let workingChangesCount: Int
    /// Hosting service per remote name, for the icon on remote-branch chips.
    let remoteHosts: [String: RemoteHost]
    let scrollRequest: RepoTab.ScrollRequest?
    let onLoadMore: () -> Void
    let onSelectCommit: (CommitRow?) -> Void
    let onCopyOid: (String) -> Void
    let onCreateBranchAtCommit: (String) -> Void
    let onCreateTagAtCommit: (String) -> Void
    let onCheckoutCommit: (String) -> Void
    /// The checked-out branch's name; empty when HEAD is detached.
    let currentBranch: String
    let onCommitAction: (CommitAction, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            workingChangesCount: workingChangesCount,
            onLoadMore: onLoadMore,
            onSelectCommit: onSelectCommit,
            onCopyOid: onCopyOid,
            onCreateBranchAtCommit: onCreateBranchAtCommit,
            onCreateTagAtCommit: onCreateTagAtCommit,
            onCheckoutCommit: onCheckoutCommit
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let table = NSTableView()
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .textBackgroundColor
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        scrollView.documentView = table
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.tableView = table
        context.coordinator.observeScroll(scrollView.contentView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let dataChanged = coordinator.lastGraphRevision != graphRevision
            || coordinator.workingChangesCount != workingChangesCount
            || coordinator.remoteHosts != remoteHosts

        // Remember what is selected (by commit, not row index) before the data is swapped.
        let selectedRowBefore = table.selectedRow
        let selectedOidBefore: String? = (selectedRowBefore > 0 && selectedRowBefore - 1 < coordinator.rows.count)
            ? coordinator.rows[selectedRowBefore - 1].oidHex
            : nil

        coordinator.lastGraphRevision = graphRevision
        coordinator.rows = rows
        coordinator.workingChangesCount = workingChangesCount
        coordinator.remoteHosts = remoteHosts
        coordinator.onLoadMore = onLoadMore
        coordinator.onSelectCommit = onSelectCommit
        coordinator.onCopyOid = onCopyOid
        coordinator.onCreateBranchAtCommit = onCreateBranchAtCommit
        coordinator.onCreateTagAtCommit = onCreateTagAtCommit
        coordinator.onCheckoutCommit = onCheckoutCommit
        coordinator.currentBranch = currentBranch
        coordinator.onCommitAction = onCommitAction

        if dataChanged {
            // Reload/restore is not a user selection: keep it from reaching the model, where
            // it would cancel a pending branch reveal or deselect the current commit.
            coordinator.isRestoringSelection = true
            table.reloadData()
            let restoreRow: Int? = if selectedRowBefore == 0 {
                0
            } else if let oid = selectedOidBefore {
                rows.firstIndex(where: { $0.oidHex == oid }).map { $0 + 1 }
            } else {
                nil
            }
            if let restoreRow, restoreRow < coordinator.numberOfRows(in: table) {
                table.selectRowIndexes(IndexSet(integer: restoreRow), byExtendingSelection: false)
            }
            coordinator.isRestoringSelection = false
        }

        if let request = scrollRequest, coordinator.lastHandledScrollID != request.id {
            coordinator.lastHandledScrollID = request.id
            let requestedOid = request.oidHex
            // Defer: selecting fires the delegate, which publishes state, and that
            // must not happen during a SwiftUI view update (the change can be dropped).
            // Resolve the row inside the block so a graph refresh in between can't
            // leave us with a stale index.
            DispatchQueue.main.async { [weak table, weak coordinator] in
                guard let table, let coordinator else { return }
                let targetRow: Int
                if let oid = requestedOid {
                    guard let idx = coordinator.rows.firstIndex(where: { $0.oidHex == oid }) else { return }
                    targetRow = idx + 1
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
        var workingChangesCount: Int
        var remoteHosts: [String: RemoteHost] = [:]
        var lastGraphRevision: UUID?
        var onLoadMore: () -> Void
        var onSelectCommit: (CommitRow?) -> Void
        var onCopyOid: (String) -> Void
        var onCreateBranchAtCommit: (String) -> Void
        var onCreateTagAtCommit: (String) -> Void
        var onCheckoutCommit: (String) -> Void
        var currentBranch = ""
        var onCommitAction: (CommitAction, String) -> Void = { _, _ in }
        var lastHandledScrollID: UUID?
        var isRestoringSelection = false
        weak var tableView: NSTableView?
        private var boundsObserver: NSObjectProtocol?

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("CommitRowCell")

        init(
            rows: [CommitRow],
            workingChangesCount: Int,
            onLoadMore: @escaping () -> Void,
            onSelectCommit: @escaping (CommitRow?) -> Void,
            onCopyOid: @escaping (String) -> Void,
            onCreateBranchAtCommit: @escaping (String) -> Void,
            onCreateTagAtCommit: @escaping (String) -> Void,
            onCheckoutCommit: @escaping (String) -> Void
        ) {
            self.rows = rows
            self.workingChangesCount = workingChangesCount
            self.onLoadMore = onLoadMore
            self.onSelectCommit = onSelectCommit
            self.onCopyOid = onCopyOid
            self.onCreateBranchAtCommit = onCreateBranchAtCommit
            self.onCreateTagAtCommit = onCreateTagAtCommit
            self.onCheckoutCommit = onCheckoutCommit
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let clickedRow = tableView.clickedRow
            guard clickedRow > 0, (clickedRow - 1) < rows.count else { return }
            let commit = rows[clickedRow - 1]
            let oid = commit.oidHex
            let branch = currentBranch
            // Detached HEAD has no branch to merge into, rebase or reset.
            let isDetached = branch.isEmpty || branch == "HEAD" || branch.hasPrefix("(")

            var entries: [MenuEntry] = []

            // Acting on the checked-out branch.
            if !isDetached {
                entries.append(.item("Merge into '\(branch)'") { [weak self] in self?.onCommitAction(.merge, oid) })
                entries.append(.item("Rebase '\(branch)' to Here…") { [weak self] in self?.onCommitAction(.rebase, oid) })
                entries.append(.submenu("Reset '\(branch)' to Here…", [
                    .item("Soft — keep changes staged") { [weak self] in self?.onCommitAction(.reset(.soft), oid) },
                    .item("Mixed — keep changes unstaged") { [weak self] in self?.onCommitAction(.reset(.mixed), oid) },
                    .item("Hard — discard uncommitted changes…") { [weak self] in self?.onCommitAction(.reset(.hard), oid) },
                ]))
                entries.append(.separator)
            }

            // Working with the commit itself.
            entries.append(.item("Cherry Pick Commit") { [weak self] in self?.onCommitAction(.cherryPick, oid) })
            entries.append(.item("Revert Commit") { [weak self] in self?.onCommitAction(.revert, oid) })
            entries.append(.separator)

            // Creating references that point at the commit.
            entries.append(.item("New Branch…") { [weak self] in self?.onCreateBranchAtCommit(oid) })
            entries.append(.item("New Tag…") { [weak self] in self?.onCreateTagAtCommit(oid) })
            entries.append(.item("Checkout Commit…") { [weak self] in self?.onCheckoutCommit(oid) })
            entries.append(.separator)

            entries.append(.item("Copy Commit SHA (\(commit.shortOid))") { [weak self] in self?.onCopyOid(oid) })

            menu.populate(with: entries)
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
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
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.location + visible.length >= max(0, rows.count - 40) {
                onLoadMore()
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            // Row 0 is pinned as synthetic "Working Changes".
            1 + rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? CommitRowCellView)
                ?? CommitRowCellView(identifier: Self.cellIdentifier)

            if row == 0 {
                cell.configureWorkingChanges(fileCount: workingChangesCount)
            } else {
                let commitIndex = row - 1
                let commit = rows[commitIndex]
                let hasIncomingLine = hasIncomingLane(at: commitIndex)
                // The dashed Working Changes line leads into the HEAD commit when it's the first row.
                let connectsToWorkingChanges = commitIndex == 0
                    && commit.lane == 0
                    && commit.refs.contains(where: { $0.isCurrent })
                cell.configure(
                    commit: commit,
                    hasIncomingLine: hasIncomingLine,
                    connectsToWorkingChanges: connectsToWorkingChanges,
                    remoteHosts: remoteHosts
                )
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isRestoringSelection, let table = notification.object as? NSTableView else { return }
            let selected = table.selectedRow
            if selected <= 0 {
                onSelectCommit(nil)
            } else {
                let idx = selected - 1
                if idx < rows.count {
                    onSelectCommit(rows[idx])
                }
            }
        }

        private func hasIncomingLane(at commitIndex: Int) -> Bool {
            guard commitIndex > 0 else { return false }
            let currentLane = rows[commitIndex].lane
            let prev = rows[commitIndex - 1]
            return prev.edges.contains { $0.toLane == currentLane }
        }
    }
}

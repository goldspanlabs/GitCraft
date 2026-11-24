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

            // Acting on the checked-out branch.
            if !isDetached {
                addItem(to: menu, "Merge into '\(branch)'", #selector(handleMerge(_:)), oid)
                addItem(to: menu, "Rebase '\(branch)' to Here…", #selector(handleRebase(_:)), oid)

                let resetItem = NSMenuItem(title: "Reset '\(branch)' to Here…", action: nil, keyEquivalent: "")
                let resetMenu = NSMenu()
                let modes: [(String, Int)] = [
                    ("Soft — keep changes staged", 0),
                    ("Mixed — keep changes unstaged", 1),
                    ("Hard — discard uncommitted changes…", 2),
                ]
                for (title, tag) in modes {
                    let item = NSMenuItem(title: title, action: #selector(handleReset(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = oid
                    item.tag = tag
                    resetMenu.addItem(item)
                }
                resetItem.submenu = resetMenu
                menu.addItem(resetItem)

                menu.addItem(.separator())
            }

            // Working with the commit itself.
            addItem(to: menu, "Cherry Pick Commit", #selector(handleCherryPick(_:)), oid)
            addItem(to: menu, "Revert Commit", #selector(handleRevert(_:)), oid)

            menu.addItem(.separator())

            // Creating references that point at the commit.
            addItem(to: menu, "New Branch…", #selector(handleCreateBranch(_:)), oid)
            addItem(to: menu, "New Tag…", #selector(handleCreateTag(_:)), oid)
            addItem(to: menu, "Checkout Commit…", #selector(handleCheckoutCommit(_:)), oid)

            menu.addItem(.separator())

            addItem(to: menu, "Copy Commit SHA (\(commit.shortOid))", #selector(handleCopyOid(_:)), oid)
        }

        @discardableResult
        private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, _ oid: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = oid
            menu.addItem(item)
            return item
        }

        @objc private func handleMerge(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String { onCommitAction(.merge, oid) }
        }

        @objc private func handleRebase(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String { onCommitAction(.rebase, oid) }
        }

        @objc private func handleReset(_ sender: NSMenuItem) {
            guard let oid = sender.representedObject as? String else { return }
            let modes: [ResetMode] = [.soft, .mixed, .hard]
            guard modes.indices.contains(sender.tag) else { return }
            onCommitAction(.reset(modes[sender.tag]), oid)
        }

        @objc private func handleCherryPick(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String { onCommitAction(.cherryPick, oid) }
        }

        @objc private func handleRevert(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String { onCommitAction(.revert, oid) }
        }

        @objc private func handleCopyOid(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String {
                onCopyOid(oid)
            }
        }

        @objc private func handleCreateBranch(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String {
                onCreateBranchAtCommit(oid)
            }
        }

        @objc private func handleCreateTag(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String {
                onCreateTagAtCommit(oid)
            }
        }

        @objc private func handleCheckoutCommit(_ sender: NSMenuItem) {
            if let oid = sender.representedObject as? String {
                onCheckoutCommit(oid)
            }
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

final class CommitRowCellView: NSTableCellView {
    private let graphView = GraphCellView()
    private let badgesStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let avatarView = AvatarImageView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let hashLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var graphWidthConstraint: NSLayoutConstraint!

    /// "Yesterday at 10:57 PM" for recent days, "Nov 22, 2026 at 6:38 PM" otherwise.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        graphView.translatesAutoresizingMaskIntoConstraints = false
        badgesStack.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        hashLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgesStack.orientation = .horizontal
        badgesStack.spacing = 4
        badgesStack.alignment = .centerY
        badgesStack.setHuggingPriority(.required, for: .horizontal)

        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .systemFont(ofSize: 12.5)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.font = .systemFont(ofSize: 11.5)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .left

        hashLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        hashLabel.textColor = .secondaryLabelColor
        hashLabel.alignment = .left

        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 11.5)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .left

        addSubview(graphView)
        addSubview(badgesStack)
        addSubview(summaryLabel)
        addSubview(avatarView)
        addSubview(authorLabel)
        addSubview(hashLabel)
        addSubview(timeLabel)

        graphWidthConstraint = graphView.widthAnchor.constraint(equalToConstant: 24)

        NSLayoutConstraint.activate([
            graphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            graphView.topAnchor.constraint(equalTo: topAnchor),
            graphView.bottomAnchor.constraint(equalTo: bottomAnchor),
            graphWidthConstraint,

            badgesStack.leadingAnchor.constraint(equalTo: graphView.trailingAnchor, constant: 6),
            badgesStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: badgesStack.trailingAnchor, constant: 6),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: avatarView.leadingAnchor, constant: -10),

            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 18),
            avatarView.heightAnchor.constraint(equalToConstant: 18),
            avatarView.trailingAnchor.constraint(equalTo: authorLabel.leadingAnchor, constant: -6),

            authorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            authorLabel.widthAnchor.constraint(equalToConstant: 130),
            authorLabel.trailingAnchor.constraint(equalTo: hashLabel.leadingAnchor, constant: -12),

            hashLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hashLabel.widthAnchor.constraint(equalToConstant: 64),
            hashLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),

            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 158),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    func configureWorkingChanges(fileCount: Int) {
        graphWidthConstraint.constant = 24
        graphView.alphaValue = 1.0
        graphView.configureWorkingChanges()
        badgesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        badgesStack.isHidden = true

        if fileCount > 0 {
            summaryLabel.stringValue = "Working Changes (\(fileCount) modified)"
            summaryLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
            summaryLabel.textColor = .labelColor
        } else {
            summaryLabel.stringValue = "Working Changes (Clean)"
            summaryLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
            summaryLabel.textColor = .secondaryLabelColor
        }
        authorLabel.stringValue = ""
        hashLabel.stringValue = ""
        timeLabel.stringValue = ""
        avatarView.isHidden = true
        avatarView.clear()
    }

    func configure(
        commit: CommitRow,
        hasIncomingLine: Bool,
        connectsToWorkingChanges: Bool = false,
        remoteHosts: [String: RemoteHost] = [:]
    ) {
        let lanes = max(1, Int(commit.maxLanes))
        graphWidthConstraint.constant = GraphCellView.width(forLanes: lanes)
        // Remote-only rows dim their text, not the graph lines.
        graphView.alphaValue = 1.0
        graphView.configure(
            commit: commit,
            hasIncomingLine: hasIncomingLine,
            connectsToWorkingChanges: connectsToWorkingChanges
        )

        badgesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if commit.refs.isEmpty {
            badgesStack.isHidden = true
        } else {
            badgesStack.isHidden = false
            let badges = Array(commit.refs.prefix(4))
            // "origin/main" -> the host behind the "origin" remote.
            let hostFor: (RefBadge) -> RemoteHost? = { badge in
                badge.kind == .remoteBranch
                    ? badge.name.split(separator: "/", maxSplits: 1).first.flatMap { remoteHosts[String($0)] } ?? .other
                    : nil
            }
            // "origin/main" -> "main".
            let branchNameOf: (RefBadge) -> String = { badge in
                String(badge.name.split(separator: "/", maxSplits: 1).last ?? "")
            }
            // Hosted remote branches on the same commit as their local branch of the same name.
            // Each is drawn as its host icon chip followed by the local chip; the origin name chip is dropped.
            let mirrored = badges.filter { $0.kind == .remoteBranch && hostFor($0)?.icon != nil }.compactMap { remote -> RefBadge? in
                commit.refs.first { $0.kind == .localBranch && $0.name == branchNameOf(remote) }
            }
            let mirroredLocalNames = Set(mirrored.map(\.name))
            for badge in badges {
                if badge.kind == .localBranch, mirroredLocalNames.contains(badge.name) {
                    continue // drawn right after its remote's icon chip
                }
                if badge.kind == .remoteBranch, let local = mirrored.first(where: { $0.name == branchNameOf(badge) }) {
                    badgesStack.addArrangedSubview(
                        RefPillView(badge: badge, host: hostFor(badge), iconOnly: true, colorFrom: local)
                    )
                    badgesStack.addArrangedSubview(RefPillView(badge: local, showsUnpushedDot: commit.isUnpushed))
                } else {
                    badgesStack.addArrangedSubview(
                        RefPillView(badge: badge, host: hostFor(badge), showsUnpushedDot: commit.isUnpushed)
                    )
                }
            }
        }

        // The latest commit of the checked-out branch is bold.
        let isHeadCommit = commit.refs.contains { $0.isCurrent }
        summaryLabel.stringValue = commit.summary
        summaryLabel.font = .systemFont(ofSize: 12.5, weight: isHeadCommit ? .bold : .regular)
        summaryLabel.textColor = commit.isRemoteOnly ? .secondaryLabelColor : .labelColor

        avatarView.isHidden = false
        avatarView.configure(name: commit.authorName, email: commit.authorEmail)
        authorLabel.stringValue = commit.authorName
        let secondary: NSColor = commit.isRemoteOnly ? .tertiaryLabelColor : .secondaryLabelColor
        // The head commit's other columns match its summary: bold, in the primary text colour.
        let columnColor: NSColor = isHeadCommit ? .labelColor : secondary
        authorLabel.textColor = columnColor
        hashLabel.stringValue = commit.shortOid
        hashLabel.textColor = columnColor
        timeLabel.textColor = columnColor
        let columnWeight: NSFont.Weight = isHeadCommit ? .bold : .regular
        authorLabel.font = .systemFont(ofSize: 11.5, weight: columnWeight)
        hashLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: columnWeight)
        timeLabel.font = .systemFont(ofSize: 11.5, weight: columnWeight)
        let date = Date(timeIntervalSince1970: TimeInterval(commit.timestamp))
        timeLabel.stringValue = Self.dateFormatter.string(from: date)
    }
}

final class RefPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let divider = NSView()
    /// The untinted glyph; `applyColors` bakes the chip colour into `iconView.image`.
    private var templateIcon: NSImage?
    private let badge: RefBadge
    /// The chip whose colours this chip uses. It is the chip itself unless `colorFrom` is set.
    private let colorBadge: RefBadge
    private let host: RemoteHost?

    /// `showsUnpushedDot` swaps the checked-out branch's check mark for an orange dot.
    /// `iconOnly` draws just the host mark, for a remote branch whose name is shown in a chip beside it.
    init(
        badge: RefBadge,
        host: RemoteHost? = nil,
        showsUnpushedDot: Bool = false,
        iconOnly: Bool = false,
        colorFrom: RefBadge? = nil
    ) {
        self.badge = badge
        self.colorBadge = colorFrom ?? badge
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.stringValue = badge.name
        label.font = .systemFont(ofSize: 11.5, weight: badge.isCurrent ? .bold : .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        if !iconOnly { addSubview(label) }
        if let host, let icon = host.icon {
            // Remote chips lead with the hosting service's mark, set off by a thin divider.
            templateIcon = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            var constraints: [NSLayoutConstraint] = [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14),
            ]
            if iconOnly {
                // Icon-only chip: the name sits in its own chip beside it.
                constraints.append(iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
            } else {
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.wantsLayer = true
                addSubview(divider)
                constraints += [
                    divider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                    divider.widthAnchor.constraint(equalToConstant: 1),
                    divider.topAnchor.constraint(equalTo: topAnchor),
                    divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                    label.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 6),
                ]
            }
            NSLayoutConstraint.activate(constraints)
        } else if badge.isCurrent, badge.kind == .localBranch || badge.kind == .head, showsUnpushedDot {
            // Unpushed commits: the orange dot takes the check mark's place, same 13pt slot.
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23),
            ])
        } else if badge.isCurrent, badge.kind == .localBranch || badge.kind == .head {
            // The checked-out branch gets a check mark in front of its name.
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            templateIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current branch")?
                .withSymbolConfiguration(config)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 13),
                iconView.heightAnchor.constraint(equalToConstant: 13),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true
        }
        if !iconOnly {
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
        }

        applyColors()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static func tinted(_ template: NSImage, with color: NSColor) -> NSImage {
        let size = template.size
        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let baseColor: NSColor = switch colorBadge.kind {
        case .localBranch: .systemBlue
        case .remoteBranch: .systemPurple
        case .tag: .systemOrange
        case .head: .systemGreen
        }

        // Opaque pastel fill (like Fork) so the chip stays legible even when the row is
        // highlighted with the strong blue selection color.
        let bgColor: NSColor
        let fgColor: NSColor
        let borderColor: NSColor

        if isDark {
            let darkBase = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
            bgColor = darkBase.blended(withFraction: colorBadge.isCurrent ? 0.35 : 0.25, of: baseColor) ?? darkBase
            // The current branch's chip text is noticeably brighter than other chips'.
            fgColor = baseColor.blended(withFraction: colorBadge.isCurrent ? 0.8 : 0.45, of: .white) ?? baseColor
            borderColor = baseColor.blended(withFraction: 0.25, of: .white) ?? baseColor
        } else {
            bgColor = NSColor.white.blended(withFraction: colorBadge.isCurrent ? 0.22 : 0.14, of: baseColor) ?? .white
            fgColor = baseColor.blended(withFraction: 0.45, of: .black) ?? baseColor
            borderColor = baseColor.withAlphaComponent(colorBadge.isCurrent ? 0.85 : 0.55)
        }

        layer?.backgroundColor = bgColor.cgColor
        layer?.borderColor = borderColor.cgColor
        label.textColor = fgColor
        // Pre-tint instead of relying on a template image: a selected row would otherwise
        // recolour template icons, washing them out against the selection highlight.
        iconView.image = templateIcon.map { Self.tinted($0, with: fgColor) }
        divider.layer?.backgroundColor = borderColor.withAlphaComponent(0.6).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class GraphCellView: NSView {
    private static let laneWidth: CGFloat = 14
    private static let leftPadding: CGFloat = 4
    private static let nodeRadius: CGFloat = 4.0
    private static let lineWidth: CGFloat = 1.8

    private static let palette: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemYellow,
        .systemIndigo,
    ]

    private var commit: CommitRow?
    private var hasIncomingLine = false
    private var isWorkingChanges = false
    private var connectsToWorkingChanges = false

    override var isFlipped: Bool { true }

    static func width(forLanes lanes: Int) -> CGFloat {
        leftPadding * 2 + CGFloat(max(1, lanes)) * laneWidth
    }

    /// Horizontal centre of a lane, measured from the graph view's leading edge.
    static func centerX(forLane lane: Int) -> CGFloat {
        leftPadding + CGFloat(lane) * laneWidth + laneWidth / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configureWorkingChanges() {
        isWorkingChanges = true
        connectsToWorkingChanges = false
        commit = nil
        hasIncomingLine = false
        needsDisplay = true
    }

    func configure(commit: CommitRow, hasIncomingLine: Bool, connectsToWorkingChanges: Bool = false) {
        isWorkingChanges = false
        self.connectsToWorkingChanges = connectsToWorkingChanges
        self.commit = commit
        self.hasIncomingLine = hasIncomingLine
        needsDisplay = true
    }

    private func xForLane(_ lane: UInt32) -> CGFloat {
        Self.leftPadding + CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func color(for idx: UInt8) -> NSColor {
        Self.palette[Int(idx) % Self.palette.count]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineCap(.round)

        let midY = bounds.height / 2

        if isWorkingChanges {
            let x = xForLane(0)
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
            ctx.move(to: CGPoint(x: x, y: midY + Self.nodeRadius))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [])
            let ringRect = CGRect(
                x: x - Self.nodeRadius,
                y: midY - Self.nodeRadius,
                width: Self.nodeRadius * 2,
                height: Self.nodeRadius * 2
            )
            ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
            ctx.fillEllipse(in: ringRect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.strokeEllipse(in: ringRect)
            return
        }

        guard let commit else { return }

        // Continue the dashed Working Changes line down into this (HEAD) commit.
        if connectsToWorkingChanges {
            let x = xForLane(commit.lane)
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: midY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Draw edges first so the commit node renders cleanly on top.
        for edge in commit.edges {
            let edgeColor = color(for: edge.colorIdx).cgColor
            ctx.setStrokeColor(edgeColor)

            let fromX = xForLane(edge.fromLane)
            let toX = xForLane(edge.toLane)

            if edge.fromLane == edge.toLane {
                if edge.fromLane == commit.lane {
                    let startY: CGFloat = hasIncomingLine ? 0 : midY
                    ctx.move(to: CGPoint(x: fromX, y: startY))
                    ctx.addLine(to: CGPoint(x: fromX, y: bounds.height))
                } else {
                    ctx.move(to: CGPoint(x: fromX, y: 0))
                    ctx.addLine(to: CGPoint(x: fromX, y: bounds.height))
                }
                ctx.strokePath()
            } else if edge.toLane == commit.lane {
                // Converging incoming branch from top -> commit node.
                ctx.move(to: CGPoint(x: fromX, y: 0))
                ctx.addCurve(
                    to: CGPoint(x: toX, y: midY),
                    control1: CGPoint(x: fromX, y: midY * 0.65),
                    control2: CGPoint(x: toX, y: midY * 0.35)
                )
                ctx.strokePath()
            } else {
                // Outgoing branch/merge from commit node -> bottom.
                let dy = bounds.height - midY
                ctx.move(to: CGPoint(x: fromX, y: midY))
                ctx.addCurve(
                    to: CGPoint(x: toX, y: bounds.height),
                    control1: CGPoint(x: fromX, y: midY + dy * 0.65),
                    control2: CGPoint(x: toX, y: midY + dy * 0.35)
                )
                ctx.strokePath()
            }
        }

        // Draw incoming vertical segment if this commit has no outgoing parent edge (root commit)
        // but did have an incoming line from above.
        if hasIncomingLine && !commit.edges.contains(where: { $0.fromLane == commit.lane && $0.toLane == commit.lane }) {
            let x = xForLane(commit.lane)
            ctx.setStrokeColor(color(for: commit.colorIdx).cgColor)
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: midY))
            ctx.strokePath()
        }

        // Draw commit circle with a 1.5pt background-colored stroke ring.
        let nodeX = xForLane(commit.lane)
        let ringRect = CGRect(
            x: nodeX - Self.nodeRadius - 1.5,
            y: midY - Self.nodeRadius - 1.5,
            width: (Self.nodeRadius + 1.5) * 2,
            height: (Self.nodeRadius + 1.5) * 2
        )
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.fillEllipse(in: ringRect)

        let dotRect = CGRect(
            x: nodeX - Self.nodeRadius,
            y: midY - Self.nodeRadius,
            width: Self.nodeRadius * 2,
            height: Self.nodeRadius * 2
        )
        ctx.setFillColor(color(for: commit.colorIdx).cgColor)
        ctx.fillEllipse(in: dotRect)
    }
}

/// Small rounded-square author avatar for AppKit cells: the fetched image when there is
/// one, otherwise the author's initials on a grey tile. Shares `AvatarLoader`'s cache.
final class AvatarImageView: NSView {
    private let imageView = NSImageView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private var email = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        initialsLabel.textColor = .secondaryLabelColor
        initialsLabel.alignment = .center
        addSubview(imageView)
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func clear() {
        email = ""
        imageView.image = nil
        imageView.isHidden = true
        initialsLabel.stringValue = ""
    }

    func configure(name: String, email: String) {
        self.email = email
        let initials = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        initialsLabel.stringValue = initials.isEmpty ? "?" : initials
        imageView.image = nil
        imageView.isHidden = true
        initialsLabel.isHidden = false
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor

        let showAvatars = UserDefaults.standard.object(forKey: showAvatarsStorageKey) as? Bool ?? true
        guard showAvatars, !email.isEmpty else { return }
        let requested = email
        Task { @MainActor [weak self] in
            let image = await AvatarLoader.shared.image(for: requested)
            // The cell may have been reused for another commit while the image loaded.
            guard let self, self.email == requested, let image else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.initialsLabel.isHidden = true
        }
    }
}

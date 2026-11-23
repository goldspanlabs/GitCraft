import AppKit
import SwiftUI

struct CommitTableView: NSViewRepresentable {
    let rows: [CommitRow]
    let graphRevision: UUID
    let workingChangesCount: Int
    let scrollRequest: RepoTab.ScrollRequest?
    let onLoadMore: () -> Void
    let onSelectCommit: (CommitRow?) -> Void
    let onCopyOid: (String) -> Void
    let onCreateBranchAtCommit: (String) -> Void
    let onCreateTagAtCommit: (String) -> Void
    let onCheckoutCommit: (String) -> Void

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

        // Remember what is selected (by commit, not row index) before the data is swapped.
        let selectedRowBefore = table.selectedRow
        let selectedOidBefore: String? = (selectedRowBefore > 0 && selectedRowBefore - 1 < coordinator.rows.count)
            ? coordinator.rows[selectedRowBefore - 1].oidHex
            : nil

        coordinator.lastGraphRevision = graphRevision
        coordinator.rows = rows
        coordinator.workingChangesCount = workingChangesCount
        coordinator.onLoadMore = onLoadMore
        coordinator.onSelectCommit = onSelectCommit
        coordinator.onCopyOid = onCopyOid
        coordinator.onCreateBranchAtCommit = onCreateBranchAtCommit
        coordinator.onCreateTagAtCommit = onCreateTagAtCommit
        coordinator.onCheckoutCommit = onCheckoutCommit

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
        var lastGraphRevision: UUID?
        var onLoadMore: () -> Void
        var onSelectCommit: (CommitRow?) -> Void
        var onCopyOid: (String) -> Void
        var onCreateBranchAtCommit: (String) -> Void
        var onCreateTagAtCommit: (String) -> Void
        var onCheckoutCommit: (String) -> Void
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

            let copyItem = NSMenuItem(title: "Copy Commit SHA (\(commit.shortOid))", action: #selector(handleCopyOid(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = commit.oidHex
            menu.addItem(copyItem)

            let branchItem = NSMenuItem(title: "Create Branch Here…", action: #selector(handleCreateBranch(_:)), keyEquivalent: "")
            branchItem.target = self
            branchItem.representedObject = commit.oidHex
            menu.addItem(branchItem)

            let tagItem = NSMenuItem(title: "Create Tag Here…", action: #selector(handleCreateTag(_:)), keyEquivalent: "")
            tagItem.target = self
            tagItem.representedObject = commit.oidHex
            menu.addItem(tagItem)

            let checkoutItem = NSMenuItem(title: "Checkout Commit (Detached)", action: #selector(handleCheckoutCommit(_:)), keyEquivalent: "")
            checkoutItem.target = self
            checkoutItem.representedObject = commit.oidHex
            menu.addItem(checkoutItem)
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
                cell.configure(commit: commit, hasIncomingLine: hasIncomingLine)
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
    private let authorLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var graphWidthConstraint: NSLayoutConstraint!

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
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
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
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
        authorLabel.alignment = .right

        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right

        addSubview(graphView)
        addSubview(badgesStack)
        addSubview(summaryLabel)
        addSubview(authorLabel)
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
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: authorLabel.leadingAnchor, constant: -10),

            authorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            authorLabel.widthAnchor.constraint(equalToConstant: 120),
            authorLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),

            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 72),
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
        timeLabel.stringValue = ""
    }

    func configure(commit: CommitRow, hasIncomingLine: Bool) {
        let lanes = max(1, Int(commit.maxLanes))
        graphWidthConstraint.constant = GraphCellView.width(forLanes: lanes)
        graphView.alphaValue = commit.isRemoteOnly ? 0.65 : 1.0
        graphView.configure(commit: commit, hasIncomingLine: hasIncomingLine)

        badgesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if commit.refs.isEmpty {
            badgesStack.isHidden = true
        } else {
            badgesStack.isHidden = false
            for badge in commit.refs.prefix(4) {
                badgesStack.addArrangedSubview(RefPillView(badge: badge))
            }
        }

        summaryLabel.stringValue = commit.summary
        summaryLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        summaryLabel.textColor = commit.isRemoteOnly ? .secondaryLabelColor : .labelColor

        authorLabel.stringValue = commit.authorName
        authorLabel.textColor = commit.isRemoteOnly ? .tertiaryLabelColor : .secondaryLabelColor
        let date = Date(timeIntervalSince1970: TimeInterval(commit.timestamp))
        timeLabel.stringValue = Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

final class RefPillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(badge: RefBadge) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = badge.isCurrent ? 1 : 0

        let (bgColor, fgColor, borderColor): (NSColor, NSColor, NSColor) = switch badge.kind {
        case .localBranch:
            (
                NSColor.systemBlue.withAlphaComponent(badge.isCurrent ? 0.22 : 0.12),
                NSColor.systemBlue,
                NSColor.systemBlue.withAlphaComponent(0.6)
            )
        case .remoteBranch:
            (
                NSColor.systemPurple.withAlphaComponent(0.14),
                NSColor.systemPurple,
                NSColor.clear
            )
        case .tag:
            (
                NSColor.systemOrange.withAlphaComponent(0.16),
                NSColor.systemOrange,
                NSColor.clear
            )
        case .head:
            (
                NSColor.systemGreen.withAlphaComponent(0.2),
                NSColor.systemGreen,
                NSColor.systemGreen.withAlphaComponent(0.6)
            )
        }

        layer?.backgroundColor = bgColor.cgColor
        layer?.borderColor = borderColor.cgColor

        label.stringValue = badge.name
        label.font = .systemFont(ofSize: 10.5, weight: badge.isCurrent ? .semibold : .medium)
        label.textColor = fgColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
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

    override var isFlipped: Bool { true }

    static func width(forLanes lanes: Int) -> CGFloat {
        leftPadding * 2 + CGFloat(max(1, lanes)) * laneWidth
    }

    func configureWorkingChanges() {
        isWorkingChanges = true
        commit = nil
        hasIncomingLine = false
        needsDisplay = true
    }

    func configure(commit: CommitRow, hasIncomingLine: Bool) {
        isWorkingChanges = false
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

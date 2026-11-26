import AppKit
import SwiftUI

struct DiffTableView: NSViewRepresentable {
    let rows: [DiffRow]

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let table = NSTableView()
        table.headerView = nil
        // The default `.inset` style pads the table (and tints rows) away from the edges.
        table.style = .plain
        scrollView.borderType = .noBorder
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        table.usesAutomaticRowHeights = false
        table.rowHeight = DiffRowCellView.lineHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        // File headers are group rows, which stay at the top while their file scrolls by.
        table.floatsGroupRows = true
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.minWidth = 400
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.observeResize(scrollView: scrollView, table: table)
        context.coordinator.observeHorizontalScroll(scrollView: scrollView, table: table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        // Compare every row: an edit in the middle of a hunk keeps the count and the first and
        // last rows, and a partial check would leave the visible cells showing the old text.
        let changed = context.coordinator.rows != rows

        if changed {
            context.coordinator.rows = rows
        }
        context.coordinator.updateColumnWidth(scrollView: scrollView, table: table)

        guard changed else { return }
        table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [DiffRow] {
            didSet { longestLine = Self.longestLine(in: rows) }
        }
        /// Length of the widest row, cached so layout passes don't recount every row.
        private var longestLine: Int
        private var frameObserver: NSObjectProtocol?
        private var boundsObserver: NSObjectProtocol?
        private var gutterOffset: CGFloat = 0
        private var visibleWidth: CGFloat = 0
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("DiffRowCell")

        init(rows: [DiffRow]) {
            self.rows = rows
            self.longestLine = Self.longestLine(in: rows)
        }

        private static func longestLine(in rows: [DiffRow]) -> Int {
            rows.reduce(0) { max($0, $1.text.utf16.count) }
        }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        /// Keeps the line-number gutter pinned to the left edge while the code scrolls
        /// horizontally underneath it.
        func observeHorizontalScroll(scrollView: NSScrollView, table: NSTableView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView, weak table] _ in
                guard let self, let scrollView, let table else { return }
                let x = max(0, scrollView.contentView.bounds.origin.x)
                guard abs(x - self.gutterOffset) > 0.01 else { return }
                self.gutterOffset = x
                table.enumerateAvailableRowViews { rowView, _ in
                    (rowView.view(atColumn: 0) as? DiffRowCellView)?.gutterOffset = x
                }
            }
        }

        func observeResize(scrollView: NSScrollView, table: NSTableView) {
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView, weak table] _ in
                guard let self, let scrollView, let table else { return }
                self.updateColumnWidth(scrollView: scrollView, table: table)
            }
        }

        func updateColumnWidth(scrollView: NSScrollView, table: NSTableView) {
            let contentWidth = CGFloat(longestLine) * 7.6 + 130
            let visibleWidth = scrollView.contentView.bounds.width
            let targetWidth = max(visibleWidth, contentWidth, 400)
            if let col = table.tableColumns.first, abs(col.width - targetWidth) > 0.5 {
                col.width = targetWidth
            }
            guard abs(visibleWidth - self.visibleWidth) > 0.5 else { return }
            self.visibleWidth = visibleWidth
            table.enumerateAvailableRowViews { rowView, _ in
                (rowView.view(atColumn: 0) as? DiffRowCellView)?.visibleWidth = visibleWidth
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows[row].kind == "header" ? DiffRowCellView.fileHeaderHeight : DiffRowCellView.lineHeight
        }

        func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
            rows[row].kind == "header"
        }

        func tableView(_: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            rows[row].kind == "header" ? DiffFileHeaderRowView() : nil
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DiffRowCellView)
                ?? DiffRowCellView(identifier: Self.cellIdentifier)
            cell.configure(row: rows[row])
            cell.gutterOffset = gutterOffset
            cell.visibleWidth = visibleWidth
            cell.endsFile = row + 1 < rows.count && rows[row + 1].kind == "header"
            return cell
        }
    }
}

/// Replaces AppKit's group row styling; the cell draws the whole header itself.
private final class DiffFileHeaderRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func drawSeparator(in _: NSRect) {}
}

final class DiffRowCellView: NSTableCellView {
    private let gutterView = NSView()
    private let gutterTint = NSView()
    private let oldLineLabel = NSTextField(labelWithString: "")
    private let newLineLabel = NSTextField(labelWithString: "")
    private let gutterDivider = NSBox()
    private let codeLabel = NSTextField(labelWithString: "")
    /// The bar naming each file when the diff spans several files.
    private let fileHeader = NSView()
    /// Closes off a file above the next one's header. It belongs to the row above so that a
    /// header at the top of the diff doesn't double the line already there.
    private let fileEndRule = NSBox()
    private let fileIcon = NSImageView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private var gutterLeading: NSLayoutConstraint?
    private var fileIconLeading: NSLayoutConstraint?
    private var fileNameMaxWidth: NSLayoutConstraint?
    private var row: DiffRow?

    static let lineHeight: CGFloat = 20
    static let fileHeaderHeight: CGFloat = 30
    private static let fileIconInset: CGFloat = 10
    private static let fileIconWidth: CGFloat = 16
    private static let fileNameSpacing: CGFloat = 6

    /// 6 + 36 + 4 + 36 + 6 + 1: labels, spacing and the divider.
    private static let gutterWidth: CGFloat = 89
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    /// Horizontal scroll offset the gutter is shifted by so it stays visible.
    var gutterOffset: CGFloat = 0 {
        didSet {
            gutterLeading?.constant = gutterOffset
            fileIconLeading?.constant = gutterOffset + Self.fileIconInset
        }
    }

    /// Width of the scroll view's visible area. A pinned header can't be scrolled sideways,
    /// so its file name has to fit inside this.
    var visibleWidth: CGFloat = 0 {
        didSet {
            let chrome = Self.fileIconInset * 2 + Self.fileIconWidth + Self.fileNameSpacing
            fileNameMaxWidth?.constant = max(0, visibleWidth - chrome)
        }
    }

    var endsFile = false {
        didSet { fileEndRule.isHidden = !endsFile }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        for view in [gutterView, gutterTint, oldLineLabel, newLineLabel, gutterDivider, codeLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        for gutter in [oldLineLabel, newLineLabel] {
            gutter.font = Self.gutterFont
            gutter.textColor = .tertiaryLabelColor
            gutter.alignment = .right
        }

        gutterDivider.boxType = .separator

        codeLabel.font = Self.monoFont
        codeLabel.lineBreakMode = .byClipping
        codeLabel.allowsEditingTextAttributes = false
        codeLabel.isSelectable = true

        // The gutter is opaque (so scrolled code never shows through) with the row's
        // highlight tinted on top.
        gutterView.wantsLayer = true
        gutterTint.wantsLayer = true

        addSubview(codeLabel)
        addSubview(gutterView)
        gutterView.addSubview(gutterTint)
        gutterView.addSubview(oldLineLabel)
        gutterView.addSubview(newLineLabel)
        gutterView.addSubview(gutterDivider)

        let leading = gutterView.leadingAnchor.constraint(equalTo: leadingAnchor)
        gutterLeading = leading
        setupFileHeader()
        setupFileEndRule()

        NSLayoutConstraint.activate([
            leading,
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: Self.gutterWidth),

            gutterTint.leadingAnchor.constraint(equalTo: gutterView.leadingAnchor),
            gutterTint.trailingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            gutterTint.topAnchor.constraint(equalTo: gutterView.topAnchor),
            gutterTint.bottomAnchor.constraint(equalTo: gutterView.bottomAnchor),

            oldLineLabel.leadingAnchor.constraint(equalTo: gutterView.leadingAnchor, constant: 6),
            oldLineLabel.widthAnchor.constraint(equalToConstant: 36),
            oldLineLabel.centerYAnchor.constraint(equalTo: gutterView.centerYAnchor),

            newLineLabel.leadingAnchor.constraint(equalTo: oldLineLabel.trailingAnchor, constant: 4),
            newLineLabel.widthAnchor.constraint(equalToConstant: 36),
            newLineLabel.centerYAnchor.constraint(equalTo: gutterView.centerYAnchor),

            gutterDivider.leadingAnchor.constraint(equalTo: newLineLabel.trailingAnchor, constant: 6),
            gutterDivider.topAnchor.constraint(equalTo: gutterView.topAnchor),
            gutterDivider.bottomAnchor.constraint(equalTo: gutterView.bottomAnchor),
            gutterDivider.widthAnchor.constraint(equalToConstant: 1),

            // The code does not move; it starts just right of the gutter's resting place.
            codeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.gutterWidth + 8),
            codeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func setupFileHeader() {
        for view in [fileHeader, fileIcon, fileNameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        fileHeader.wantsLayer = true
        fileIcon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        fileIcon.contentTintColor = .secondaryLabelColor
        // Quieter than the pane's title bar above it.
        fileNameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        // Truncate the front of a long path, so the file's own name stays readable.
        fileNameLabel.lineBreakMode = .byTruncatingHead
        fileNameLabel.usesSingleLineMode = true
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileNameLabel.isSelectable = true

        addSubview(fileHeader)
        // No rules of its own: macOS draws an edge under a pinned header, and the diff pane
        // has a divider above the table. A second line against either looks like a shadow.
        for view in [fileIcon, fileNameLabel] {
            fileHeader.addSubview(view)
        }

        // Like the gutter, the icon and name stay put while the code scrolls horizontally.
        let iconLeading = fileIcon.leadingAnchor.constraint(
            equalTo: fileHeader.leadingAnchor, constant: Self.fileIconInset
        )
        fileIconLeading = iconLeading
        let nameMaxWidth = fileNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        fileNameMaxWidth = nameMaxWidth

        NSLayoutConstraint.activate([
            fileHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            fileHeader.bottomAnchor.constraint(equalTo: bottomAnchor),
            fileHeader.heightAnchor.constraint(equalToConstant: Self.fileHeaderHeight),

            iconLeading,
            fileIcon.centerYAnchor.constraint(equalTo: fileHeader.centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: Self.fileIconWidth),

            nameMaxWidth,
            fileNameLabel.leadingAnchor.constraint(
                equalTo: fileIcon.trailingAnchor, constant: Self.fileNameSpacing
            ),
            fileNameLabel.centerYAnchor.constraint(equalTo: fileHeader.centerYAnchor),
        ])
    }

    /// Added last, so it draws over the gutter.
    private func setupFileEndRule() {
        fileEndRule.translatesAutoresizingMaskIntoConstraints = false
        fileEndRule.boxType = .separator
        fileEndRule.isHidden = true
        addSubview(fileEndRule)
        NSLayoutConstraint.activate([
            fileEndRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileEndRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            fileEndRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            fileEndRule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer background and highlight colors are resolved to concrete CGColors
        // in `configure`, so re-run it under the new appearance.
        guard let row else { return }
        configure(row: row)
    }

    /// Resolves all dynamic colors under this cell's own effective appearance, so the
    /// result is correct whether called from cell reuse or an appearance change.
    func configure(row: DiffRow) {
        self.row = row
        let appearance = effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearance.performAsCurrentDrawingAppearance {
            self.applyConfiguration(row: row, isDark: isDark)
        }
    }

    private func applyConfiguration(row: DiffRow, isDark: Bool) {
        // Cells are reused, so every row sets which of the two layouts is showing.
        let isFileHeader = row.kind == "header"
        fileHeader.isHidden = !isFileHeader
        gutterView.isHidden = isFileHeader
        codeLabel.isHidden = isFileHeader
        if isFileHeader {
            // Opaque under the tint, so code never shows through a floating header.
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            fileHeader.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            fileNameLabel.textColor = NSColor.labelColor.withAlphaComponent(0.65)
            fileNameLabel.stringValue = row.text
            fileNameLabel.toolTip = row.text
            codeLabel.stringValue = ""
            return
        }

        oldLineLabel.stringValue = row.oldLine.map(String.init) ?? ""
        newLineLabel.stringValue = row.newLine.map(String.init) ?? ""

        let bgColor: NSColor
        let defaultTextColor: NSColor
        switch row.kind {
        case "addition":
            bgColor = NSColor.systemGreen.withAlphaComponent(0.13)
            defaultTextColor = NSColor.labelColor
        case "deletion":
            bgColor = NSColor.systemRed.withAlphaComponent(0.13)
            defaultTextColor = NSColor.labelColor
        case "hunk":
            bgColor = NSColor.systemBlue.withAlphaComponent(0.10)
            defaultTextColor = NSColor.systemBlue
        default:
            bgColor = NSColor.clear
            defaultTextColor = NSColor.labelColor
        }
        layer?.backgroundColor = bgColor.cgColor
        gutterView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        gutterTint.layer?.backgroundColor = bgColor.cgColor

        if row.spans.isEmpty {
            codeLabel.textColor = defaultTextColor
            codeLabel.stringValue = row.text
        } else {
            let attr = NSMutableAttributedString(
                string: row.text,
                attributes: [
                    .font: Self.monoFont,
                    .foregroundColor: defaultTextColor,
                ]
            )
            let utf16Len = (row.text as NSString).length
            for span in row.spans {
                let start = Int(span.startUtf16)
                let len = Int(span.lenUtf16)
                if start >= 0 && start + len <= utf16Len, let color = NSColor(hex: span.foreground, isDark: isDark) {
                    attr.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: len))
                }
            }
            codeLabel.attributedStringValue = attr
        }
    }
}

private extension NSColor {
    convenience init?(hex: String, isDark: Bool) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        var r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        var g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        var b = CGFloat(rgb & 0xFF) / 255.0

        // base16-ocean.dark tokens are light pastels; darken them in Light Mode for crisp contrast.
        if !isDark {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luminance > 0.55 {
                r *= 0.48
                g *= 0.48
                b *= 0.48
            }
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

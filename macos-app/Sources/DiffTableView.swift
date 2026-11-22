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
        table.usesAutomaticRowHeights = false
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let prev = context.coordinator.rows
        let changed = prev.count != rows.count
            || prev.first?.text != rows.first?.text
            || prev.last?.text != rows.last?.text
            || prev.first?.newLine != rows.first?.newLine
            || prev.last?.newLine != rows.last?.newLine
        guard changed else { return }
        context.coordinator.rows = rows
        table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [DiffRow]
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("DiffRowCell")

        init(rows: [DiffRow]) {
            self.rows = rows
        }

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DiffRowCellView)
                ?? DiffRowCellView(identifier: Self.cellIdentifier)
            cell.configure(row: rows[row])
            return cell
        }
    }
}

final class DiffRowCellView: NSTableCellView {
    private let oldLineLabel = NSTextField(labelWithString: "")
    private let newLineLabel = NSTextField(labelWithString: "")
    private let gutterDivider = NSBox()
    private let codeLabel = NSTextField(labelWithString: "")

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

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
        oldLineLabel.translatesAutoresizingMaskIntoConstraints = false
        newLineLabel.translatesAutoresizingMaskIntoConstraints = false
        gutterDivider.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        for gutter in [oldLineLabel, newLineLabel] {
            gutter.font = Self.gutterFont
            gutter.textColor = .tertiaryLabelColor
            gutter.alignment = .right
        }

        gutterDivider.boxType = .separator

        codeLabel.font = Self.monoFont
        codeLabel.lineBreakMode = .byTruncatingTail
        codeLabel.allowsEditingTextAttributes = false
        codeLabel.isSelectable = false

        addSubview(oldLineLabel)
        addSubview(newLineLabel)
        addSubview(gutterDivider)
        addSubview(codeLabel)

        NSLayoutConstraint.activate([
            oldLineLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            oldLineLabel.widthAnchor.constraint(equalToConstant: 36),
            oldLineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            newLineLabel.leadingAnchor.constraint(equalTo: oldLineLabel.trailingAnchor, constant: 4),
            newLineLabel.widthAnchor.constraint(equalToConstant: 36),
            newLineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            gutterDivider.leadingAnchor.constraint(equalTo: newLineLabel.trailingAnchor, constant: 6),
            gutterDivider.topAnchor.constraint(equalTo: topAnchor),
            gutterDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterDivider.widthAnchor.constraint(equalToConstant: 1),

            codeLabel.leadingAnchor.constraint(equalTo: gutterDivider.trailingAnchor, constant: 8),
            codeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(row: DiffRow) {
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
        case "header":
            bgColor = NSColor.controlBackgroundColor
            defaultTextColor = NSColor.secondaryLabelColor
        default:
            bgColor = NSColor.clear
            defaultTextColor = NSColor.labelColor
        }
        layer?.backgroundColor = bgColor.cgColor

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
                if start >= 0 && start + len <= utf16Len, let color = NSColor(hex: span.foreground) {
                    attr.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: len))
                }
            }
            codeLabel.attributedStringValue = attr
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

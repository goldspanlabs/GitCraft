import AppKit
import SwiftUI

struct CommitTableView: NSViewRepresentable {
    let rows: [CommitRow]

    func makeCoordinator() -> Coordinator { Coordinator(rows: rows) }
    func makeNSView(context: Context) -> NSTableView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 32
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit")))
        return table
    }
    func updateNSView(_ table: NSTableView, context: Context) {
        context.coordinator.rows = rows
        table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [CommitRow]
        init(rows: [CommitRow]) { self.rows = rows }
        func numberOfRows(in _: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: "\(rows[row].hash.prefix(8))  \(rows[row].summary)")
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

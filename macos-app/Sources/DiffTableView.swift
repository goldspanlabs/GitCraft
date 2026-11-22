import AppKit
import SwiftUI

struct DiffTableView: NSViewRepresentable {
    let rows: [String]
    func makeNSView(context: Context) -> NSTableView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 20
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff")))
        table.dataSource = context.coordinator
        return table
    }
    func updateNSView(_ table: NSTableView, context: Context) {
        context.coordinator.rows = rows
        table.reloadData()
    }
    func makeCoordinator() -> Coordinator { Coordinator(rows: rows) }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [String]
        init(rows: [String]) { self.rows = rows }
        func numberOfRows(in _: NSTableView) -> Int { rows.count }
        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            NSTextField(labelWithString: rows[row])
        }
    }
}

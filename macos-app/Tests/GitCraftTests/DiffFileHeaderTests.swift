import AppKit
import SwiftUI
import XCTest
@testable import GitCraft

@MainActor
final class DiffFileHeaderTests: XCTestCase {
    private let path = String(repeating: "shared/directory/", count: 8) + "Distinct.swift"

    func testLongPathStaysWithinTheVisibleWidth() throws {
        // A code line wider than the path, so the diff can also scroll sideways.
        let rows = [
            DiffRow(kind: "header", text: path, oldLine: nil, newLine: nil, spans: []),
            DiffRow(kind: "context", text: String(repeating: "x", count: 400), oldLine: 1, newLine: 1, spans: []),
        ]
        let host = NSHostingView(rootView: DiffTableView(rows: rows))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        settle(host)
        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: host) { _ in true })

        try assertNameFits(in: scrollView, host: host)

        scrollView.contentView.scroll(to: NSPoint(x: 500, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(host)
        try assertNameFits(in: scrollView, host: host)

        window.setContentSize(NSSize(width: 250, height: 120))
        settle(host)
        try assertNameFits(in: scrollView, host: host)
    }

    private func assertNameFits(
        in scrollView: NSScrollView, host: NSView, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let label = try XCTUnwrap(
            find(NSTextField.self, in: host) { $0.stringValue == path }, file: file, line: line
        )
        let frame = label.convert(label.bounds, to: scrollView.contentView)
        let visible = scrollView.contentView.bounds
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX, file: file, line: line)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingHead, file: file, line: line)
        XCTAssertEqual(label.toolTip, path, file: file, line: line)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
    }

    private func find<View: NSView>(_ type: View.Type, in view: NSView, where matches: (View) -> Bool) -> View? {
        if let found = view as? View, matches(found) { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview, where: matches) { return found }
        }
        return nil
    }
}

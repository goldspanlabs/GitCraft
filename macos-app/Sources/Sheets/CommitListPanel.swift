import AppKit
import SwiftUI

/// A recessed, scrolling list of commits for a sheet. A list too long to show cuts its last
/// row in half and shows a scrollbar while the pointer is over it.
struct CommitListPanel: View {
    struct Item {
        let oid: String
        let shortOid: String
        let summary: String
    }

    let items: [Item]
    /// How many rows the panel is sized for; lists beside each other pass the same number.
    let rows: Int
    /// The most whole rows shown before the list scrolls.
    let limit: Int

    private static let rowHeight: CGFloat = 20
    private static let inset: CGFloat = 8

    /// The height of the visible rows. The extra half row says there is more below.
    static func listHeight(rows: Int, limit: Int) -> CGFloat {
        rowHeight * (rows > limit ? CGFloat(limit) + 0.5 : CGFloat(rows))
    }

    var body: some View {
        HoverScroller(content: list)
            .frame(height: Self.listHeight(rows: rows, limit: limit))
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.oid) { item in
                HStack(spacing: 8) {
                    Text(item.shortOid)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.summary)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .help(item.summary)
                }
                .frame(height: Self.rowHeight)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A vertical scroll view whose scrollbar shows only while the pointer is over it and there is
/// something to scroll. SwiftUI's own indicators fade out whatever the pointer does.
final class HoverScrollView: NSScrollView {
    var isHovered = false {
        didSet { showScrollerIfNeeded() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = false
        // A legacy scroller keeps its own space, so showing it doesn't move the rows.
        scrollerStyle = .legacy
        verticalScroller?.isHidden = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func tile() {
        // The system switches the style when a mouse is plugged in or the setting changes.
        if scrollerStyle != .legacy { scrollerStyle = .legacy }
        super.tile()
        showScrollerIfNeeded()
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
    }

    private func showScrollerIfNeeded() {
        let overflows = (documentView?.frame.height ?? 0) > contentSize.height
        verticalScroller?.isHidden = !(isHovered && overflows)
    }
}

private struct HoverScroller<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context _: Context) -> HoverScrollView {
        let scrollView = HoverScrollView(frame: .zero)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: HoverScrollView, context _: Context) {
        (scrollView.documentView as? NSHostingView<Content>)?.rootView = content
    }
}

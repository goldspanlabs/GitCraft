import AppKit
import SwiftUI

/// A vertical split (top / bottom) whose bottom pane height is remembered across launches.
/// SwiftUI's `VSplitView` can't persist its divider, so this draws its own.
struct PersistentVSplit<Top: View, Bottom: View>: View {
    static var storageKey: String { "bottomPanelHeight" }
    /// Whether the bottom panel is collapsed to just its tab strip.
    static var collapsedKey: String { "bottomPanelCollapsed" }
    /// Height of the tab strip (30pt) plus its divider: what stays visible when collapsed.
    static var collapsedHeight: CGFloat { 31 }

    let minTop: CGFloat
    let minBottom: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    @AppStorage(PersistentVSplit<EmptyView, EmptyView>.storageKey) private var storedHeight: Double = 290
    @AppStorage(PersistentVSplit<EmptyView, EmptyView>.collapsedKey) private var isCollapsed = false
    @State private var dragStartHeight: Double?

    var body: some View {
        GeometryReader { geo in
            let maxBottom = max(minBottom, geo.size.height - minTop - 1)
            let expandedHeight = min(max(CGFloat(storedHeight), minBottom), maxBottom)
            let bottomHeight = isCollapsed ? Self.collapsedHeight : expandedHeight

            VStack(spacing: 0) {
                top()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                Divider()
                    .overlay {
                        // Wider invisible grab area around the 1pt line (not when collapsed).
                        if !isCollapsed {
                        Color.clear
                            .frame(height: 9)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStartHeight ?? Double(bottomHeight)
                                        dragStartHeight = start
                                        let proposed = CGFloat(start - value.translation.height)
                                        storedHeight = Double(min(max(proposed, minBottom), maxBottom))
                                    }
                                    .onEnded { _ in dragStartHeight = nil }
                            )
                        }
                    }

                bottom()
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomHeight, alignment: .top)
                    .clipped()
            }
        }
    }
}

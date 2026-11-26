import AppKit
import SwiftUI

/// A vertical split (top / bottom) whose bottom pane height is remembered across launches.
/// SwiftUI's `VSplitView` can't persist its divider, so this draws its own.
///
/// Dragging the divider down past the minimum height (plus a threshold) collapses the bottom
/// pane to its tab strip; dragging it back up reopens it. The pane can also be maximized, which
/// hides the top pane and gives the bottom pane the whole split.
struct PersistentVSplit<Top: View, Bottom: View>: View {
    let minTop: CGFloat
    let minBottom: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    @AppStorage(BottomPanelDefaults.storageKey) private var storedHeight: Double = 290
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false
    @State private var dragStartHeight: Double?
    @State private var dragStartedCollapsed = false

    var body: some View {
        GeometryReader { geo in
            let maxBottom = max(minBottom, geo.size.height - minTop - 1)
            let expandedHeight = min(max(CGFloat(storedHeight), minBottom), maxBottom)
            let bottomHeight: CGFloat = if isMaximized {
                max(minBottom, geo.size.height - 1)
            } else if isCollapsed {
                BottomPanelDefaults.collapsedHeight
            } else {
                expandedHeight
            }

            VStack(spacing: 0) {
                top()
                    .frame(maxWidth: .infinity, maxHeight: isMaximized ? 0 : .infinity)
                    .clipped()

                Divider()
                    .overlay {
                        // Wider invisible grab area around the 1pt line. It stays active while
                        // collapsed so the panel can be dragged back open.
                        if !isMaximized {
                            Color.clear
                                .frame(height: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            handleDrag(
                                                translation: value.translation.height,
                                                currentHeight: bottomHeight,
                                                maxBottom: maxBottom
                                            )
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

    /// Resizes the pane while dragging, collapsing or reopening it at the thresholds.
    ///
    /// The collapse decision depends on where the drag started, not on the current state, so a
    /// drag that hovers near a threshold can't flicker between open and collapsed.
    private func handleDrag(translation: CGFloat, currentHeight: CGFloat, maxBottom: CGFloat) {
        if dragStartHeight == nil {
            dragStartHeight = Double(currentHeight)
            dragStartedCollapsed = isCollapsed
        }
        let proposed = CGFloat(dragStartHeight ?? Double(currentHeight)) - translation

        let shouldCollapse = if dragStartedCollapsed {
            proposed <= BottomPanelDefaults.collapsedHeight + BottomPanelDefaults.expandDragThreshold
        } else {
            proposed < minBottom - BottomPanelDefaults.collapseDragThreshold
        }

        if shouldCollapse != isCollapsed {
            withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = shouldCollapse }
        }
        if !shouldCollapse {
            let clamped = Double(min(max(proposed, minBottom), maxBottom))
            // Reopening from the collapsed strip restores the last height; only pulling beyond it
            // makes the pane taller.
            storedHeight = dragStartedCollapsed ? max(storedHeight, clamped) : clamped
        }
    }
}

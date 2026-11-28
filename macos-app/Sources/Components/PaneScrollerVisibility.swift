import AppKit

/// Keeps a narrow native scroller visible while the pointer is in the pane or scrolling is underway.
final class PaneScrollerVisibility: NSView {
    private var isHovered = false
    private var isScrolling = false
    private var lightAppearanceOpacity: CGFloat = 1

    static func install(on scrollView: NSScrollView, lightAppearanceOpacity: CGFloat = 1) {
        guard scrollView.verticalScroller != nil,
              !scrollView.subviews.contains(where: { $0 is PaneScrollerVisibility }) else { return }

        // AppKit automatically fades overlay scrollers. A legacy scroller lets us control
        // visibility without changing the content width when the pointer enters or leaves.
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small

        let visibility = PaneScrollerVisibility(frame: .zero)
        visibility.lightAppearanceOpacity = lightAppearanceOpacity
        scrollView.addSubview(visibility)
        scrollView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: visibility,
            userInfo: nil
        ))
        NotificationCenter.default.addObserver(
            visibility,
            selector: #selector(PaneScrollerVisibility.didScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        visibility.updateVisibility()
        scrollView.tile()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisibility()
    }

    @objc private func didScroll(_ notification: Notification) {
        isScrolling = true
        updateVisibility()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(scrollSettled), object: nil)
        perform(#selector(scrollSettled), with: nil, afterDelay: 0.35)
    }

    @objc private func scrollSettled() {
        isScrolling = false
        updateVisibility()
    }

    private func updateVisibility() {
        guard let scrollView = superview as? NSScrollView else { return }
        let isLight = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let visibleOpacity = isLight ? lightAppearanceOpacity : 1
        scrollView.verticalScroller?.alphaValue = isHovered || isScrolling ? visibleOpacity : 0
    }
}

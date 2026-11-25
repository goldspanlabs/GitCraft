import AppKit

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

    /// The lane colour for a graph colour index. Branch chips reuse it so they match their lane.
    static func laneColor(for idx: UInt8) -> NSColor {
        palette[Int(idx) % palette.count]
    }

    static func width(forLanes lanes: Int) -> CGFloat {
        leftPadding * 2 + CGFloat(max(1, lanes)) * laneWidth
    }

    /// Horizontal centre of a lane, measured from the graph view's leading edge.
    static func centerX(forLane lane: Int) -> CGFloat {
        leftPadding + CGFloat(lane) * laneWidth + laneWidth / 2
    }

    private var commit: CommitRow?
    private var hasIncomingLine = false
    private var isWorkingChanges = false

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineCap(.round)

        let midY = bounds.height / 2

        if isWorkingChanges {
            let x = Self.centerX(forLane: 0)
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
            let edgeColor = Self.laneColor(for: edge.colorIdx).cgColor
            ctx.setStrokeColor(edgeColor)

            let fromX = Self.centerX(forLane: Int(edge.fromLane))
            let toX = Self.centerX(forLane: Int(edge.toLane))

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
            let x = Self.centerX(forLane: Int(commit.lane))
            ctx.setStrokeColor(Self.laneColor(for: commit.colorIdx).cgColor)
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: midY))
            ctx.strokePath()
        }

        // Draw commit circle with a 1.5pt background-colored stroke ring.
        let nodeX = Self.centerX(forLane: Int(commit.lane))
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
        ctx.setFillColor(Self.laneColor(for: commit.colorIdx).cgColor)
        ctx.fillEllipse(in: dotRect)
    }
}

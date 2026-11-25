import AppKit

final class CommitRowCellView: NSTableCellView {
    private let graphView = GraphCellView()
    private let badgesStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let avatarView = AvatarImageView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let hashLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var graphWidthConstraint: NSLayoutConstraint!

    private static let summaryRegularFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    private static let summarySemiboldFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let summaryBoldFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    private static let columnRegularFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    private static let columnBoldFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
    private static let hashRegularFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let hashBoldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

    /// "Yesterday at 10:57 PM" for recent days, "Nov 22, 2026 at 6:38 PM" otherwise.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let formattedDateCache: NSCache<NSNumber, NSString> = {
        let cache = NSCache<NSNumber, NSString>()
        cache.countLimit = 2000
        return cache
    }()
    private static var formattedDateCacheDay = Date()
    private static var formattedDateCacheTimeZone = TimeZone.autoupdatingCurrent
    private static var formattedDateCacheLocale = Locale.autoupdatingCurrent

    private static func formattedDate(for timestamp: Int64) -> String {
        let currentTimeZone = TimeZone.autoupdatingCurrent
        let currentLocale = Locale.autoupdatingCurrent
        if !Calendar.autoupdatingCurrent.isDateInToday(formattedDateCacheDay)
            || formattedDateCacheTimeZone != currentTimeZone
            || formattedDateCacheLocale != currentLocale
        {
            formattedDateCache.removeAllObjects()
            formattedDateCacheDay = Date()
            formattedDateCacheTimeZone = currentTimeZone
            formattedDateCacheLocale = currentLocale
            dateFormatter.timeZone = currentTimeZone
            dateFormatter.locale = currentLocale
        }
        let key = NSNumber(value: timestamp)
        if let cached = formattedDateCache.object(forKey: key) {
            return cached as String
        }
        let formatted = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        formattedDateCache.setObject(formatted as NSString, forKey: key)
        return formatted
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        for view in [graphView, badgesStack, summaryLabel, avatarView, authorLabel, hashLabel, timeLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        badgesStack.orientation = .horizontal
        badgesStack.spacing = 4
        badgesStack.alignment = .centerY
        badgesStack.setHuggingPriority(.required, for: .horizontal)

        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .systemFont(ofSize: 12.5)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.font = .systemFont(ofSize: 11.5)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .left

        hashLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        hashLabel.textColor = .secondaryLabelColor
        hashLabel.alignment = .left

        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 11.5)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .left

        graphWidthConstraint = graphView.widthAnchor.constraint(equalToConstant: 24)

        NSLayoutConstraint.activate([
            graphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            graphView.topAnchor.constraint(equalTo: topAnchor),
            graphView.bottomAnchor.constraint(equalTo: bottomAnchor),
            graphWidthConstraint,

            badgesStack.leadingAnchor.constraint(equalTo: graphView.trailingAnchor, constant: 6),
            badgesStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: badgesStack.trailingAnchor, constant: 6),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: avatarView.leadingAnchor, constant: -10),

            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 18),
            avatarView.heightAnchor.constraint(equalToConstant: 18),
            avatarView.trailingAnchor.constraint(equalTo: authorLabel.leadingAnchor, constant: -6),

            authorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            authorLabel.widthAnchor.constraint(equalToConstant: 130),
            authorLabel.trailingAnchor.constraint(equalTo: hashLabel.leadingAnchor, constant: -12),

            hashLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hashLabel.widthAnchor.constraint(equalToConstant: 64),
            hashLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),

            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 158),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    func configureWorkingChanges(fileCount: Int) {
        graphWidthConstraint.constant = 24
        graphView.alphaValue = 1.0
        graphView.configureWorkingChanges()
        badgesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        badgesStack.isHidden = true

        if fileCount > 0 {
            summaryLabel.stringValue = "Working Changes (\(fileCount) modified)"
            summaryLabel.font = Self.summarySemiboldFont
            summaryLabel.textColor = .labelColor
        } else {
            summaryLabel.stringValue = "Working Changes (Clean)"
            summaryLabel.font = Self.summaryRegularFont
            summaryLabel.textColor = .secondaryLabelColor
        }
        authorLabel.stringValue = ""
        hashLabel.stringValue = ""
        timeLabel.stringValue = ""
        avatarView.isHidden = true
        avatarView.clear()
    }

    func configure(
        commit: CommitRow,
        hasIncomingLine: Bool,
        otherWorktreeBranches: Set<String> = [],
        remoteHosts: [String: RemoteHost] = [:]
    ) {
        let lanes = max(1, Int(commit.maxLanes))
        graphWidthConstraint.constant = GraphCellView.width(forLanes: lanes)
        // Remote-only rows dim their text, not the graph lines.
        graphView.alphaValue = 1.0
        graphView.configure(
            commit: commit,
            hasIncomingLine: hasIncomingLine
        )

        badgesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if commit.refs.isEmpty {
            badgesStack.isHidden = true
        } else {
            badgesStack.isHidden = false
            let badges = Array(commit.refs.prefix(4))
            // Branch chips take the colour of the commit's graph lane.
            let laneColor = GraphCellView.laneColor(for: commit.colorIdx)
            // "origin/main" -> the host behind the "origin" remote.
            let hostFor: (RefBadge) -> RemoteHost? = { badge in
                badge.kind == .remoteBranch
                    ? badge.name.split(separator: "/", maxSplits: 1).first.flatMap { remoteHosts[String($0)] } ?? .other
                    : nil
            }
            // "origin/main" -> "main".
            let branchNameOf: (RefBadge) -> String = { badge in
                String(badge.name.split(separator: "/", maxSplits: 1).last ?? "")
            }
            // Hosted remote branches on the same commit as their local branch of the same name.
            // Each is drawn as its host icon chip followed by the local chip; the origin name chip is dropped.
            // Searches only the capped `badges`, so a local chip cut off by the cap can't come back.
            let mirrored = badges.filter { $0.kind == .remoteBranch && hostFor($0)?.icon != nil }.compactMap { remote -> RefBadge? in
                badges.first { $0.kind == .localBranch && $0.name == branchNameOf(remote) }
            }
            let mirroredLocalNames = Set(mirrored.map(\.name))
            // Remote chips lead the row, then the rest in their usual order (current branch first).
            var remoteChips: [NSView] = []
            var otherChips: [NSView] = []
            for badge in badges {
                if badge.kind == .localBranch, mirroredLocalNames.contains(badge.name) {
                    continue // drawn right after its remote's icon chip
                }
                if badge.kind == .remoteBranch, let local = mirrored.first(where: { $0.name == branchNameOf(badge) }) {
                    remoteChips.append(
                        RefPillView(badge: badge, host: hostFor(badge), iconOnly: true, laneColor: laneColor)
                    )
                    remoteChips.append(
                        RefPillView(
                            badge: local,
                            showsUnpushedDot: commit.isUnpushed,
                            inOtherWorktree: otherWorktreeBranches.contains(local.name),
                            laneColor: laneColor
                        )
                    )
                } else {
                    let chip = RefPillView(
                        badge: badge,
                        host: hostFor(badge),
                        showsUnpushedDot: commit.isUnpushed,
                        inOtherWorktree: badge.kind == .localBranch && otherWorktreeBranches.contains(badge.name),
                        laneColor: laneColor
                    )
                    if badge.kind == .remoteBranch {
                        remoteChips.append(chip)
                    } else {
                        otherChips.append(chip)
                    }
                }
            }
            for chip in remoteChips + otherChips {
                badgesStack.addArrangedSubview(chip)
            }
        }

        // The latest commit of the checked-out branch is bold.
        let isHeadCommit = commit.refs.contains { $0.isCurrent }
        summaryLabel.stringValue = commit.summary
        summaryLabel.font = isHeadCommit ? Self.summaryBoldFont : Self.summaryRegularFont
        summaryLabel.textColor = commit.isRemoteOnly ? .secondaryLabelColor : .labelColor

        avatarView.isHidden = false
        avatarView.configure(name: commit.authorName, email: commit.authorEmail)
        authorLabel.stringValue = commit.authorName
        let secondary: NSColor = commit.isRemoteOnly ? .tertiaryLabelColor : .secondaryLabelColor
        // The head commit's other columns match its summary: bold, in the primary text colour.
        let columnColor: NSColor = isHeadCommit ? .labelColor : secondary
        authorLabel.textColor = columnColor
        hashLabel.stringValue = commit.shortOid
        hashLabel.textColor = columnColor
        timeLabel.textColor = columnColor
        let columnFont = isHeadCommit ? Self.columnBoldFont : Self.columnRegularFont
        authorLabel.font = columnFont
        hashLabel.font = isHeadCommit ? Self.hashBoldFont : Self.hashRegularFont
        timeLabel.font = columnFont
        timeLabel.stringValue = Self.formattedDate(for: commit.timestamp)
    }
}

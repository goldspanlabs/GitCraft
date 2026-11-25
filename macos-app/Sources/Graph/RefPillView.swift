import AppKit

final class RefPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let divider = NSView()
    /// The untinted glyph; `applyColors` bakes the chip colour into `iconView.image`.
    private var templateIcon: NSImage?
    private var templateIconKey: String?
    private let badge: RefBadge
    /// The graph lane colour of the commit this chip sits on. Used by branch chips only;
    /// HEAD and tag chips keep fixed colours so they stand apart from the lanes.
    private let laneColor: NSColor?
    private let host: RemoteHost?
    private var appliedAppearanceName: NSAppearance.Name?

    private static let checkmarkIcon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        return NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current branch")?
            .withSymbolConfiguration(config)
    }()

    private static let tintedIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    /// `showsUnpushedDot` swaps the checked-out branch's check mark for an orange dot.
    /// `inOtherWorktree` marks a local branch checked out in a different worktree with a folder icon.
    /// `iconOnly` draws just the host mark, for a remote branch whose name is shown in a chip beside it.
    init(
        badge: RefBadge,
        host: RemoteHost? = nil,
        showsUnpushedDot: Bool = false,
        inOtherWorktree: Bool = false,
        iconOnly: Bool = false,
        laneColor: NSColor? = nil
    ) {
        self.badge = badge
        self.laneColor = laneColor
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.stringValue = badge.name
        label.font = .systemFont(ofSize: 11.5, weight: badge.isCurrent ? .bold : .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        if !iconOnly { addSubview(label) }
        if let host, let icon = host.icon {
            // Remote chips lead with the hosting service's mark, set off by a thin divider.
            configureLeadingIcon(icon, key: "host:\(host)", size: 14, iconOnly: iconOnly, withDivider: !iconOnly)
        } else if badge.isCurrent, badge.kind == .localBranch || badge.kind == .head, showsUnpushedDot {
            // Unpushed commits: the orange dot takes the check mark's place, same 13pt slot.
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            // Named for VoiceOver, which UI tests also read.
            dot.setAccessibilityElement(true)
            dot.setAccessibilityRole(.image)
            dot.setAccessibilityLabel("Unpushed commits")
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23),
            ])
        } else if badge.isCurrent, badge.kind == .localBranch || badge.kind == .head {
            // The checked-out branch gets a check mark in front of its name.
            configureLeadingIcon(Self.checkmarkIcon, key: "checkmark", size: 13, iconOnly: false, withDivider: false, labelSpacing: 4)
        } else if inOtherWorktree, badge.kind == .localBranch, !badge.isCurrent {
            // Checked out in another worktree: a folder mark set off by a divider, like tags.
            configureLeadingIcon(PhosphorIcon.nsImage(for: .folder), key: "folder", size: 12, iconOnly: false, withDivider: true)
        } else if badge.kind == .tag {
            // Tags lead with a tag glyph, set off by a thin divider like the host marks on remote chips.
            configureLeadingIcon(PhosphorIcon.nsImage(for: .tag), key: "tag", size: 12, iconOnly: false, withDivider: true)
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true
        }

        if !iconOnly {
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
        }

        applyColors()
    }

    private func configureLeadingIcon(
        _ icon: NSImage?,
        key: String,
        size: CGFloat,
        iconOnly: Bool,
        withDivider: Bool,
        labelSpacing: CGFloat = 6
    ) {
        templateIcon = icon
        templateIconKey = key
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        var constraints: [NSLayoutConstraint] = [
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: size),
            iconView.heightAnchor.constraint(equalToConstant: size),
        ]
        if iconOnly {
            // Icon-only chip: the name sits in its own chip beside it.
            constraints.append(iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
        } else if withDivider {
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.wantsLayer = true
            addSubview(divider)
            constraints += [
                divider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.topAnchor.constraint(equalTo: topAnchor),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                label.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: labelSpacing),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: labelSpacing))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override var wantsUpdateLayer: Bool { true }

    /// The tinted leading icon currently displayed by this chip (for tests).
    var displayedIconImage: NSImage? {
        iconView.image
    }

    override func updateLayer() {
        if appliedAppearanceName != effectiveAppearance.name {
            applyColors()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appliedAppearanceName = nil
        needsDisplay = true
    }

    private static func tinted(_ template: NSImage, key: String, with color: NSColor) -> NSImage {
        let byte: (CGFloat) -> UInt8 = { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        let cacheKey: NSString? = color.usingColorSpace(.sRGB).map { srgb in
            "\(key):\(byte(srgb.redComponent)):\(byte(srgb.greenComponent)):\(byte(srgb.blueComponent)):\(byte(srgb.alphaComponent))" as NSString
        }
        if let cacheKey, let cached = tintedIconCache.object(forKey: cacheKey) {
            return cached
        }
        let size = template.size
        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        if let cacheKey {
            tintedIconCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    private func applyColors() {
        appliedAppearanceName = effectiveAppearance.name
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            let baseColor: NSColor = switch badge.kind {
            case .localBranch, .remoteBranch: laneColor ?? .systemGray
            case .tag: .systemBrown
            case .head: .systemRed
            }

            // Opaque pastel fill (like Fork) so the chip stays legible even when the row is
            // highlighted with the strong blue selection color.
            let bgColor: NSColor
            let fgColor: NSColor
            let borderColor: NSColor

            if isDark {
                let darkBase = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
                bgColor = darkBase.blended(withFraction: badge.isCurrent ? 0.35 : 0.25, of: baseColor) ?? darkBase
                // The current branch's chip text is noticeably brighter than other chips'.
                fgColor = baseColor.blended(withFraction: badge.isCurrent ? 0.8 : 0.45, of: .white) ?? baseColor
                borderColor = baseColor.blended(withFraction: 0.25, of: .white) ?? baseColor
            } else {
                bgColor = NSColor.white.blended(withFraction: badge.isCurrent ? 0.22 : 0.14, of: baseColor) ?? .white
                fgColor = baseColor.blended(withFraction: 0.45, of: .black) ?? baseColor
                borderColor = baseColor.withAlphaComponent(badge.isCurrent ? 0.85 : 0.55)
            }

            layer?.backgroundColor = bgColor.cgColor
            layer?.borderColor = borderColor.cgColor
            label.textColor = fgColor
            // Pre-tint instead of relying on a template image: a selected row would otherwise
            // recolour template icons, washing them out against the selection highlight.
            if let templateIcon, let templateIconKey {
                iconView.image = Self.tinted(templateIcon, key: templateIconKey, with: fgColor)
            } else {
                iconView.image = nil
            }
            divider.layer?.backgroundColor = borderColor.withAlphaComponent(0.6).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

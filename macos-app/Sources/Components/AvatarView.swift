import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Extracts up to two uppercase initials from an author name, falling back to `"?"`.
enum AvatarInitials {
    static func from(_ name: String) -> String {
        let text = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return text.isEmpty ? "?" : text
    }
}

/// Resolves and caches author avatars. GitHub noreply addresses map to the GitHub
/// avatar of that user; everything else goes through Gravatar using a SHA-256 hash
/// of the address (the address itself is never sent). An address with no avatar gets the
/// GitHub mark; if the lookup itself fails (offline, rate-limited) initials are shown and
/// the lookup is retried after a minute.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private enum Lookup: Sendable {
        case found(CGImage)
        case notFound
        case failed
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]

    nonisolated static func normalizedKey(for email: String) -> String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Returns the avatar synchronously when it is already known or cached in memory,
    /// avoiding an async hop (and placeholder flash) when table cells are recycled.
    func cachedImage(for email: String) -> NSImage? {
        let key = Self.normalizedKey(for: email)
        guard !key.isEmpty else { return nil }
        if let sender = KnownSender(email: key) { return sender.tile }
        return cache.object(forKey: key as NSString)
    }

    func image(for email: String) async -> NSImage? {
        let key = Self.normalizedKey(for: email)
        guard !key.isEmpty else { return nil }
        if let sender = KnownSender(email: key) { return sender.tile }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        if let task = inFlight[key] { return resolve(await task.value, key: key) }

        let task = Task.detached(priority: .utility) { () -> Lookup in
            guard let url = Self.avatarURL(for: key) else { return .notFound }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { return .failed }
            switch status {
            case 200:
                return Self.decodedImage(from: data).map(Lookup.found) ?? .notFound
            case 404:
                return .notFound
            default:
                return .failed
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return resolve(result, key: key)
    }

    private func resolve(_ lookup: Lookup, key: String) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        switch lookup {
        case let .found(cgImage):
            failedAt.removeValue(forKey: key)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key as NSString)
            return image
        case .notFound:
            failedAt.removeValue(forKey: key)
            // No avatar exists for this address: fall back to the GitHub mark.
            let tile = KnownSender.github.tile
            cache.setObject(tile, forKey: key as NSString)
            return tile
        case .failed:
            failedAt[key] = Date()
            return nil
        }
    }

    /// Eagerly decodes and downsamples avatar bytes off the main thread so Core Animation
    /// does not stall decoding PNG/JPEG data during scrolling.
    nonisolated static func decodedImage(from data: Data, maxPixelSize: Int = 96) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return thumbnail
        }
        let imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary)
    }

    nonisolated static func avatarURL(for email: String) -> URL? {
        let suffix = "@users.noreply.github.com"
        if email.hasSuffix(suffix) {
            var user = String(email.dropLast(suffix.count))
            if let plus = user.firstIndex(of: "+") { user = String(user[user.index(after: plus)...]) }
            return URL(string: "https://github.com/\(user).png?size=120")
        }
        if email == "noreply@github.com" { return nil }
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=120&d=404")
    }
}

/// Rounded-square avatar with an initials fallback for SwiftUI views.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 36

    @AppStorage(showAvatarsStorageKey) private var showAvatars = true
    @State private var loaded: (email: String, image: NSImage)?

    var body: some View {
        let key = AvatarLoader.normalizedKey(for: email)
        let displayedImage: NSImage? = if showAvatars, !key.isEmpty {
            AvatarLoader.shared.cachedImage(for: key)
                ?? (loaded?.email == key ? loaded?.image : nil)
        } else {
            nil
        }
        ZStack {
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                Text(AvatarInitials.from(name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: "\(key)|\(showAvatars)") {
            guard showAvatars, !key.isEmpty else {
                loaded = nil
                return
            }
            if let cached = AvatarLoader.shared.cachedImage(for: key) {
                loaded = (key, cached)
                return
            }
            loaded = nil
            let fetched = await AvatarLoader.shared.image(for: key)
            guard !Task.isCancelled else { return }
            loaded = fetched.map { (key, $0) }
        }
    }
}

/// Small rounded-square author avatar for AppKit cells: the fetched image when there is
/// one, otherwise the author's initials on a grey tile. Shares `AvatarLoader`'s cache.
final class AvatarImageView: NSView {
    private let imageView = NSImageView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private var email = ""
    private var loadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        initialsLabel.textColor = .secondaryLabelColor
        initialsLabel.alignment = .center
        addSubview(imageView)
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    deinit {
        loadTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Whether the view is currently displaying an avatar image (rather than initials).
    var hasLoadedImage: Bool {
        !imageView.isHidden && imageView.image != nil
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        email = ""
        imageView.image = nil
        imageView.isHidden = true
        initialsLabel.stringValue = ""
        initialsLabel.isHidden = true
    }

    func configure(name: String, email: String) {
        let showAvatars = UserDefaults.standard.object(forKey: showAvatarsStorageKey) as? Bool ?? true
        let key = AvatarLoader.normalizedKey(for: email)

        // Reuse the existing image in place when the recycled cell belongs to the same author.
        if showAvatars, !key.isEmpty, self.email == key, imageView.image != nil, !imageView.isHidden {
            return
        }

        loadTask?.cancel()
        loadTask = nil
        self.email = key

        if showAvatars, !key.isEmpty, let cached = AvatarLoader.shared.cachedImage(for: key) {
            if imageView.image !== cached {
                imageView.image = cached
            }
            imageView.isHidden = false
            initialsLabel.isHidden = true
            return
        }

        initialsLabel.stringValue = AvatarInitials.from(name)
        imageView.image = nil
        imageView.isHidden = true
        initialsLabel.isHidden = false

        guard showAvatars, !key.isEmpty else { return }
        loadTask = Task { @MainActor [weak self] in
            let image = await AvatarLoader.shared.image(for: key)
            // The cell may have been reused for another commit while the image loaded.
            guard !Task.isCancelled, let self, self.email == key, let image else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.initialsLabel.isHidden = true
        }
    }
}

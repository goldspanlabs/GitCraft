import AppKit
import CryptoKit
import SwiftUI

/// UserDefaults key for the "show avatars" preference (Settings ▸ General).
let showAvatarsStorageKey = "showAvatars"

/// Resolves and caches author avatars. GitHub noreply addresses map to the GitHub
/// avatar of that user; everything else goes through Gravatar using a SHA-256 hash
/// of the address (the address itself is never sent). An address with no avatar gets the
/// GitHub mark; if the lookup itself fails (offline, rate-limited) initials are shown and
/// the lookup is retried after a minute.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private enum Lookup {
        case found(NSImage)
        case notFound
        case failed
    }

    private let cache = NSCache<NSString, NSImage>()
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]

    func image(for email: String) async -> NSImage? {
        let key = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let sender = KnownSender(email: key) { return sender.tile }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        if let task = inFlight[key] { return await resolve(await task.value, key: key) }

        let task = Task<Lookup, Never> {
            guard let url = Self.avatarURL(for: key) else { return .notFound }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { return .failed }
            switch status {
            case 200:
                return NSImage(data: data).map(Lookup.found) ?? .notFound
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
        switch lookup {
        case let .found(image):
            cache.setObject(image, forKey: key as NSString)
            return image
        case .notFound:
            // No avatar exists for this address: fall back to the GitHub mark.
            let tile = KnownSender.github.tile
            cache.setObject(tile, forKey: key as NSString)
            return tile
        case .failed:
            failedAt[key] = Date()
            return nil
        }
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

/// Rounded-square avatar with an initials fallback.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 36

    @AppStorage(showAvatarsStorageKey) private var showAvatars = true
    @State private var image: NSImage?

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        let text = String(parts).uppercased()
        return text.isEmpty ? "?" : text
    }

    var body: some View {
        ZStack {
            if let image, showAvatars {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: "\(email)|\(showAvatars)") {
            guard showAvatars, !email.isEmpty else { image = nil; return }
            image = await AvatarLoader.shared.image(for: email)
        }
    }
}

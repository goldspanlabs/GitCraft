import Foundation

/// A dotted numeric version such as `1.10.2`, optionally prefixed with `v`.
struct SemanticVersion: Comparable {
    /// Trailing zeros are dropped, so `1.0` and `1.0.0` are equal.
    private let components: [Int]

    /// Nil for anything but digits separated by dots, including pre-release suffixes.
    init?(_ text: String) {
        var text = Substring(text)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        var numbers: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        while numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// A published release the person could upgrade to.
struct AppUpdate: Codable, Equatable {
    /// Without the leading `v`.
    let version: String
    let releasePageURL: URL
    let dmgURL: URL?

    var downloadURL: URL { dmgURL ?? releasePageURL }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }

        let tagName: String
        let htmlUrl: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// Reads GitHub's "latest release" response. Nil for a release that shouldn't be offered
    /// (draft, pre-release, unreadable tag); throws if the response isn't a release at all.
    static func decodeLatestRelease(_ data: Data) throws -> AppUpdate? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              SemanticVersion(release.tagName) != nil,
              let page = webURL(release.htmlUrl)
        else { return nil }
        let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return AppUpdate(
            version: String(release.tagName.drop { $0 == "v" || $0 == "V" }),
            releasePageURL: page,
            dmgURL: dmg.flatMap { webURL($0.browserDownloadUrl) }
        )
    }

    /// These links are handed to the system to open, so only `https` is accepted.
    private static func webURL(_ text: String) -> URL? {
        URL(string: text).flatMap { $0.scheme == "https" ? $0 : nil }
    }
}

/// How the running app got onto this Mac, which decides how it should be upgraded.
enum InstallType: Equatable {
    case homebrew
    /// A DMG download, a local build, or anything else.
    case direct

    static let homebrewUpgradeCommand = "brew upgrade --cask gitcraft"
    static let standardCaskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    /// The app is a Homebrew install if its real location is inside a Caskroom, or if a
    /// Caskroom entry links to it. The second is what `brew install --cask` produces: the app
    /// is moved to /Applications and a symlink to it is left in the Caskroom.
    static func detect(bundlePath: String, caskrooms: [String] = standardCaskrooms) -> InstallType {
        let bundle = resolved(bundlePath)
        for caskroom in caskrooms {
            if bundle.hasPrefix(resolved(caskroom) + "/") { return .homebrew }

            let cask = URL(fileURLWithPath: caskroom).appendingPathComponent("gitcraft")
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: cask.path)) ?? []
            for version in versions {
                let entry = cask.appendingPathComponent(version).appendingPathComponent("GitCraft.app").path
                if resolved(entry) == bundle { return .homebrew }
            }
        }
        return .direct
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Asks GitHub whether a newer GitCraft has been released. It only reports what it finds;
/// downloading and installing are left to the person.
@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Outcome: Equatable {
        case updateAvailable(AppUpdate)
        case upToDate
        /// Builds without a version number (such as `swift run`) have nothing to compare.
        case unknownCurrentVersion
        case failed(String)
    }

    nonisolated static let automaticChecksKey = "checkForUpdatesAutomatically"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let foundUpdateKey = "foundUpdate"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/goldspanlabs/gitcraft/releases/latest")!

    static let shared = UpdateChecker(
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    )

    /// The release to advertise in the window banner, if any.
    @Published private(set) var availableUpdate: AppUpdate?

    private let currentVersion: SemanticVersion?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: Fetch
    /// Checks can overlap (a slow launch check and a manual one). Each is numbered when it
    /// starts, so an answer older than one already used can be thrown away.
    private var checksStarted = 0
    private var newestAnswered = 0

    init(
        currentVersion: String?,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
    ) {
        self.currentVersion = currentVersion.flatMap(SemanticVersion.init)
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    /// On unless turned off. Read with `bool(forKey:)`, which also understands the string a
    /// launch argument supplies.
    private var checksAutomatically: Bool {
        defaults.object(forKey: Self.automaticChecksKey) == nil || defaults.bool(forKey: Self.automaticChecksKey)
    }

    /// The launch-time check: honors the setting and skipped version, asks GitHub at most once
    /// a day, and says nothing if it fails.
    func checkAutomatically() async {
        guard checksAutomatically, currentVersion != nil else { return }
        if let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date {
            let age = now().timeIntervalSince(lastCheck)
            // A timestamp in the future means the clock was moved back; don't wait for it.
            if age >= 0, age < Self.checkInterval {
                // Keep advertising what the last check found.
                offerUnlessSkipped(rememberedUpdate())
                return
            }
        }
        let check = startCheck()
        do {
            let update = try await latestNewerRelease()
            guard use(update, from: check) else { return }
            offerUnlessSkipped(update)
        } catch {
            guard check > newestAnswered else { return }
            offerUnlessSkipped(rememberedUpdate())
        }
    }

    /// "Check for Updates…": always asks GitHub, includes a skipped version, and reports errors.
    func checkManually() async -> Outcome {
        guard currentVersion != nil else { return .unknownCurrentVersion }
        let check = startCheck()
        do {
            let update = try await latestNewerRelease()
            if use(update, from: check) { availableUpdate = update }
            return update.map(Outcome.updateAvailable) ?? .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func skip(_ update: AppUpdate) {
        defaults.set(update.version, forKey: Self.skippedVersionKey)
        availableUpdate = nil
    }

    /// Hides the banner until the next launch.
    func dismiss() {
        availableUpdate = nil
    }

    private struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { "GitHub answered with HTTP status \(status)." }
    }

    private func startCheck() -> Int {
        checksStarted += 1
        return checksStarted
    }

    /// Remembers what `check` found, unless a later check has already answered.
    private func use(_ update: AppUpdate?, from check: Int) -> Bool {
        guard check > newestAnswered else { return false }
        newestAnswered = check
        defaults.set(update.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.foundUpdateKey)
        return true
    }

    private func latestNewerRelease() async throws -> AppUpdate? {
        // Recorded before the request, so a failing check is also limited to once a day.
        defaults.set(now(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw HTTPError(status: status)
        }
        return try AppUpdate.decodeLatestRelease(data).flatMap { isNewer($0) ? $0 : nil }
    }

    private func rememberedUpdate() -> AppUpdate? {
        defaults.data(forKey: Self.foundUpdateKey)
            .flatMap { try? JSONDecoder().decode(AppUpdate.self, from: $0) }
            .flatMap { isNewer($0) ? $0 : nil }
    }

    private func isNewer(_ update: AppUpdate) -> Bool {
        guard let currentVersion, let version = SemanticVersion(update.version) else { return false }
        return version > currentVersion
    }

    private func offerUnlessSkipped(_ update: AppUpdate?) {
        let skipped = defaults.string(forKey: Self.skippedVersionKey)
        availableUpdate = update?.version == skipped ? nil : update
    }
}

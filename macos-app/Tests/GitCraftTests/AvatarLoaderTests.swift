import AppKit
import XCTest
@testable import GitCraft

final class AvatarLoaderTests: XCTestCase {
    @MainActor
    func testCachedImageReturnsKnownSendersSynchronously() {
        XCTAssertNotNil(AvatarLoader.shared.cachedImage(for: "noreply@github.com"))
        XCTAssertNotNil(AvatarLoader.shared.cachedImage(for: " NoReply@Anthropic.com "))
        XCTAssertNil(AvatarLoader.shared.cachedImage(for: ""))
        XCTAssertNil(AvatarLoader.shared.cachedImage(for: "   "))
        XCTAssertNil(AvatarLoader.shared.cachedImage(for: "uncached-avatar-test@example.com"))
    }

    func testDecodedImageDownsamplesAndRejectsInvalidData() throws {
        XCTAssertNil(AvatarLoader.decodedImage(from: Data("not an image".utf8)))

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 200,
                pixelsHigh: 200,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(AvatarLoader.decodedImage(from: pngData, maxPixelSize: 64))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 64)
    }

    @MainActor
    func testAvatarImageViewRendersKnownSenderSynchronouslyAndHandlesReuse() {
        let previous = UserDefaults.standard.object(forKey: showAvatarsStorageKey)
        UserDefaults.standard.set(true, forKey: showAvatarsStorageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: showAvatarsStorageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: showAvatarsStorageKey)
            }
        }

        let view = AvatarImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        view.configure(name: "GitHub", email: "noreply@github.com")
        XCTAssertTrue(view.hasLoadedImage)

        // Same author with different casing/whitespace reuses the existing image in place.
        view.configure(name: "GitHub", email: " NoReply@GitHub.com ")
        XCTAssertTrue(view.hasLoadedImage)

        // Switching to an uncached email falls back to initials immediately.
        view.configure(name: "Ada Lovelace", email: "uncached-reuse-test@example.com")
        XCTAssertFalse(view.hasLoadedImage)

        // Disabling avatars hides even known-sender images.
        UserDefaults.standard.set(false, forKey: showAvatarsStorageKey)
        view.configure(name: "GitHub", email: "noreply@github.com")
        XCTAssertFalse(view.hasLoadedImage)

        view.clear()
        XCTAssertFalse(view.hasLoadedImage)
    }

    @MainActor
    func testRefPillViewReusesCachedTintedIconsForSFSymbols() throws {
        let currentBranch = RefBadge(name: "main", kind: .localBranch, isCurrent: true)
        let check1 = RefPillView(badge: currentBranch, laneColor: .systemBlue)
        let check2 = RefPillView(badge: currentBranch, laneColor: .systemBlue)
        let checkIcon1 = try XCTUnwrap(check1.displayedIconImage)
        let checkIcon2 = try XCTUnwrap(check2.displayedIconImage)
        XCTAssertTrue(checkIcon1 === checkIcon2)

        let remoteBranch = RefBadge(name: "origin/main", kind: .remoteBranch, isCurrent: false)
        let cloud1 = RefPillView(badge: remoteBranch, host: .other, laneColor: .systemBlue)
        let cloud2 = RefPillView(badge: remoteBranch, host: .other, laneColor: .systemBlue)
        let cloudIcon1 = try XCTUnwrap(cloud1.displayedIconImage)
        let cloudIcon2 = try XCTUnwrap(cloud2.displayedIconImage)
        XCTAssertTrue(cloudIcon1 === cloudIcon2)
    }
    func testInitialsUseFirstTwoWordsAndFallBackToQuestionMark() {
        XCTAssertEqual(AvatarInitials.from("Ada Lovelace"), "AL")
        XCTAssertEqual(AvatarInitials.from("ada byron lovelace"), "AB")
        XCTAssertEqual(AvatarInitials.from("madonna"), "M")
        XCTAssertEqual(AvatarInitials.from(""), "?")
        XCTAssertEqual(AvatarInitials.from("   "), "?")
    }

    func testNormalizedKeyTrimsWhitespaceAndLowercases() {
        XCTAssertEqual(AvatarLoader.normalizedKey(for: "  Foo@Example.COM "), "foo@example.com")
        XCTAssertEqual(AvatarLoader.normalizedKey(for: "   "), "")
    }

    func testAvatarURLMapsGitHubNoreplyAddressesToGitHubAvatars() {
        XCTAssertEqual(
            AvatarLoader.avatarURL(for: "octocat@users.noreply.github.com")?.absoluteString,
            "https://github.com/octocat.png?size=120"
        )
        XCTAssertEqual(
            AvatarLoader.avatarURL(for: "12345+octocat@users.noreply.github.com")?.absoluteString,
            "https://github.com/octocat.png?size=120"
        )
        XCTAssertNil(AvatarLoader.avatarURL(for: "noreply@github.com"))
    }

    func testAvatarURLRejectsNoreplyNamesThatAreNotGitHubLogins() {
        for email in [
            "a/../../settings@users.noreply.github.com",
            "name?size=1#@users.noreply.github.com",
            "49699333+dependabot[bot]@users.noreply.github.com",
            "-leading@users.noreply.github.com",
            "trailing-@users.noreply.github.com",
            "a--b@users.noreply.github.com",
            "@users.noreply.github.com",
        ] {
            XCTAssertNil(AvatarLoader.avatarURL(for: email), email)
        }
        XCTAssertNotNil(AvatarLoader.avatarURL(for: "a-b-9@users.noreply.github.com"))
    }

    func testAvatarsAreOffUntilThePersonTurnsThemOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "gitcraft-avatar-pref-\(UUID().uuidString)"))
        XCTAssertFalse(AvatarPreference.isEnabled(defaults))

        defaults.set(true, forKey: showAvatarsStorageKey)
        XCTAssertTrue(AvatarPreference.isEnabled(defaults))

        defaults.set(false, forKey: showAvatarsStorageKey)
        XCTAssertFalse(AvatarPreference.isEnabled(defaults))
    }

    @MainActor
    func testAvatarImageViewIsHiddenWhileAvatarsAreOff() {
        let previous = UserDefaults.standard.object(forKey: showAvatarsStorageKey)
        UserDefaults.standard.set(false, forKey: showAvatarsStorageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: showAvatarsStorageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: showAvatarsStorageKey)
            }
        }

        let view = AvatarImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        view.isHidden = false
        view.configure(name: "Ada Lovelace", email: "ada@example.com")
        XCTAssertTrue(view.isHidden)
        view.isHidden = false
        view.configure(name: "GitHub", email: "noreply@github.com")
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.hasLoadedImage)
    }

    func testAvatarURLUsesHashedGravatarWithoutLeakingTheAddress() throws {
        let url = try XCTUnwrap(AvatarLoader.avatarURL(for: "someone@example.com"))
        XCTAssertEqual(url.host, "www.gravatar.com")
        XCTAssertFalse(url.absoluteString.contains("someone"))
        XCTAssertEqual(url.lastPathComponent.count, 64)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value, "404")
        XCTAssertEqual(url, AvatarLoader.avatarURL(for: "someone@example.com"))
    }
    // MARK: - Faked network

    private static func pngData() throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private static func response(_ status: Int, for request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @MainActor
    func testFetchedAvatarIsCachedAndServedSynchronouslyAfterwards() async throws {
        let png = try Self.pngData()
        let counter = FetchCounter()
        let loader = AvatarLoader(fetch: { request in
            counter.increment()
            return (png, Self.response(200, for: request))
        })
        let email = "fetch-ok@example.com"

        XCTAssertNil(loader.cachedImage(for: email))
        let fetched = await loader.image(for: email)
        let first = try XCTUnwrap(fetched)
        // The 8x8 fixture, not the GitHub fallback tile a failed decode would produce.
        XCTAssertEqual(first.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(loader.cachedImage(for: " FETCH-OK@example.com ")?.size, NSSize(width: 8, height: 8))
        _ = await loader.image(for: email)
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testConcurrentRequestsForTheSameAddressShareOneFetch() async throws {
        let png = try Self.pngData()
        let counter = FetchCounter()
        let loader = AvatarLoader(fetch: { request in
            counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return (png, Self.response(200, for: request))
        })
        async let a = loader.image(for: "shared@example.com")
        async let b = loader.image(for: "shared@example.com")
        let (imageA, imageB) = await (a, b)
        XCTAssertEqual(imageA?.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(imageB?.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testNotFoundFallsBackToGitHubMarkAndIsCached() async {
        let counter = FetchCounter()
        let loader = AvatarLoader(fetch: { request in
            counter.increment()
            return (Data(), Self.response(404, for: request))
        })
        let image = await loader.image(for: "no-avatar@example.com")
        XCTAssertNotNil(image)
        XCTAssertNotNil(loader.cachedImage(for: "no-avatar@example.com"))
        _ = await loader.image(for: "no-avatar@example.com")
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testFailedLookupReturnsNilThenRetriesAfterAMinute() async throws {
        let png = try Self.pngData()
        let counter = FetchCounter()
        var clock = Date(timeIntervalSince1970: 1_000)
        let loader = AvatarLoader(
            fetch: { request in
                counter.increment()
                if counter.count == 1 { throw URLError(.notConnectedToInternet) }
                return (png, Self.response(200, for: request))
            },
            now: { clock }
        )
        let email = "flaky@example.com"

        let failed = await loader.image(for: email)
        XCTAssertNil(failed)
        XCTAssertNil(loader.cachedImage(for: email))

        clock.addTimeInterval(30)
        let stillBackedOff = await loader.image(for: email)
        XCTAssertNil(stillBackedOff)
        XCTAssertEqual(counter.count, 1)

        clock.addTimeInterval(31)
        let retried = await loader.image(for: email)
        XCTAssertEqual(retried?.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(counter.count, 2)
    }

    @MainActor
    func testServerErrorIsTreatedAsFailureNotAsMissingAvatar() async {
        let loader = AvatarLoader(fetch: { request in
            (Data(), Self.response(500, for: request))
        })
        let image = await loader.image(for: "server-error@example.com")
        XCTAssertNil(image)
        XCTAssertNil(loader.cachedImage(for: "server-error@example.com"))
    }

    @MainActor
    func testGitHubMarkAddressNeverHitsTheNetwork() async {
        let counter = FetchCounter()
        let loader = AvatarLoader(fetch: { request in
            counter.increment()
            return (Data(), Self.response(200, for: request))
        })
        let image = await loader.image(for: "noreply@github.com")
        XCTAssertNotNil(image)
        XCTAssertEqual(counter.count, 0)
    }
}

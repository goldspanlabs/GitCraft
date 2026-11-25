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

    func testAvatarURLUsesHashedGravatarWithoutLeakingTheAddress() throws {
        let url = try XCTUnwrap(AvatarLoader.avatarURL(for: "someone@example.com"))
        XCTAssertEqual(url.host, "www.gravatar.com")
        XCTAssertFalse(url.absoluteString.contains("someone"))
        XCTAssertEqual(url.lastPathComponent.count, 64)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value, "404")
        XCTAssertEqual(url, AvatarLoader.avatarURL(for: "someone@example.com"))
    }
}

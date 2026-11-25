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
    func testAvatarImageViewRendersKnownSenderSynchronously() {
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

        view.clear()
        XCTAssertFalse(view.hasLoadedImage)
    }
}

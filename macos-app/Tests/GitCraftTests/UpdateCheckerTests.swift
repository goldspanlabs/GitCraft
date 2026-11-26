import Foundation
import XCTest
@testable import GitCraft

final class SemanticVersionTests: XCTestCase {
    private func version(_ text: String) throws -> SemanticVersion {
        try XCTUnwrap(SemanticVersion(text), "\(text) should parse")
    }

    func testLeadingVIsIgnored() throws {
        XCTAssertEqual(try version("v1.2.3"), try version("1.2.3"))
        XCTAssertEqual(try version("V1.2.3"), try version("1.2.3"))
    }

    func testComponentsCompareNumerically() throws {
        XCTAssertLessThan(try version("1.9"), try version("1.10"))
        XCTAssertLessThan(try version("1.9.9"), try version("2.0.0"))
        XCTAssertFalse(try version("1.10") < version("1.9"))
    }

    func testMissingComponentsCountAsZero() throws {
        XCTAssertEqual(try version("1.0"), try version("1.0.0"))
        XCTAssertEqual(try version("2"), try version("2.0.0"))
        XCTAssertLessThan(try version("1.0"), try version("1.0.1"))
        XCTAssertFalse(try version("1.0.0") < version("1.0"))
    }

    func testUnparseableTextIsRejected() {
        for text in ["", "v", "abc", "1..2", "1.2.", ".1", "1.2-beta", "1.2.3+4", "-1.0", "+1.0", " 1.0", "vv1.0",
                     "1.99999999999999999999"]
        {
            XCTAssertNil(SemanticVersion(text), "\(text) should not parse")
        }
    }
}

private func releaseJSON(
    tag: String = "v1.2.0",
    draft: Bool = false,
    prerelease: Bool = false,
    page: String = "https://github.com/goldspanlabs/gitcraft/releases/tag/v1.2.0",
    assets: [(name: String, url: String)] = [
        ("GitCraft-v1.2.0.dmg", "https://github.com/goldspanlabs/gitcraft/releases/download/v1.2.0/GitCraft-v1.2.0.dmg"),
    ]
) -> Data {
    let object: [String: Any] = [
        "tag_name": tag,
        "html_url": page,
        "draft": draft,
        "prerelease": prerelease,
        "body": "Notes",
        "assets": assets.map { ["name": $0.name, "browser_download_url": $0.url, "size": 1] },
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

final class ReleaseDecodingTests: XCTestCase {
    func testDecodesVersionPageAndDMG() throws {
        let update = try XCTUnwrap(AppUpdate.decodeLatestRelease(releaseJSON()))
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.releasePageURL.absoluteString, "https://github.com/goldspanlabs/gitcraft/releases/tag/v1.2.0")
        XCTAssertEqual(update.dmgURL?.lastPathComponent, "GitCraft-v1.2.0.dmg")
        XCTAssertEqual(update.downloadURL, update.dmgURL)
    }

    func testPicksTheDMGAmongOtherAssets() throws {
        let data = releaseJSON(assets: [
            ("checksums.txt", "https://example.com/checksums.txt"),
            ("GitCraft.DMG", "https://example.com/GitCraft.DMG"),
        ])
        let update = try XCTUnwrap(AppUpdate.decodeLatestRelease(data))
        XCTAssertEqual(update.dmgURL?.absoluteString, "https://example.com/GitCraft.DMG")
    }

    func testDraftsAndPrereleasesAreIgnored() throws {
        XCTAssertNil(try AppUpdate.decodeLatestRelease(releaseJSON(draft: true)))
        XCTAssertNil(try AppUpdate.decodeLatestRelease(releaseJSON(prerelease: true)))
    }

    func testMissingDMGFallsBackToTheReleasePage() throws {
        let update = try XCTUnwrap(AppUpdate.decodeLatestRelease(releaseJSON(assets: [])))
        XCTAssertNil(update.dmgURL)
        XCTAssertEqual(update.downloadURL, update.releasePageURL)
    }

    func testUnparseableTagIsNoUpdate() throws {
        XCTAssertNil(try AppUpdate.decodeLatestRelease(releaseJSON(tag: "nightly")))
    }

    func testNonHTTPSLinksAreNeverOpened() throws {
        XCTAssertNil(try AppUpdate.decodeLatestRelease(releaseJSON(page: "file:///Applications")))
        let data = releaseJSON(assets: [("GitCraft.dmg", "http://example.com/GitCraft.dmg")])
        XCTAssertNil(try XCTUnwrap(AppUpdate.decodeLatestRelease(data)).dmgURL)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try AppUpdate.decodeLatestRelease(Data("{\"message\":\"rate limited\"}".utf8)))
        XCTAssertThrowsError(try AppUpdate.decodeLatestRelease(Data("<html>".utf8)))
    }
}

/// Stands in for GitHub: returns a canned response and counts requests.
private actor FakeGitHub {
    private(set) var requests: [URLRequest] = []
    private var result: Result<(Data, Int), URLError>

    init(_ data: Data = releaseJSON(), status: Int = 200) {
        result = .success((data, status))
    }

    func respond(with data: Data, status: Int = 200) { result = .success((data, status)) }
    func fail() { result = .failure(URLError(.notConnectedToInternet)) }

    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let (data, status) = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let clock = FakeClock()

    override func setUp() async throws {
        suiteName = "gitcraft-update-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeChecker(_ github: FakeGitHub, version: String? = "1.0.1") -> UpdateChecker {
        let clock = clock
        return UpdateChecker(
            currentVersion: version,
            defaults: defaults,
            now: { clock.now },
            fetch: { try await github.fetch($0) }
        )
    }

    func testAutomaticCheckOffersANewerRelease() async {
        let github = FakeGitHub()
        let checker = makeChecker(github)

        await checker.checkAutomatically()

        XCTAssertEqual(checker.availableUpdate?.version, "1.2.0")
        let requests = await github.requests
        XCTAssertEqual(
            requests.map { $0.url?.absoluteString },
            ["https://api.github.com/repos/goldspanlabs/gitcraft/releases/latest"]
        )
    }

    func testSameOrOlderReleaseIsNotOffered() async {
        for current in ["1.2.0", "1.2", "1.3.0"] {
            defaults.removePersistentDomain(forName: suiteName)
            let checker = makeChecker(FakeGitHub(), version: current)
            let outcome = await checker.checkManually()
            XCTAssertEqual(outcome, .upToDate, "current version \(current)")
            XCTAssertNil(checker.availableUpdate)
        }
    }

    func testMissingOrGarbageVersionSkipsTheCheck() async {
        for current in [nil, "dev"] {
            let github = FakeGitHub()
            let checker = makeChecker(github, version: current)

            await checker.checkAutomatically()
            let outcome = await checker.checkManually()

            XCTAssertEqual(outcome, .unknownCurrentVersion)
            XCTAssertNil(checker.availableUpdate)
            let count = await github.requests.count
            XCTAssertEqual(count, 0)
        }
    }

    func testAutomaticCheckRunsAtMostOncePerDay() async {
        let github = FakeGitHub()

        await makeChecker(github).checkAutomatically()
        clock.now += 24 * 60 * 60 - 1
        await makeChecker(github).checkAutomatically()
        var count = await github.requests.count
        XCTAssertEqual(count, 1)

        clock.now += 1
        await makeChecker(github).checkAutomatically()
        count = await github.requests.count
        XCTAssertEqual(count, 2)
    }

    func testFailedAutomaticCheckIsSilentAndStillThrottled() async {
        let github = FakeGitHub()
        await github.fail()
        let checker = makeChecker(github)

        await checker.checkAutomatically()
        await checker.checkAutomatically()

        XCTAssertNil(checker.availableUpdate)
        let count = await github.requests.count
        XCTAssertEqual(count, 1)
    }

    func testLastCheckInTheFutureDoesNotBlockChecking() async {
        let github = FakeGitHub()
        await makeChecker(github).checkAutomatically()
        clock.now -= 10 * 24 * 60 * 60

        await makeChecker(github).checkAutomatically()

        let count = await github.requests.count
        XCTAssertEqual(count, 2)
    }

    func testManualCheckIgnoresTheThrottle() async {
        let github = FakeGitHub()
        let checker = makeChecker(github)

        await checker.checkAutomatically()
        _ = await checker.checkManually()
        _ = await checker.checkManually()

        let count = await github.requests.count
        XCTAssertEqual(count, 3)
    }

    func testManualCheckReportsFailures() async {
        let github = FakeGitHub()
        await github.fail()
        guard case .failed = await makeChecker(github).checkManually() else {
            return XCTFail("offline should be reported")
        }

        await github.respond(with: Data("{}".utf8), status: 403)
        guard case let .failed(message) = await makeChecker(github).checkManually() else {
            return XCTFail("HTTP errors should be reported")
        }
        XCTAssertTrue(message.contains("403"), message)
    }

    func testTurningAutomaticChecksOffStopsThem() async {
        defaults.set(false, forKey: UpdateChecker.automaticChecksKey)
        let github = FakeGitHub()
        let checker = makeChecker(github)

        await checker.checkAutomatically()
        var count = await github.requests.count
        XCTAssertEqual(count, 0)

        let outcome = await checker.checkManually()
        count = await github.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(outcome, .updateAvailable(try! XCTUnwrap(checker.availableUpdate)))
    }

    func testFoundUpdateIsStillShownOnARelaunchWithinTheDay() async {
        let github = FakeGitHub()
        await makeChecker(github).checkAutomatically()

        let relaunched = makeChecker(github)
        await relaunched.checkAutomatically()

        XCTAssertEqual(relaunched.availableUpdate?.version, "1.2.0")
        let count = await github.requests.count
        XCTAssertEqual(count, 1)
    }

    func testRememberedUpdateIsDroppedOnceInstalled() async {
        let github = FakeGitHub()
        await makeChecker(github).checkAutomatically()

        let upgraded = makeChecker(github, version: "1.2.0")
        await upgraded.checkAutomatically()

        XCTAssertNil(upgraded.availableUpdate)
    }

    func testWithdrawnReleaseClearsTheOffer() async {
        let github = FakeGitHub()
        let checker = makeChecker(github)
        _ = await checker.checkManually()

        await github.respond(with: releaseJSON(tag: "v1.0.1"))
        _ = await checker.checkManually()

        XCTAssertNil(checker.availableUpdate)
        let relaunched = makeChecker(github)
        await relaunched.checkAutomatically()
        XCTAssertNil(relaunched.availableUpdate)
    }

    func testSkippedVersionStaysHiddenFromAutomaticChecks() async throws {
        let github = FakeGitHub()
        let checker = makeChecker(github)
        await checker.checkAutomatically()

        checker.skip(try XCTUnwrap(checker.availableUpdate))
        XCTAssertNil(checker.availableUpdate)

        clock.now += 25 * 60 * 60
        let relaunched = makeChecker(github)
        await relaunched.checkAutomatically()
        XCTAssertNil(relaunched.availableUpdate)
    }

    func testAReleaseNewerThanTheSkippedOneIsOffered() async throws {
        let github = FakeGitHub()
        let checker = makeChecker(github)
        await checker.checkAutomatically()
        checker.skip(try XCTUnwrap(checker.availableUpdate))

        await github.respond(with: releaseJSON(tag: "v1.3.0"))
        clock.now += 25 * 60 * 60
        await checker.checkAutomatically()

        XCTAssertEqual(checker.availableUpdate?.version, "1.3.0")
    }

    func testManualCheckStillReportsASkippedVersion() async throws {
        let checker = makeChecker(FakeGitHub())
        await checker.checkAutomatically()
        checker.skip(try XCTUnwrap(checker.availableUpdate))

        let outcome = await checker.checkManually()

        XCTAssertEqual(checker.availableUpdate?.version, "1.2.0")
        XCTAssertEqual(outcome, .updateAvailable(try XCTUnwrap(checker.availableUpdate)))
    }
}

final class InstallTypeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func directory(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func link(_ path: String, to destination: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url.path
    }

    private var caskroom: String { root.appendingPathComponent("Caskroom").path }

    private func detect(_ path: String) -> InstallType {
        InstallType.detect(bundlePath: path, caskrooms: [caskroom])
    }

    func testBundleInsideTheStandardCaskroomsIsHomebrew() {
        for path in [
            "/opt/homebrew/Caskroom/gitcraft/1.0.1/GitCraft.app",
            "/usr/local/Caskroom/gitcraft/1.0.1/GitCraft.app",
        ] {
            XCTAssertEqual(InstallType.detect(bundlePath: path), .homebrew, path)
        }
    }

    func testLookalikeFolderIsNotTheCaskroom() {
        XCTAssertEqual(InstallType.detect(bundlePath: "/opt/homebrew/CaskroomOld/GitCraft.app"), .direct)
        XCTAssertEqual(InstallType.detect(bundlePath: "/Users/someone/Caskroom/GitCraft.app"), .direct)
    }

    func testSymlinkIntoTheCaskroomIsHomebrew() throws {
        let real = try directory("Caskroom/gitcraft/1.0.1/GitCraft.app")
        let app = try link("Applications/GitCraft.app", to: real)
        XCTAssertEqual(detect(app), .homebrew)
    }

    /// What `brew install --cask` does: the app is moved to /Applications and the Caskroom
    /// keeps a symlink pointing back at it.
    func testAppMovedByHomebrewWithACaskroomLinkIsHomebrew() throws {
        let app = try directory("Applications/GitCraft.app")
        _ = try link("Caskroom/gitcraft/1.0.1/GitCraft.app", to: app)
        XCTAssertEqual(detect(app), .homebrew)
    }

    func testManualInstallInApplicationsIsDirect() throws {
        let app = try directory("Applications/GitCraft.app")
        XCTAssertEqual(detect(app), .direct)
    }

    func testAnotherCopyBesideAHomebrewInstallIsDirect() throws {
        let installed = try directory("Applications/GitCraft.app")
        _ = try link("Caskroom/gitcraft/1.0.1/GitCraft.app", to: installed)
        let other = try directory("Downloads/GitCraft.app")
        XCTAssertEqual(detect(other), .direct)
    }
}

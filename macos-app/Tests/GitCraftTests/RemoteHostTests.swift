import XCTest
@testable import GitCraft

final class RemoteHostTests: XCTestCase {
    func testRecognisesCommonHostsFromEveryUrlStyle() {
        let cases: [(String, RemoteHost)] = [
            ("git@github.com:goldspanlabs/GitCraft.git", .github),
            ("https://github.com/goldspanlabs/GitCraft.git", .github),
            ("ssh://git@github.com/goldspanlabs/GitCraft.git", .github),
            ("https://user:token@github.com/org/repo.git", .github),
            ("git@gitlab.com:group/project.git", .gitlab),
            ("https://gitlab.example.com/group/project.git", .gitlab),
            ("git@bitbucket.org:team/repo.git", .bitbucket),
            ("https://codeberg.org/user/repo.git", .codeberg),
            ("https://gitea.com/user/repo.git", .gitea),
            ("git@git.sr.ht:~user/repo", .sourcehut),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(RemoteHost(url: url), expected, url)
        }
    }

    func testUnknownHostsAndLocalPathsFallBackToOther() {
        for url in [
            "https://git.example.com/repo.git",
            "git@internal.corp:team/repo.git",
            "/Users/me/repos/origin.git",
            "file:///tmp/origin.git",
            "https://notgithub.com/x.git",
            "",
        ] {
            XCTAssertEqual(RemoteHost(url: url), .other, url)
        }
    }

    func testEveryHostHasAnIcon() {
        for host in [RemoteHost.github, .gitlab, .bitbucket, .codeberg, .gitea, .sourcehut, .other] {
            XCTAssertNotNil(host.icon, "\(host)")
        }
    }

    func testRemoteURLProtocolDetectionAndConversion() {
        XCTAssertEqual(
            RemoteURLProtocol.detect(from: "https://github.com/goldspanlabs/GitCraft.git"),
            .https
        )
        XCTAssertEqual(
            RemoteURLProtocol.detect(from: "git@github.com:goldspanlabs/GitCraft.git"),
            .ssh
        )
        XCTAssertEqual(
            RemoteURLProtocol.detect(from: "ssh://git@github.com/goldspanlabs/GitCraft.git"),
            .ssh
        )
        XCTAssertNil(RemoteURLProtocol.detect(from: "/tmp/local-bare.git"))

        XCTAssertEqual(
            RemoteURLProtocol.ssh.convert("https://github.com/goldspanlabs/GitCraft.git"),
            "git@github.com:goldspanlabs/GitCraft.git"
        )
        XCTAssertEqual(
            RemoteURLProtocol.https.convert("git@github.com:goldspanlabs/GitCraft.git"),
            "https://github.com/goldspanlabs/GitCraft.git"
        )
        XCTAssertEqual(
            RemoteURLProtocol.https.convert("ssh://git@gitlab.com/team/app.git"),
            "https://gitlab.com/team/app.git"
        )
        XCTAssertNil(RemoteURLProtocol.ssh.convert("/tmp/local-bare.git"))
    }
}

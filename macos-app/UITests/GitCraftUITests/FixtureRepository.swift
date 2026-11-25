import Foundation

/// A throwaway repository on `main` with one commit. Optionally it carries a staged change, so
/// the commit composer has something to commit.
struct FixtureRepository {
    static let linkedBranch = "feature/ui"

    let root: URL
    let mainPath: String

    /// Where `make(linkedWorktree: true)` puts the linked checkout.
    var linkedPath: String { root.appendingPathComponent("repo-ui", isDirectory: true).path }

    /// The untracked file `make(dirtyLinkedWorktree: true)` leaves in the linked checkout.
    var linkedScratchPath: String { (linkedPath as NSString).appendingPathComponent("scratch.txt") }

    static func make(
        stagedChange: Bool = false,
        linkedWorktree: Bool = false,
        dirtyLinkedWorktree: Bool = false
    ) throws -> FixtureRepository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-ui-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        try git(["init", "-b", "main"], in: main)
        try git(["config", "user.name", "GitCraft UI Tests"], in: main)
        try git(["config", "user.email", "ui-tests@gitcraft.local"], in: main)
        let readme = main.appendingPathComponent("README.md")
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: main)
        try git(["commit", "-m", "initial"], in: main)

        if linkedWorktree || dirtyLinkedWorktree {
            let linked = root.appendingPathComponent("repo-ui", isDirectory: true)
            try git(["worktree", "add", "-b", linkedBranch, linked.path], in: main)
            if dirtyLinkedWorktree {
                // An untracked file is enough to make git refuse a plain `worktree remove`.
                try "unsaved work\n".write(
                    to: linked.appendingPathComponent("scratch.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        if stagedChange {
            try "hello, staged\n".write(to: readme, atomically: true, encoding: .utf8)
            try git(["add", "README.md"], in: main)
        }
        return FixtureRepository(root: root, mainPath: main.path)
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(arguments.joined(separator: " "), output)
        }
        return output
    }
}

/// Locates the built app bundle. CI passes it in as GITCRAFT_APP_PATH; locally it falls back to
/// `build/GitCraft.app` at the repository root, which `make` produces.
enum GitCraftApp {
    static func bundleURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["GITCRAFT_APP_PATH"] {
            return URL(fileURLWithPath: path)
        }
        // This file is macos-app/UITests/GitCraftUITests/FixtureRepository.swift.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = repoRoot.appendingPathComponent("build/GitCraft.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw FixtureError.missingApp(app.path)
        }
        return app
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case missingApp(String)
    case gitFailed(String, String)

    var description: String {
        switch self {
        case let .missingApp(path):
            "GitCraft.app not found at \(path). Run `make` first, or set GITCRAFT_APP_PATH."
        case let .gitFailed(command, output):
            "git \(command) failed: \(output)"
        }
    }
}

import Foundation

/// A throwaway repository on `main` with one commit. Optionally it carries a staged change, so
/// the commit composer has something to commit.
struct FixtureRepository {
    static let linkedBranch = "feature/ui"
    /// The branch `make(twoBranches: true)` creates next to `main`.
    static let featureBranch = "feature"
    /// The branch `make(mergedBranch: true)` creates. It needs `twoBranches`, which gives main a
    /// second commit, and points at "initial".
    static let mergedBranchName = "old-work"

    let root: URL
    let mainPath: String

    /// Where `make(linkedWorktree: true)` puts the linked checkout.
    var linkedPath: String { root.appendingPathComponent("repo-ui", isDirectory: true).path }

    /// The untracked file `make(dirtyLinkedWorktree: true)` leaves in the linked checkout.
    var linkedScratchPath: String { (linkedPath as NSString).appendingPathComponent("scratch.txt") }

    static func make(
        stagedChange: Bool = false,
        linkedWorktree: Bool = false,
        dirtyLinkedWorktree: Bool = false,
        twoBranches: Bool = false,
        mergedBranch: Bool = false,
        unstagedFiles: [String] = []
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

        if twoBranches {
            // `feature` and `main` each get one commit on top of "initial", touching different
            // files, so merging or rebasing either way is conflict-free.
            try git(["switch", "-c", featureBranch], in: main)
            try "feature\n".write(to: main.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
            try git(["add", "feature.txt"], in: main)
            try git(["commit", "-m", "feature work"], in: main)
            try git(["switch", "main"], in: main)
            try "main\n".write(to: main.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
            try git(["add", "main.txt"], in: main)
            try git(["commit", "-m", "main work"], in: main)
        }

        if mergedBranch {
            // Points at "initial", which main already contains, so a plain delete succeeds.
            try git(["branch", mergedBranchName, "main~1"], in: main)
        }

        for file in unstagedFiles {
            // Each file must already be committed; this leaves an unstaged edit to it.
            let url = main.appendingPathComponent(file)
            let edited = try String(contentsOf: url, encoding: .utf8) + "edited\n"
            try edited.write(to: url, atomically: true, encoding: .utf8)
        }

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

    /// Runs git in the main checkout, for tests that check the repository after a UI action.
    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try Self.git(arguments, in: URL(fileURLWithPath: mainPath, isDirectory: true))
    }

    /// The full commit id `ref` points at.
    func commitID(_ ref: String) throws -> String {
        try git(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `file` in the main checkout has uncommitted changes.
    func isModified(_ file: String) throws -> Bool {
        !(try git(["status", "--porcelain", "--", file])).isEmpty
    }

    /// Whether a local branch called `name` exists.
    func hasBranch(_ name: String) throws -> Bool {
        !(try git(["branch", "--list", name])).isEmpty
    }

    /// Whether `ancestor` is reachable from `descendant`.
    func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        (try? git(["merge-base", "--is-ancestor", ancestor, descendant])) != nil
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

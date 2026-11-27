import Foundation

/// A throwaway repository on `main` with one commit. Optionally it carries a staged change, so
/// the commit composer has something to commit.
struct FixtureRepository {
    static let linkedBranch = "feature/ui"
    /// The branch `make(twoBranches: true)` creates next to `main`.
    static let featureBranch = "feature"
    /// The file `make(untrackedFile: true)` leaves in the main checkout without adding it.
    static let untrackedFileName = "notes.txt"

    /// Where `make(conflict:)` leaves git: stopped on a conflict in README.md.
    enum Conflict {
        case merge
        case rebase
        /// Both branches have their conflicting commit, but git hasn't started anything.
        case notStarted
        /// main cherry-picks feature's commit and stops on the conflict.
        case cherryPick
        /// main commits README.md again, then reverting "main edit" stops on the conflict.
        case revert
    }

    /// The branch `make(mergedBranch: true)` creates. It needs `twoBranches`, which gives main a
    /// second commit, and points at "initial".
    static let mergedBranchName = "old-work"

    let root: URL
    let mainPath: String

    /// The bare repository `make(bareRemote: true)` uses as `origin`.
    var remotePath: String { root.appendingPathComponent("origin.git", isDirectory: true).path }

    /// Where `make(linkedWorktree: true)` puts the linked checkout.
    var linkedPath: String { root.appendingPathComponent("repo-ui", isDirectory: true).path }

    /// The untracked file `make(dirtyLinkedWorktree: true)` leaves in the linked checkout.
    var linkedScratchPath: String { (linkedPath as NSString).appendingPathComponent("scratch.txt") }

    static func make(
        stagedChange: Bool = false,
        linkedWorktree: Bool = false,
        dirtyLinkedWorktree: Bool = false,
        lockedLinkedWorktree: Bool = false,
        detachedLinkedWorktree: Bool = false,
        twoBranches: Bool = false,
        featureAhead: Bool = false,
        extraBranches: [String] = [],
        bareRemote: Bool = false,
        mergedBranch: Bool = false,
        unstagedFiles: [String] = [],
        untrackedFile: Bool = false,
        stashes: Bool = false,
        conflict: Conflict? = nil,
        noCommits: Bool = false,
        detachedHead: Bool = false,
        extraCommits: [String] = []
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
        if noCommits {
            // A brand-new repository: an unborn `main` and one untracked file to commit first.
            return FixtureRepository(root: root, mainPath: main.path)
        }
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

        if featureAhead {
            // `feature` is one commit ahead of `main`, so merging it can fast-forward.
            try git(["switch", "-c", featureBranch], in: main)
            try "feature\n".write(to: main.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
            try git(["add", "feature.txt"], in: main)
            try git(["commit", "-m", "feature work"], in: main)
            try git(["switch", "main"], in: main)
        }

        for name in extraCommits {
            // One commit per name on main, each adding its own file.
            try "\(name)\n".write(to: main.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try git(["add", "\(name).txt"], in: main)
            try git(["commit", "-m", name], in: main)
        }

        for branch in extraBranches {
            // Extra branches at main's tip, for tests about how names show in the sidebar.
            try git(["branch", branch], in: main)
        }

        if bareRemote {
            // A bare repository on disk stands in for a server. Every branch is pushed and
            // tracks its copy there.
            let remote = root.appendingPathComponent("origin.git", isDirectory: true)
            try git(["init", "--bare", "-b", "main", remote.path], in: root)
            try git(["remote", "add", "origin", remote.path], in: main)
            try git(["push", "-u", "origin", "--all"], in: main)
        }

        if mergedBranch {
            // Points at "initial", which main already contains, so a plain delete succeeds.
            try git(["branch", mergedBranchName, "main~1"], in: main)
        }

        if let conflict {
            // `feature` and `main` both rewrite README.md's only line, then git stops partway
            // through merging or rebasing, leaving the conflict for the app to show.
            try git(["switch", "-c", featureBranch], in: main)
            try "feature\n".write(to: readme, atomically: true, encoding: .utf8)
            try git(["commit", "-am", "feature edit"], in: main)
            try git(["switch", "main"], in: main)
            try "main\n".write(to: readme, atomically: true, encoding: .utf8)
            try git(["commit", "-am", "main edit"], in: main)
            switch conflict {
            case .merge: try gitExpectingFailure(["merge", featureBranch], in: main)
            case .rebase: try gitExpectingFailure(["rebase", featureBranch], in: main)
            case .notStarted: break
            case .cherryPick: try gitExpectingFailure(["cherry-pick", featureBranch], in: main)
            case .revert:
                try "later\n".write(to: readme, atomically: true, encoding: .utf8)
                try git(["commit", "-am", "later edit"], in: main)
                try gitExpectingFailure(["revert", "--no-edit", "HEAD~1"], in: main)
            }
        }

        if stashes {
            // stash@{1} is "first stash", stash@{0} is "second stash".
            for label in ["first", "second"] {
                try "\(label) stash\n".write(to: readme, atomically: true, encoding: .utf8)
                try git(["stash", "push", "-m", "\(label) stash"], in: main)
            }
        }

        if untrackedFile {
            try "not yet added\n".write(
                to: main.appendingPathComponent(untrackedFileName),
                atomically: true,
                encoding: .utf8
            )
        }

        for file in unstagedFiles {
            // Each file must already be committed; this leaves an unstaged edit to it.
            let url = main.appendingPathComponent(file)
            let edited = try String(contentsOf: url, encoding: .utf8) + "edited\n"
            try edited.write(to: url, atomically: true, encoding: .utf8)
        }

        if linkedWorktree || dirtyLinkedWorktree || lockedLinkedWorktree || detachedLinkedWorktree {
            let linked = root.appendingPathComponent("repo-ui", isDirectory: true)
            if detachedLinkedWorktree {
                // No branch: the linked checkout's HEAD is main's commit, detached.
                try git(["worktree", "add", "--detach", linked.path, "main"], in: main)
            } else {
                try git(["worktree", "add", "-b", linkedBranch, linked.path], in: main)
            }
            if dirtyLinkedWorktree {
                // An untracked file is enough to make git refuse a plain `worktree remove`.
                try "unsaved work\n".write(
                    to: linked.appendingPathComponent("scratch.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            if lockedLinkedWorktree {
                try git(["worktree", "lock", "--reason", "UI test", linked.path], in: main)
            }
        }

        if detachedHead {
            // Check out the commit before main's tip, leaving no branch checked out.
            try git(["switch", "--detach", "main~1"], in: main)
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

    /// The commit `ref` points at in the bare remote, or nil if the remote has no such ref.
    func remoteCommitID(_ ref: String) -> String? {
        (try? git(["--git-dir", remotePath, "rev-parse", "--verify", "--quiet", ref]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `contents` to `file` in the main checkout and commits it on the current branch.
    func commitFile(_ file: String, contents: String, message: String) throws {
        let url = URL(fileURLWithPath: mainPath).appendingPathComponent(file)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try git(["add", file])
        try git(["commit", "-m", message])
    }

    /// The parents of `ref`'s commit, as full ids.
    func parents(of ref: String) throws -> [String] {
        try git(["rev-list", "--parents", "-n", "1", ref])
            .split(whereSeparator: \.isWhitespace)
            .dropFirst()
            .map { String($0) }
    }

    /// The paths staged in the index, relative to the main checkout.
    func stagedFiles() throws -> [String] {
        try git(["diff", "--cached", "--name-only"])
            .split(separator: "\n")
            .map { String($0) }
    }

    /// Whether `path`, relative to the main checkout's `.git` folder, exists.
    func gitDirContains(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(mainPath)/.git/\(path)")
    }

    /// The stash messages, newest first.
    func stashMessages() throws -> [String] {
        try git(["stash", "list", "--format=%s"])
            .split(separator: "\n")
            .map { String($0) }
    }

    /// Runs a git command that is meant to stop with an error, such as a conflicting merge.
    private static func gitExpectingFailure(_ arguments: [String], in directory: URL) throws {
        do {
            try git(arguments, in: directory)
        } catch FixtureError.gitFailed {
            return
        }
        throw FixtureError.gitFailed(arguments.joined(separator: " "), "expected git to stop on a conflict, but it succeeded")
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL, input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Ignore the developer's own git settings (merge.ff, rebase.backend, commit signing and
        // so on), so fixtures come out the same on every machine.
        // Tests poll `git status` while the app works on the same repository. Without
        // GIT_OPTIONAL_LOCKS=0 it locks the index to refresh it, and the app's own command fails.
        process.environment = ProcessInfo.processInfo.environment
            .merging(GitCraftApp.isolatedGitEnvironment) { _, isolated in isolated }
            .merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, ours in ours }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
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
    /// Environment that makes git ignore the machine's own git settings (merge.ff, pull.rebase,
    /// commit signing and so on). The fixture's git commands use it, and tests whose outcome
    /// depends on git's defaults pass it to the app through `launchEnvironment`.
    static let isolatedGitEnvironment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

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

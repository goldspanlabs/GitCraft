import Foundation
import XCTest
@testable import GitCraft

final class WorktreeTabTests: XCTestCase {
    @MainActor
    func testOpeningViaSymlinkMatchesCanonicalWorktreePath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let symlink = root.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: repo)

        let tab = try RepoTab(url: symlink)
        defer { tab.stopWatcher() }

        XCTAssertEqual(tab.worktrees.count, 1)
        XCTAssertEqual(tab.activeCheckoutPath, tab.worktrees[0].path)
        XCTAssertEqual(tab.repoPath, tab.worktrees[0].path)
        XCTAssertTrue(tab.contains(checkoutPath: symlink.path))
    }

    @MainActor
    func testContainsMatchesPrimaryActiveAndSiblingWorktrees() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let wtA = root.appendingPathComponent("wt-a", isDirectory: true)
        let wtB = root.appendingPathComponent("wt-b", isDirectory: true)
        try git(["worktree", "add", "-b", "branch-a", wtA.path], in: repo)
        try git(["worktree", "add", "-b", "branch-b", wtB.path], in: repo)

        let tab = try RepoTab(url: wtA)
        defer { tab.stopWatcher() }

        XCTAssertTrue(tab.contains(checkoutPath: repo.path))
        XCTAssertTrue(tab.contains(checkoutPath: wtA.path))
        XCTAssertTrue(tab.contains(checkoutPath: wtB.path))
    }

    @MainActor
    func testSwitchCheckoutClearsComposerStateAndIgnoresPrunable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let gone = root.appendingPathComponent("gone", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)
        try git(["worktree", "add", "-b", "gone", gone.path], in: repo)
        try FileManager.default.removeItem(at: gone)

        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        let prunable = try XCTUnwrap(tab.worktrees.first { $0.isPrunable })
        let startingPath = tab.activeCheckoutPath
        tab.switchCheckout(to: prunable.path)
        XCTAssertEqual(tab.activeCheckoutPath, startingPath)
        XCTAssertNil(tab.errorMessage)

        tab.commitSummary = "Draft summary"
        tab.commitBody = "Draft body"
        tab.skipHooks = true

        let target = try XCTUnwrap(tab.worktrees.first { !$0.isMain && !$0.isPrunable })
        tab.switchCheckout(to: target.path)

        XCTAssertEqual(tab.activeCheckoutPath, target.path)
        XCTAssertEqual(tab.commitSummary, "")
        XCTAssertEqual(tab.commitBody, "")
        XCTAssertFalse(tab.skipHooks)
    }

    @MainActor
    func testSuggestedWorktreePathSanitizesBranchName() {
        let path = NewWorktreeSheet.suggestedPath(
            repoPath: "/Users/me/code/GitCraft",
            suffix: "feature/worktree ui"
        )
        XCTAssertEqual(path, "/Users/me/code/GitCraft-feature-worktree-ui")

        let fallback = NewWorktreeSheet.suggestedPath(
            repoPath: "/Users/me/code/GitCraft",
            suffix: "   "
        )
        XCTAssertEqual(fallback, "/Users/me/code/GitCraft-worktree")
    }

    @MainActor
    func testRequestRemoveWorktreeGuardsMainAndLockedAndMarksActive() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)
        try git(["worktree", "add", "-b", "locked", locked.path], in: repo)
        try git(["worktree", "lock", locked.path], in: repo)

        let tab = try RepoTab(url: linked)
        defer { tab.stopWatcher() }

        let mainWt = try XCTUnwrap(tab.worktrees.first { $0.isMain })
        let lockedWt = try XCTUnwrap(tab.worktrees.first { $0.isLocked })
        let activeWt = try XCTUnwrap(tab.worktrees.first { $0.path == tab.activeCheckoutPath })

        tab.requestRemoveWorktree(mainWt)
        XCTAssertNil(tab.pendingConfirmation, "main checkout must not be removable")

        tab.requestRemoveWorktree(lockedWt)
        XCTAssertNil(tab.pendingConfirmation, "locked worktree must be unlocked before removing")

        tab.requestRemoveWorktree(activeWt)
        guard case let .removeWorktree(path, label, isActive) = tab.pendingConfirmation else {
            return XCTFail("expected .removeWorktree confirmation")
        }
        XCTAssertEqual(path, activeWt.path)
        XCTAssertEqual(label, URL(fileURLWithPath: activeWt.path).lastPathComponent)
        XCTAssertTrue(isActive)
    }

    @MainActor
    func testRemovingActiveWorktreeSwitchesBackToMainCheckout() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)

        let tab = try RepoTab(url: linked)
        defer { tab.stopWatcher() }

        let activeWt = try XCTUnwrap(tab.worktrees.first { !$0.isMain })
        XCTAssertEqual(tab.activeCheckoutPath, activeWt.path)

        tab.removeWorktree(path: activeWt.path, label: "linked", force: false)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && tab.activeCheckoutPath != tab.repoPath {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(tab.activeCheckoutPath, tab.repoPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeWt.path))
    }

    @MainActor
    func testRemovingADirtyWorktreeAsksForForceConfirmationBeforeDeletingAnything() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)
        try "unsaved work\n".write(
            to: linked.appendingPathComponent("scratch.txt"),
            atomically: true,
            encoding: .utf8
        )

        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let worktree = try XCTUnwrap(tab.worktrees.first { !$0.isMain })

        // The safe remove is refused by git, so the tab escalates to the force prompt.
        tab.requestRemoveWorktree(worktree)
        let first = try XCTUnwrap(tab.pendingConfirmation)
        tab.executeConfirmed(first)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !tab.isForceRemovePrompt {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case let .forceRemoveWorktree(path, label, isActive) = tab.pendingConfirmation else {
            return XCTFail("expected the force-remove confirmation, got \(String(describing: tab.pendingConfirmation))")
        }
        XCTAssertEqual(path, worktree.path)
        XCTAssertEqual(label, "linked", "the prompt names the folder")
        XCTAssertFalse(isActive)
        XCTAssertTrue(
            tab.pendingConfirmation?.message.contains("permanently deleted") == true,
            "the prompt warns that the files can't be recovered"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path), "nothing is deleted before the user confirms")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.appendingPathComponent("scratch.txt").path))

        // Confirming the force prompt deletes the folder; the branch stays.
        tab.executeConfirmed(try XCTUnwrap(tab.pendingConfirmation))
        let removalDeadline = Date().addingTimeInterval(10)
        while Date() < removalDeadline, FileManager.default.fileExists(atPath: linked.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertTrue(try git(["branch", "--list", "linked"], in: repo).contains("linked"))
    }

    func testRemoveWorktreeConfirmationShortensTheHomeFolderToATilde() {
        let path = NSHomeDirectory() + "/Documents/projects/GitCraft-feature"
        let expected = "\"~/Documents/projects/GitCraft-feature\""

        for action in [
            RepoTab.DestructiveAction.removeWorktree(path: path, label: "GitCraft-feature", isActive: false),
            .removeWorktree(path: path, label: "GitCraft-feature", isActive: true),
            .forceRemoveWorktree(path: path, label: "GitCraft-feature", isActive: false),
            .forceRemoveWorktree(path: path, label: "GitCraft-feature", isActive: true),
        ] {
            XCTAssertTrue(action.message.contains(expected), "unexpected message: \(action.message)")
            XCTAssertFalse(action.message.contains(NSHomeDirectory()))
        }
        XCTAssertEqual(
            RepoTab.DestructiveAction.removeWorktree(path: path, label: "GitCraft-feature", isActive: false).title,
            "Remove worktree \"GitCraft-feature\"?"
        )
    }

    @MainActor
    func testSwitchCheckoutClearsStaleStatusAndResetsTableSelection() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)

        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.stagedFiles = [FileChange(path: "a.txt", status: "M", staged: true)]
        tab.unstagedFiles = [FileChange(path: "b.txt", status: "M", staged: false)]
        tab.isMerging = true
        tab.isRebasing = true
        tab.isCherryPicking = true
        tab.isReverting = true
        tab.hasConflicts = true
        tab.scrollRequest = RepoTab.ScrollRequest(oidHex: "deadbeef")

        let target = try XCTUnwrap(tab.worktrees.first { !$0.isMain })
        tab.switchCheckout(to: target.path)

        XCTAssertTrue(tab.stagedFiles.isEmpty)
        XCTAssertTrue(tab.unstagedFiles.isEmpty)
        XCTAssertFalse(tab.isMerging)
        XCTAssertFalse(tab.isRebasing)
        XCTAssertFalse(tab.isCherryPicking)
        XCTAssertFalse(tab.isReverting)
        XCTAssertFalse(tab.hasConflicts)
        XCTAssertEqual(tab.currentBranch, "linked")
        XCTAssertNotNil(tab.scrollRequest)
        XCTAssertNil(tab.scrollRequest?.oidHex)
    }

    @MainActor
    func testAddWorktreeResolvesRelativePathAgainstActiveCheckout() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        let canonicalRoot = URL(fileURLWithPath: RepoTab.canonicalPath(for: root.path), isDirectory: true)
        let expected = canonicalRoot.appendingPathComponent("relative-wt").path
        XCTAssertEqual(
            RepoTab.resolvePath("../relative-wt", relativeTo: tab.activeCheckoutPath),
            expected
        )

        tab.addWorktree(
            path: "../relative-wt",
            branchName: "relative-branch",
            startPoint: nil,
            detach: false,
            switchAfterCreate: true
        )

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && tab.activeCheckoutPath != expected {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(tab.activeCheckoutPath, expected)
        XCTAssertNil(tab.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
    }

    @MainActor
    func testBareBackedWorktreeRemovalUsesSurvivingCheckoutAndBlocksSoleCheckout() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)

        let wt1 = root.appendingPathComponent("wt1", isDirectory: true)
        let wt2 = root.appendingPathComponent("wt2", isDirectory: true)
        try git(["worktree", "add", wt1.path, "main"], in: bare)
        try git(["worktree", "add", "-b", "second", wt2.path], in: bare)

        let tab = try RepoTab(url: wt1)
        defer { tab.stopWatcher() }

        let firstWt = try XCTUnwrap(tab.worktrees.first { $0.path == tab.activeCheckoutPath })
        let secondWt = try XCTUnwrap(tab.worktrees.first { $0.path != tab.activeCheckoutPath })
        XCTAssertTrue(tab.canRemoveWorktree(firstWt))

        tab.removeWorktree(path: firstWt.path, label: "main", force: false)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && tab.activeCheckoutPath != secondWt.path {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(tab.activeCheckoutPath, secondWt.path)
        XCTAssertEqual(tab.repoPath, secondWt.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWt.path))

        // Wait for the surviving tab's worktree list to reflect that only one checkout remains.
        let listDeadline = Date().addingTimeInterval(10)
        while Date() < listDeadline && tab.worktrees.count != 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let sole = try XCTUnwrap(tab.worktrees.first)
        XCTAssertFalse(tab.canRemoveWorktree(sole), "cannot remove the sole remaining checkout")
    }

    @MainActor
    func testRemovingActiveWorktreeIsRefusedWhenFallbackIsNoLongerUsable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A bare-backed repository has no primary checkout, so the only fallback for wt1 is wt2.
        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)
        let wt1 = root.appendingPathComponent("wt1", isDirectory: true)
        let wt2 = root.appendingPathComponent("wt2", isDirectory: true)
        try git(["worktree", "add", wt1.path, "main"], in: bare)
        try git(["worktree", "add", "-b", "second", wt2.path], in: bare)

        let tab = try RepoTab(url: wt1)
        defer { tab.stopWatcher() }
        let active = tab.activeCheckoutPath
        let other = try XCTUnwrap(tab.worktrees.first { $0.path != active })
        XCTAssertTrue(tab.canRemoveWorktree(try XCTUnwrap(tab.worktrees.first { $0.path == active })))

        // The fallback's folder is still there but is no longer a checkout: opening it fails in
        // the background work, before anything is removed.
        try FileManager.default.removeItem(atPath: other.path + "/.git")
        tab.removeWorktree(path: active, label: "main", force: false)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && tab.isBusy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(tab.isBusy)
        XCTAssertNotNil(tab.errorMessage)
        XCTAssertEqual(tab.activeCheckoutPath, active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active))

        // The fallback's folder is gone entirely, though the cached list still offers it.
        tab.errorMessage = nil
        try FileManager.default.removeItem(atPath: other.path)
        tab.removeWorktree(path: active, label: "main", force: true)
        XCTAssertNotNil(tab.errorMessage)
        XCTAssertFalse(tab.isBusy, "nothing should have been started")
        XCTAssertEqual(tab.activeCheckoutPath, active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active))
    }

    @MainActor
    func testFallbackNestedInsideRemovalTargetIsNotUsed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // The only other checkout lives inside the active one, so removing the active one
        // would delete it too.
        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        try git(["worktree", "add", outer.path, "main"], in: bare)
        let nested = outer.appendingPathComponent("nested", isDirectory: true)
        try git(["worktree", "add", "-b", "nested", nested.path], in: bare)

        let tab = try RepoTab(url: outer)
        defer { tab.stopWatcher() }
        let active = try XCTUnwrap(tab.worktrees.first { $0.path == tab.activeCheckoutPath })

        XCTAssertNil(tab.fallbackCheckoutPath(excluding: active.path))
        XCTAssertFalse(tab.canRemoveWorktree(active))
        tab.removeWorktree(path: active.path, label: "main", force: true)
        XCTAssertNotNil(tab.errorMessage)
        XCTAssertFalse(tab.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    @MainActor
    func testRemovingActiveWorktreeIsRefusedWhenFallbackIsAnotherRepository() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)
        let wt1 = root.appendingPathComponent("wt1", isDirectory: true)
        let wt2 = root.appendingPathComponent("wt2", isDirectory: true)
        try git(["worktree", "add", wt1.path, "main"], in: bare)
        try git(["worktree", "add", "-b", "second", wt2.path], in: bare)

        let tab = try RepoTab(url: wt1)
        defer { tab.stopWatcher() }
        let active = tab.activeCheckoutPath
        let other = try XCTUnwrap(tab.worktrees.first { $0.path != active })

        // An unrelated repository now sits where the fallback checkout was.
        try FileManager.default.removeItem(atPath: other.path)
        _ = try makeRepo(at: URL(fileURLWithPath: other.path, isDirectory: true))

        tab.removeWorktree(path: active, label: "main", force: false)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && tab.isBusy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(tab.errorMessage)
        XCTAssertEqual(tab.activeCheckoutPath, active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active))
    }

    @MainActor
    func testTabSwitchesAwayWhenShownCheckoutFolderDisappears() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)

        let tab = try RepoTab(url: linked)
        tab.startWatcher()
        defer { tab.stopWatcher() }
        let primary = tab.repoPath
        XCTAssertNotEqual(tab.activeCheckoutPath, primary)

        // Deleted outside the app, as Finder or `rm -rf` would.
        try FileManager.default.removeItem(at: linked)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && tab.activeCheckoutPath != primary {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(tab.activeCheckoutPath, primary)
        XCTAssertNotNil(tab.toast)
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testTabSwitchesAwayWhenCheckoutIsRemovedAndPrunedByAnotherClient() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked", linked.path], in: repo)

        let tab = try RepoTab(url: linked)
        tab.startWatcher()
        defer { tab.stopWatcher() }
        let primary = tab.repoPath

        // Another Git client removes the checkout and its registration, so the primary's own
        // worktree list no longer mentions anything the tab knew besides itself.
        try FileManager.default.removeItem(at: linked)
        try git(["worktree", "prune"], in: repo)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && tab.activeCheckoutPath != primary {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(tab.activeCheckoutPath, primary)
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testRepoPathMovesWhenTheMissingCheckoutWasTheRepositoryPath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A bare-backed repository has no separate main folder, so the first checkout git lists
        // doubles as the tab's `repoPath`.
        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)
        let wt1 = root.appendingPathComponent("wt1", isDirectory: true)
        let wt2 = root.appendingPathComponent("wt2", isDirectory: true)
        try git(["worktree", "add", wt1.path, "main"], in: bare)
        try git(["worktree", "add", "-b", "second", wt2.path], in: bare)

        let tab = try RepoTab(url: wt1)
        tab.startWatcher()
        defer { tab.stopWatcher() }
        let missing = tab.activeCheckoutPath
        XCTAssertEqual(tab.repoPath, missing)
        let survivor = try XCTUnwrap(tab.worktrees.first { $0.path != missing })

        try FileManager.default.removeItem(atPath: missing)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && tab.activeCheckoutPath != survivor.path {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(tab.activeCheckoutPath, survivor.path)
        XCTAssertEqual(tab.repoPath, survivor.path)
    }

    @MainActor
    func testMissingSoleCheckoutIsReportedAndTabStaysPut() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A bare-backed repository with a single checkout has nowhere else to go.
        let source = try makeRepo(at: root.appendingPathComponent("source", isDirectory: true))
        let bare = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["clone", "--bare", source.path, bare.path], in: root)
        let only = root.appendingPathComponent("only", isDirectory: true)
        try git(["worktree", "add", only.path, "main"], in: bare)

        let tab = try RepoTab(url: only)
        tab.startWatcher()
        defer { tab.stopWatcher() }
        let active = tab.activeCheckoutPath

        try FileManager.default.removeItem(at: only)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && tab.errorMessage == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(tab.errorMessage)
        XCTAssertEqual(tab.activeCheckoutPath, active)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-wt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepo(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: url)
        try git(["config", "user.name", "GitCraft Tests"], in: url)
        try git(["config", "user.email", "tests@gitcraft.local"], in: url)
        try "hello\n".write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "README.md"], in: url)
        try git(["commit", "-m", "initial"], in: url)
        return url
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
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
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed: \(output)")
        return output
    }
}

private extension RepoTab {
    /// True while the "has uncommitted changes" prompt for a worktree removal is showing.
    var isForceRemovePrompt: Bool {
        if case .forceRemoveWorktree = pendingConfirmation { return true }
        return false
    }
}

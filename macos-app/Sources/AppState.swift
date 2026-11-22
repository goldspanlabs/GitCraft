import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Operation { case fetch, pull, push }

    struct ScrollRequest: Equatable {
        let id = UUID()
        let oidHex: String?
    }

    @Published private(set) var repositoryName = "No repository"
    @Published private(set) var changes: [String] = []
    @Published private(set) var commits: [CommitRow] = []
    @Published private(set) var branches: [BranchInfo] = []
    @Published private(set) var tags: [TagInfo] = []
    @Published private(set) var selectedCommit: CommitRow?
    @Published private(set) var scrollRequest: ScrollRequest?
    @Published var searchQuery: String = ""

    private var session: RepoSession?
    private var isLoadingMore = false
    private var hasMoreCommits = true
    private let pageSize: UInt32 = 500

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "recentRepository")
        open(url)
    }

    func openRecent() async {
        if let path = UserDefaults.standard.string(forKey: "recentRepository") {
            open(URL(fileURLWithPath: path))
        }
    }

    func run(_ operation: Operation) {
        Task {
            guard let session else { return }
            do {
                switch operation {
                case .fetch: try await Task.detached { try session.fetch() }.value
                case .pull: try await Task.detached { try session.pull() }.value
                case .push: try await Task.detached { try session.push() }.value
                }
                refresh()
            } catch {
                NSLog("MiniGit operation failed: \(error)")
            }
        }
    }

    func checkoutBranch(_ branchName: String) {
        Task {
            guard let session else { return }
            do {
                try await Task.detached {
                    try session.checkoutBranch(branchName: branchName)
                }.value
                refresh()
            } catch {
                NSLog("Checkout failed: \(error)")
            }
        }
    }

    func scrollToCommit(oidHex: String) {
        scrollRequest = ScrollRequest(oidHex: oidHex)
    }

    func scrollToWorkingChanges() {
        scrollRequest = ScrollRequest(oidHex: nil)
    }

    func selectCommit(_ commit: CommitRow?) {
        selectedCommit = commit
    }

    func updateSearch(_ query: String) {
        searchQuery = query
        refreshCommitsOnly()
    }

    func loadMoreCommits() {
        guard let session, !isLoadingMore, hasMoreCommits else { return }
        isLoadingMore = true
        let offset = UInt32(commits.count)
        let limit = pageSize
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery

        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = try await Task.detached {
                    try session.getCommitGraph(offset: offset, limit: limit, searchQuery: query)
                }.value
                if nextPage.count < Int(limit) {
                    hasMoreCommits = false
                }
                commits.append(contentsOf: nextPage)
            } catch {
                NSLog("Unable to load more commits: \(error)")
            }
        }
    }

    private func open(_ url: URL) {
        do {
            let newSession = try RepoSession(path: url.path)
            session = newSession
            repositoryName = url.lastPathComponent
            refresh()
        } catch {
            NSLog("Unable to open repository: \(error)")
        }
    }

    private func refresh() {
        guard let session else { return }
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery
        let limit = pageSize

        Task {
            do {
                async let statusTask = Task.detached { try session.status() }.value
                async let branchesTask = Task.detached { try session.listBranches() }.value
                async let tagsTask = Task.detached { try session.listTags() }.value
                async let graphTask = Task.detached {
                    try session.getCommitGraph(offset: 0, limit: limit, searchQuery: query)
                }.value

                let (status, branchList, tagList, graphRows) = try await (
                    statusTask,
                    branchesTask,
                    tagsTask,
                    graphTask
                )
                changes = status.files
                branches = branchList
                tags = tagList
                commits = graphRows
                hasMoreCommits = graphRows.count >= Int(limit)
            } catch {
                NSLog("Unable to refresh repository: \(error)")
            }
        }
    }

    private func refreshCommitsOnly() {
        guard let session else { return }
        let query: String? = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchQuery
        let limit = pageSize

        Task {
            do {
                let graphRows = try await Task.detached {
                    try session.getCommitGraph(offset: 0, limit: limit, searchQuery: query)
                }.value
                commits = graphRows
                hasMoreCommits = graphRows.count >= Int(limit)
            } catch {
                NSLog("Unable to search commits: \(error)")
            }
        }
    }
}

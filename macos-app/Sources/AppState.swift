import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Operation { case fetch, pull, push }
    @Published private(set) var repositoryName = "No repository"
    @Published private(set) var changes: [String] = []
    @Published private(set) var commits: [CommitRow] = []
    private var session: RepoSession?

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
                case .fetch: try await session.fetch()
                case .pull: try await session.pull()
                case .push: try await session.push()
                }
                refresh()
            } catch { NSLog("MiniGit operation failed: \(error)") }
        }
    }

    private func open(_ url: URL) {
        do {
            let newSession = try RepoSession(path: url.path)
            session = newSession
            repositoryName = url.lastPathComponent
            refresh()
        } catch { NSLog("Unable to open repository: \(error)") }
    }

    private func refresh() {
        guard let session else { return }
        Task {
            do {
                let status = try await session.status()
                let history = try await session.history(limit: 200)
                changes = status.files
                commits = history
            } catch { NSLog("Unable to refresh repository: \(error)") }
        }
    }
}

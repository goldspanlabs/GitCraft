import Foundation

extension RepoTab {
    func toggleScopeToCurrentBranch() {
        scopeToCurrentBranch.toggle()
        updateSearch(searchQuery)  // reload the graph from the top with the new scope
    }

    nonisolated static func graphPage(
        _ session: RepoSession,
        scoped: Bool,
        offset: UInt32,
        limit: UInt32,
        query: String?
    ) throws -> [CommitRow] {
        session.setCommitSort(sort: CommitSortPreference.current.core)
        if scoped {
            return try session.getBranchGraph(offset: offset, limit: limit, searchQuery: query)
        }
        return try session.getCommitGraph(offset: offset, limit: limit, searchQuery: query)
    }

    /// Hides git's plumbing header lines (`index`, `---`, `+++`, mode lines). When the diff
    /// spans several files, each file's `diff --git` line is kept as a plain file name so
    /// the files stay distinguishable; a single-file diff needs no header at all.
    nonisolated static func displayRows(_ rows: [DiffRow]) -> [DiffRow] {
        let fileCount = rows.reduce(0) { $0 + ($1.kind == "header" && $1.text.hasPrefix("diff --git ") ? 1 : 0) }
        return rows.compactMap { row in
            guard row.kind == "header" else { return row }
            guard fileCount > 1, row.text.hasPrefix("diff --git ") else { return nil }
            var shown = row
            if let range = row.text.range(of: " b/", options: .backwards) {
                shown.text = String(row.text[range.upperBound...])
            }
            return shown
        }
    }

    func loadMoreCommits() {
        guard !isLoadingMore, hasMoreCommits else { return }
        isLoadingMore = true
        let session = self.session
        let offset = UInt32(commits.count)
        let limit = pageSize
        let query = activeSearchQuery
        let generation = graphGeneration
        let scoped = scopeToCurrentBranch

        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: offset, limit: limit, query: query)
                }.value
                // The list was replaced while we fetched; this page belongs to the old one.
                guard generation == graphGeneration else { return }
                if nextPage.count < Int(limit) {
                    hasMoreCommits = false
                }
                commits.append(contentsOf: nextPage)
                graphRevision = UUID()
            } catch {
                showError(error)
            }
        }
    }

    func updateSearch(_ query: String) {
        searchQuery = query
        graphGeneration += 1  // in-flight page fetches used the old query
        pendingSearchReplacements += 1
        let session = self.session
        let q = activeSearchQuery
        let limit = pageSize
        let scoped = scopeToCurrentBranch

        Task {
            defer { pendingSearchReplacements -= 1 }
            do {
                let graphRows = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: 0, limit: limit, query: q)
                }.value
                graphGeneration += 1
                commits = graphRows
                graphRevision = UUID()
                hasMoreCommits = graphRows.count >= Int(limit)
            } catch {
                showError(error)
            }
        }
    }

    func scrollToCommit(oidHex: String) {
        revealTask?.cancel()
        revealTask = nil
        if let commit = commits.first(where: { $0.oidHex == oidHex }) {
            scrollRequest = ScrollRequest(oidHex: oidHex)
            // Update the detail/diff panes directly rather than relying on the table
            // selection callback, which fires from inside a SwiftUI view update.
            selectCommit(commit)
            return
        }
        // Tip is beyond the loaded page(s): page in more history until it shows up.
        revealTask = Task { await revealCommit(oidHex: oidHex) }
    }

    private func revealCommit(oidHex: String) async {
        while isLoadingMore {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let session = self.session
        // Each graph call re-walks history from the tips (cost ~ offset + limit), so
        // grow the page geometrically: O(log n) calls instead of n / pageSize.
        var limit = pageSize

        while !Task.isCancelled {
            // The new query's first page isn't installed yet: the old list's offset and
            // pagination state don't apply to it, so wait and re-evaluate.
            if pendingSearchReplacements > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            if let commit = commits.first(where: { $0.oidHex == oidHex }) {
                scrollRequest = ScrollRequest(oidHex: oidHex)
                selectCommit(commit)
                return
            }
            guard hasMoreCommits else { break }
            // Re-read offset/query each round: refresh or search may have replaced the list.
            let offset = UInt32(commits.count)
            let query = activeSearchQuery
            let generation = graphGeneration
            let scoped = scopeToCurrentBranch
            do {
                let nextPage = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: offset, limit: limit, query: query)
                }.value
                if Task.isCancelled { return }
                // Stale page (list replaced mid-fetch): drop it and look again.
                if generation != graphGeneration { continue }
                if nextPage.count < Int(limit) { hasMoreCommits = false }
                commits.append(contentsOf: nextPage)
                graphRevision = UUID()
                limit = min(limit * 2, 64_000)
            } catch {
                showError(error)
                return
            }
        }
        if Task.isCancelled { return }
        if scopeToCurrentBranch {
            // Outside the Branch view (e.g. another branch picked in the sidebar): switch to
            // All, which reloads the list from the top, then look for the commit again.
            toggleScopeToCurrentBranch()
            revealTask = Task { await self.revealCommit(oidHex: oidHex) }
            return
        }
        // Not reachable in the current graph (e.g. hidden by the search filter): don't
        // leave the panes showing an unrelated commit.
        errorMessage = "That commit isn't in the current commit list."
        // Go through the same path as the sidebar's Working Changes so the table
        // highlight moves with the detail pane.
        scrollToWorkingChanges()
    }

    func scrollToWorkingChanges() {
        revealTask?.cancel()
        revealTask = nil
        scrollRequest = ScrollRequest(oidHex: nil)
        selectCommit(nil)
    }

    /// Selection coming from the commit table (user click/arrow keys, or the table
    /// echoing a programmatic selection). Either way it supersedes a pending reveal:
    /// programmatic table selections only happen after a reveal has finished.
    func selectCommitFromTable(_ commit: CommitRow?) {
        revealTask?.cancel()
        revealTask = nil
        selectCommit(commit)
    }

    func selectCommit(_ commit: CommitRow?) {
        if let commit {
            // Always keep the freshest row (refs/lanes may have changed), but only
            // reload when this oid's detail is already loaded or in flight; a failed
            // load clears the marker so re-clicking the commit retries.
            selectedCommit = commit
            if loadedDetailOid == commit.oidHex { return }
            loadedDetailOid = commit.oidHex
            loadCommitDetails(commit)
        } else {
            guard selectedCommit != nil else { return }
            selectedCommit = nil
            loadedDetailOid = nil
            commitDetail = nil
            loadWorkingDiffSelection()
        }
    }

    func selectWorkingFile(_ file: FileChange) {
        selectedFilePath = file.path
        selectedFileStaged = file.staged
        loadWorkingDiff(path: file.path, staged: file.staged)
    }

    func selectCommitFile(_ path: String?) {
        guard let oid = selectedCommit?.oidHex else { return }
        selectedFilePath = path
        selectedFileStaged = false
        loadCommitDiff(oidHex: oid, path: path)
    }

    func loadWorkingDiffSelection() {
        if let path = selectedFilePath {
            if selectedFileStaged, stagedFiles.contains(where: { $0.path == path }) {
                loadWorkingDiff(path: path, staged: true)
                return
            }
            if !selectedFileStaged, unstagedFiles.contains(where: { $0.path == path }) {
                loadWorkingDiff(path: path, staged: false)
                return
            }
        }
        if let first = unstagedFiles.first {
            selectWorkingFile(first)
        } else if let firstStaged = stagedFiles.first {
            selectWorkingFile(firstStaged)
        } else {
            selectedFilePath = nil
            diffRows = []
        }
    }

    private func loadWorkingDiff(path: String, staged: Bool) {
        let session = self.session
        Task {
            do {
                let rows = try await Task.detached {
                    try session.getWorkingDiff(path: path, staged: staged)
                }.value
                if selectedCommit == nil && selectedFilePath == path && selectedFileStaged == staged {
                    diffRows = Self.displayRows(rows)
                }
            } catch {
                showError(error)
            }
        }
    }

    private func loadCommitDetails(_ commit: CommitRow) {
        let session = self.session
        let oid = commit.oidHex
        Task {
            do {
                let detail = try await Task.detached {
                    try session.getCommitDetail(oidHex: oid)
                }.value
                guard selectedCommit?.oidHex == oid else { return }
                commitDetail = detail
                let firstPath = detail.files.first?.path
                selectedFilePath = firstPath
                loadCommitDiff(oidHex: oid, path: firstPath)
            } catch {
                if loadedDetailOid == oid { loadedDetailOid = nil }
                showError(error)
            }
        }
    }

    private func loadCommitDiff(oidHex: String, path: String?) {
        let session = self.session
        Task {
            do {
                let rows = try await Task.detached {
                    try session.getCommitDiff(oidHex: oidHex, path: path)
                }.value
                if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                    diffRows = Self.displayRows(rows)
                }
            } catch {
                // Only react if this request is still the current one (same commit and file);
                // a late failure for a file the user already moved off must not wipe the
                // newer file's diff.
                if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                    // Don't leave the previous diff showing, and let re-selecting
                    // this commit retry the load.
                    diffRows = []
                    loadedDetailOid = nil
                }
                showError(error)
            }
        }
    }
}

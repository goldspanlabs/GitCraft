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

    /// Fetches up to `totalLimit` commits in bounded UniFFI chunks so refreshing a deeply
    /// scrolled history doesn't serialize tens of thousands of rows in one buffer. If refs
    /// move between chunks, the inconsistent batch is discarded and retried (falling back to
    /// a single atomic fetch if refs keep changing).
    nonisolated static func graphPages(
        _ session: RepoSession,
        scoped: Bool,
        totalLimit: UInt32,
        query: String?
    ) throws -> [CommitRow] {
        let chunkSize: UInt32 = 2_000
        if totalLimit <= chunkSize {
            return try graphPage(session, scoped: scoped, offset: 0, limit: totalLimit, query: query)
        }
        session.setCommitSort(sort: CommitSortPreference.current.core)
        for _ in 0..<3 {
            let token = try session.graphStateToken(scoped: scoped)
            var rows: [CommitRow] = []
            rows.reserveCapacity(Int(totalLimit))
            var offset: UInt32 = 0
            var changed = false
            while offset < totalLimit {
                let remaining = totalLimit - offset
                let request = min(chunkSize, remaining)
                let page = try graphPage(session, scoped: scoped, offset: offset, limit: request, query: query)
                if try session.graphStateToken(scoped: scoped) != token {
                    changed = true
                    break
                }
                rows.append(contentsOf: page)
                if page.count < Int(request) {
                    break
                }
                offset += UInt32(page.count)
            }
            if !changed {
                return rows
            }
        }
        return try graphPage(session, scoped: scoped, offset: 0, limit: totalLimit, query: query)
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

    /// Installs a fresh first page as the whole commit list. Fewer rows than `requested` means
    /// the history ended. Bumps the generation, so pages fetched for the old list are dropped.
    func replaceCommits(with rows: [CommitRow], requested: UInt32) {
        graphIndexTask?.cancel()
        graphIndexTask = nil
        graphGeneration += 1
        commits = rows
        totalCommitCount = rows.count
        graphRevision = UUID()
        hasMoreCommits = rows.count >= Int(requested)
        historyState = .loaded
        reconcileSelection()
        if hasMoreCommits && activeSearchQuery == nil {
            startBackgroundGraphIndexing()
        }
    }

    /// Indexes the full unfiltered commit graph in Rust (compact OIDs + lane checkpoints, no
    /// row string materialization) so the table scrollbar reflects the full history without
    /// blocking startup.
    func startBackgroundGraphIndexing() {
        graphIndexTask?.cancel()
        let session = self.session
        let generation = graphGeneration
        let scoped = scopeToCurrentBranch
        graphIndexTask = Task { [weak self] in
            do {
                let summary = try await Task.detached {
                    session.setCommitSort(sort: CommitSortPreference.current.core)
                    return try session.indexCommitGraph(scoped: scoped)
                }.value
                guard !Task.isCancelled, let self,
                      self.session === session,
                      self.graphGeneration == generation,
                      self.activeSearchQuery == nil,
                      self.scopeToCurrentBranch == scoped
                else { return }
                let indexedCount = Int(summary.totalCount)
                if indexedCount > self.totalCommitCount {
                    self.totalCommitCount = indexedCount
                    self.graphRevision = UUID()
                }
                self.hasMoreCommits = !summary.exhausted
            } catch {
                // Background indexing is best-effort; on-demand paging remains available.
            }
        }
    }

    /// Fetches a small materialized slice of the unfiltered graph for virtualized scrolling.
    func fetchGraphWindow(offset: Int, limit: Int) async throws -> [CommitRow] {
        let session = self.session
        let scoped = scopeToCurrentBranch
        let uOffset = UInt32(max(0, offset))
        let uLimit = UInt32(max(0, limit))
        return try await Task.detached {
            try RepoTab.graphPage(session, scoped: scoped, offset: uOffset, limit: uLimit, query: nil)
        }.value
    }

    /// Adds the next page to the commit list. Fewer rows than `requested` means the history ended.
    func appendCommits(_ page: [CommitRow], requested: UInt32) {
        if page.count < Int(requested) {
            hasMoreCommits = false
        }
        commits.append(contentsOf: page)
        totalCommitCount = max(totalCommitCount, commits.count)
        graphRevision = UUID()
    }

    func loadMoreCommits() {
        guard !isLoadingMore, hasMoreCommits else { return }
        isLoadingMore = true
        let offset = UInt32(commits.count)
        let limit = pageSize
        let query = activeSearchQuery
        let generation = graphGeneration
        let scoped = scopeToCurrentBranch

        loadInBackground({ session in
            try RepoTab.graphPage(session, scoped: scoped, offset: offset, limit: limit, query: query)
        }, apply: { [self] nextPage in
            // The list was replaced while we fetched; this page belongs to the old one.
            guard generation == graphGeneration else { return }
            appendCommits(nextPage, requested: limit)
        }, always: { [self] in
            isLoadingMore = false
        })
    }

    /// Runs the search once typing pauses, so each keystroke doesn't start a history walk.
    func updateSearchDebounced(_ query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.searchDebounceTask = nil
            self?.updateSearch(query)
        }
    }

    func updateSearch(_ query: String) {
        searchQuery = query
        graphGeneration += 1  // invalidate in-flight page fetches and older searches
        let requestGeneration = graphGeneration
        pendingSearchReplacements += 1
        let session = self.session
        let q = activeSearchQuery
        let limit = pageSize
        let scoped = scopeToCurrentBranch

        // A newer search, scope change or checkout switch replaces this one's results.
        let isCurrent = {
            self.session === session
                && requestGeneration == self.graphGeneration
                && self.activeSearchQuery == q
                && self.scopeToCurrentBranch == scoped
        }

        Task {
            defer { pendingSearchReplacements -= 1 }
            do {
                let graphRows = try await Task.detached {
                    try RepoTab.graphPage(session, scoped: scoped, offset: 0, limit: limit, query: q)
                }.value
                guard isCurrent() else { return }
                replaceCommits(with: graphRows, requested: limit)
            } catch {
                guard isCurrent() else { return }
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
        // Fast path for unfiltered graphs: look up the commit's exact index in Rust's compact
        // index and fetch only a small window around it instead of paging tens of thousands of rows.
        if activeSearchQuery == nil {
            let scoped = scopeToCurrentBranch
            let generation = graphGeneration
            do {
                let foundIndex = try await Task.detached {
                    session.setCommitSort(sort: CommitSortPreference.current.core)
                    return try session.findCommitIndex(oidHex: oidHex, scoped: scoped)
                }.value
                if Task.isCancelled || self.session !== session || generation != graphGeneration { return }
                if let idx = foundIndex {
                    let rowIdx = Int(idx)
                    let winStart = max(0, rowIdx - 20)
                    let winLen = 60
                    let window = try await Task.detached {
                        try RepoTab.graphPage(
                            session,
                            scoped: scoped,
                            offset: UInt32(winStart),
                            limit: UInt32(winLen),
                            query: nil
                        )
                    }.value
                    if Task.isCancelled || self.session !== session || generation != graphGeneration { return }
                    let localIdx = rowIdx - winStart
                    if localIdx >= 0, localIdx < window.count {
                        let target = window[localIdx]
                        if rowIdx + 1 > totalCommitCount {
                            totalCommitCount = rowIdx + 1
                            graphRevision = UUID()
                        }
                        scrollRequest = ScrollRequest(
                            oidHex: oidHex,
                            rowIndex: rowIdx,
                            prefetchedOffset: winStart,
                            prefetchedRows: window
                        )
                        selectCommit(target)
                        return
                    }
                } else if !hasMoreCommits {
                    // Index is exhausted and commit wasn't found; skip the paging loop.
                    if scopeToCurrentBranch {
                        toggleScopeToCurrentBranch()
                        revealTask = Task { await self.revealCommit(oidHex: oidHex) }
                        return
                    }
                    errorMessage = "That commit isn't in the current commit list."
                    scrollToWorkingChanges()
                    return
                }
            } catch {
                guard self.session === session else { return }
                showError(error)
                return
            }
        }

        // Each graph call re-walks history from the tips (cost ~ offset + limit), so
        // grow the page geometrically: O(log n) calls instead of n / pageSize.
        var limit = pageSize

        while !Task.isCancelled {
            guard self.session === session else { return }
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
                if Task.isCancelled || self.session !== session { return }
                // Stale page (list replaced mid-fetch): drop it and look again.
                if generation != graphGeneration { continue }
                appendCommits(nextPage, requested: limit)
                limit = min(limit * 2, 64_000)
            } catch {
                guard self.session === session else { return }
                showError(error)
                return
            }
        }
        if Task.isCancelled || self.session !== session { return }
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
        pendingSelectionOid = nil
        selectCommit(commit)
    }

    func selectCommit(_ commit: CommitRow?) {
        let hadMultiSelection = !selectedCommits.isEmpty
        if hadMultiSelection { selectedCommits = [] }
        if let commit {
            // Always keep the freshest row (refs/lanes may have changed), but only
            // reload when this oid's detail is already loaded or in flight; a failed
            // load clears the marker so re-clicking the commit retries.
            selectedCommit = commit
            if loadedDetailOid == commit.oidHex { return }
            isMarkdownPreview = false
            markdownPreviewGeneration &+= 1
            loadedMarkdownPreviewKey = nil
            markdownPreviewState = .idle
            loadedDetailOid = commit.oidHex
            loadCommitDetails(commit)
        } else {
            guard selectedCommit != nil || hadMultiSelection else { return }
            isMarkdownPreview = false
            markdownPreviewGeneration &+= 1
            loadedMarkdownPreviewKey = nil
            markdownPreviewState = .idle
            selectedCommit = nil
            loadedDetailOid = nil
            commitDetail = nil
            loadWorkingDiffSelection()
        }
    }

    func selectWorkingFile(_ file: FileChange) {
        publish(file.path, to: \.selectedFilePath)
        publish(file.staged, to: \.selectedFileStaged)
        loadWorkingDiff(path: file.path, staged: file.staged)
    }

    /// Moves the selected working file one row up (`delta` < 0) or down through the staged tree
    /// and then the unstaged one, skipping files in collapsed folders and stopping at the ends.
    func moveWorkingFileSelection(
        by delta: Int,
        collapsedStagedFolders: Set<String> = [],
        collapsedUnstagedFolders: Set<String> = []
    ) {
        let lists = [
            FileTree.List(changes: stagedFiles, collapsedFolderPaths: collapsedStagedFolders),
            FileTree.List(changes: unstagedFiles, collapsedFolderPaths: collapsedUnstagedFolders),
        ]
        // At either end there is no next file; skip the diff reload.
        guard let file = FileTree.file(
            movingBy: delta,
            through: lists,
            from: { $0.path == selectedFilePath && $0.staged == selectedFileStaged }
        ) else { return }
        selectWorkingFile(file)
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
            // Staging or unstaging moved the file to the other list: follow it there.
            if let moved = (stagedFiles + unstagedFiles).first(where: { $0.path == path }) {
                selectWorkingFile(moved)
                return
            }
        }
        if let first = FileTree.files(in: unstagedFiles).first ?? FileTree.files(in: stagedFiles).first {
            selectWorkingFile(first)
        } else {
            publish(nil, to: \.selectedFilePath)
            publish([], to: \.diffRows)
            resetMarkdownPreviewState()
        }
    }

    nonisolated static func isMarkdownPath(_ path: String?) -> Bool {
        guard let path else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd"
    }

    func toggleMarkdownPreview() {
        isMarkdownPreview.toggle()
        if isMarkdownPreview {
            loadMarkdownPreviewForSelection()
        } else {
            markdownPreviewGeneration &+= 1
        }
    }

    func loadMarkdownPreviewForSelection() {
        guard let path = selectedFilePath, Self.isMarkdownPath(path) else {
            resetMarkdownPreviewState()
            return
        }
        if let oid = selectedCommit?.oidHex {
            loadCommitMarkdownPreview(oidHex: oid, path: path)
        } else {
            loadWorkingMarkdownPreview(path: path, staged: selectedFileStaged)
        }
    }

    func resetMarkdownPreviewState() {
        markdownPreviewGeneration &+= 1
        loadedMarkdownPreviewKey = nil
        publish(.idle, to: \.markdownPreviewState)
    }

    private func loadWorkingDiff(path: String, staged: Bool) {
        loadInBackground({ try $0.getWorkingDiff(path: path, staged: staged) }, apply: { [self] rows in
            if selectedCommit == nil && selectedFilePath == path && selectedFileStaged == staged {
                publish(Self.displayRows(rows), to: \.diffRows)
            }
        })
        if isMarkdownPreview && Self.isMarkdownPath(path) {
            loadWorkingMarkdownPreview(path: path, staged: staged)
        } else {
            resetMarkdownPreviewState()
        }
    }

    private func loadWorkingMarkdownPreview(path: String, staged: Bool) {
        loadMarkdownPreview(
            key: "working:\(activeCheckoutPath):\(staged):\(path)",
            isCurrent: { self.selectedCommit == nil && self.selectedFilePath == path && self.selectedFileStaged == staged },
            fetch: { try $0.getWorkingFileVersions(path: path, staged: staged) }
        )
    }

    private func loadCommitDetails(_ commit: CommitRow) {
        let oid = commit.oidHex
        loadInBackground({ try $0.getCommitDetail(oidHex: oid) }, apply: { [self] detail in
            guard selectedCommit?.oidHex == oid else { return }
            commitDetail = detail
            let firstPath = detail.files.first?.path
            selectedFilePath = firstPath
            loadCommitDiff(oidHex: oid, path: firstPath)
        }, onFailure: { [self] _ in
            if loadedDetailOid == oid { loadedDetailOid = nil }
        })
    }

    private func loadCommitDiff(oidHex: String, path: String?) {
        loadInBackground({ try $0.getCommitDiff(oidHex: oidHex, path: path) }, apply: { [self] rows in
            if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                diffRows = Self.displayRows(rows)
            }
        }, onFailure: { [self] _ in
            // Only react if this request is still the current one (same commit and file);
            // a late failure for a file the user already moved off must not wipe the
            // newer file's diff.
            if selectedCommit?.oidHex == oidHex && selectedFilePath == path {
                // Don't leave the previous diff showing, and let re-selecting
                // this commit retry the load.
                diffRows = []
                loadedDetailOid = nil
            }
        })
        if isMarkdownPreview, let path, Self.isMarkdownPath(path) {
            loadCommitMarkdownPreview(oidHex: oidHex, path: path)
        } else {
            resetMarkdownPreviewState()
        }
    }

    private func loadCommitMarkdownPreview(oidHex: String, path: String) {
        loadMarkdownPreview(
            key: "commit:\(activeCheckoutPath):\(oidHex):\(path)",
            isCurrent: { self.selectedCommit?.oidHex == oidHex && self.selectedFilePath == path },
            fetch: { try $0.getCommitFileVersions(oidHex: oidHex, path: path) }
        )
    }

    private func loadMarkdownPreview(
        key: String,
        isCurrent: @escaping () -> Bool,
        fetch: @escaping (RepoSession) throws -> FileContentPair
    ) {
        markdownPreviewGeneration &+= 1
        let generation = markdownPreviewGeneration
        if loadedMarkdownPreviewKey != key || !isPreviewLoaded {
            loadedMarkdownPreviewKey = key
            publish(.loading, to: \.markdownPreviewState)
        }
        loadInBackground({ session -> MarkdownPreviewState in
            let pair = try fetch(session)
            guard pair.oldContent != nil || pair.newContent != nil else {
                return .deleted
            }
            return .loaded(renderMarkdownDiffHtml(oldMarkdown: pair.oldContent, newMarkdown: pair.newContent))
        }, apply: { [self] state in
            guard generation == markdownPreviewGeneration, isCurrent() else { return }
            loadedMarkdownPreviewKey = key
            publish(state, to: \.markdownPreviewState)
        }, onFailure: { [self] error in
            guard generation == markdownPreviewGeneration, isCurrent() else { return }
            loadedMarkdownPreviewKey = nil
            publish(.unavailable(error.localizedDescription), to: \.markdownPreviewState)
        }, reportsError: false)
    }

    private var isPreviewLoaded: Bool {
        if case .loaded = markdownPreviewState { return true }
        return false
    }
}

import Foundation

enum CompareRequest: Equatable, Sendable {
    case branch(String)
    case workingTree(String)

    var targetRef: String {
        switch self {
        case .branch(let ref), .workingTree(let ref): return ref
        }
    }
}

enum CompareState: Equatable {
    case idle
    case loading
    case loaded(CompareSummary)
    case error(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

extension RepoTab {
    nonisolated static func canCompareBranch(
        isCheckedOut: Bool, isDetached: Bool, hasMergeBase: Bool
    ) -> Bool {
        !isCheckedOut && !isDetached && hasMergeBase
    }

    func branchCompareMenuItem(_ branch: BranchInfo) -> MenuEntry {
        let enabled = Self.canCompareBranch(
            isCheckedOut: branch.isHead,
            isDetached: Self.isDetachedHead(branch: currentBranch),
            hasMergeBase: comparableBranchTips.contains(branch.targetOidHex)
        )
        return .item("Compare Common Base", enabled: enabled) {
            self.startCompare(.branch(branch.fullRef))
        }
    }

    var workingTreeCompareMenu: [MenuEntry] {
        let locals = branches.filter { !$0.isRemote }
        let defaultRef = locals.first { $0.fullRef == compareDefaultBranch }?.fullRef
            ?? locals.first(where: \.isDefault)?.fullRef
        let ordered = locals.sorted { lhs, rhs in
            if lhs.fullRef == defaultRef { return rhs.fullRef != defaultRef }
            if rhs.fullRef == defaultRef { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return [.submenu("Compare Common Base with Working Tree", ordered.map { branch in
            .item(branch.name) { self.startCompare(.workingTree(branch.fullRef)) }
        })]
    }

    func refreshCompareBranches(_ branchList: [BranchInfo]) {
        let tips = branchList.map(\.targetOidHex)
        let revision = UUID()
        compareBranchesRevision = revision
        loadInBackground({ session in
            (session.compareDefaultBranch(), (try? session.comparableBranchTips(tips: tips)) ?? [])
        }, apply: { [self] result in
            guard compareBranchesRevision == revision else { return }
            compareDefaultBranch = result.0
            comparableBranchTips = Set(result.1)
        })
    }

    func startCompare(_ request: CompareRequest) {
        closeCompare()
        compareRequest = request
        refreshCompare()
    }

    func closeCompare() {
        guard compareRequest != nil else { return }
        compareRequest = nil
        compareRevision = UUID()
        compareFileRevision = UUID()
        compareState = .idle
        compareFile = nil
        compareDiffRows = []
        compareDiffMessage = nil
        compareShowsMarkdown = false
        compareMarkdownState = .idle
    }

    func refreshCompare(workingTreeOnly: Bool = false) {
        guard let request = compareRequest else { return }
        if workingTreeOnly, case .branch = request { return }
        let revision = UUID()
        compareRevision = revision
        compareFileRevision = UUID()
        // Keep the current inspector in place during a background refresh.
        if !compareState.isLoaded { compareState = .loading }
        loadInBackground({ session in
            switch request {
            case .branch(let ref): return try session.compareBranches(baseRef: "HEAD", headRef: ref)
            case .workingTree(let ref): return try session.compareWorkingTree(baseRef: ref)
            }
        }, apply: { [self] summary in
            guard compareRevision == revision else { return }
            let selected = compareFile?.path
            let file = summary.files.first { $0.path == selected } ?? summary.files.first
            if file?.path != selected { compareShowsMarkdown = false }
            compareState = .loaded(summary)
            selectCompareFile(file)
        }, onFailure: { [self] error in
            guard compareRevision == revision else { return }
            if let error = error as? GitCraftError,
               case let .UnknownCompareRef(name) = error, name == request.targetRef {
                closeCompare()
                errorMessage = "Comparison closed because \(name) is no longer available."
            } else {
                compareState = .error(error.displayMessage)
            }
        }, reportsError: false)
    }

    func selectCompareFile(_ file: CompareFile?) {
        guard case .loaded(let summary) = compareState else { return }
        if compareFile?.path != file?.path { compareShowsMarkdown = false }
        compareFile = file
        compareDiffRows = []
        compareDiffMessage = file == nil ? nil : "Loading diff…"
        compareMarkdownState = .idle
        compareFileRevision = UUID()
        guard let file else { return }
        let revision = compareFileRevision
        let base = summary.mergeBaseOid
        let head = summary.headOid
        loadInBackground({ try $0.getCompareDiff(mergeBaseOid: base, headOid: head, file: file) },
            apply: { [self] rows in
                guard compareFileRevision == revision else { return }
                compareDiffRows = rows
                compareDiffMessage = nil
            },
            onFailure: { [self] error in
                guard compareFileRevision == revision else { return }
                compareDiffMessage = error.displayMessage
            },
            reportsError: false
        )
        loadCompareMarkdown()
    }

    func toggleCompareMarkdown() {
        compareShowsMarkdown.toggle()
        loadCompareMarkdown()
    }

    private func loadCompareMarkdown() {
        guard compareShowsMarkdown, compareMarkdownState == .idle,
              let file = compareFile, case .loaded(let summary) = compareState else { return }
        compareMarkdownState = .loading
        let revision = compareFileRevision
        let base = summary.mergeBaseOid
        let head = summary.headOid
        loadInBackground({ session in
            let versions = try session.getCompareFileContents(mergeBaseOid: base, headOid: head, file: file)
            return renderMarkdownDiffHtml(oldMarkdown: versions.oldContent, newMarkdown: versions.newContent)
        }, apply: { [self] html in
            guard compareFileRevision == revision else { return }
            compareMarkdownState = .loaded(html)
        }, onFailure: { [self] error in
            guard compareFileRevision == revision else { return }
            compareMarkdownState = .unavailable(error.displayMessage)
        }, reportsError: false)
    }
}

import SwiftUI

struct SidebarView: View {
    @ObservedObject var tab: RepoTab
    @State private var isWorkingTreeExpanded = true
    @State private var isLocalBranchesExpanded = true
    @State private var isRemotesExpanded = false
    @State private var isTagsExpanded = false
    @State private var isStashesExpanded = false
    @State private var collapsedFolderIDs: Set<String> = []

    private var localBranches: [BranchInfo] {
        tab.branches.filter { !$0.isRemote }
    }

    private var remoteBranches: [BranchInfo] {
        tab.branches.filter { $0.isRemote }
    }

    private var localBranchRows: [FlatBranchRow] {
        BranchTreeNode.buildFlattenedRows(
            from: localBranches,
            scope: "local",
            collapsedFolderIDs: collapsedFolderIDs
        )
    }

    private var remoteBranchRows: [FlatBranchRow] {
        BranchTreeNode.buildFlattenedRows(
            from: remoteBranches,
            scope: "remote",
            collapsedFolderIDs: collapsedFolderIDs
        )
    }

    private func toggleFolder(_ folderID: String) {
        withAnimation(.easeInOut(duration: 0.14)) {
            if collapsedFolderIDs.contains(folderID) {
                collapsedFolderIDs.remove(folderID)
            } else {
                collapsedFolderIDs.insert(folderID)
            }
        }
    }

    var body: some View {
        List {
            Section(isExpanded: $isWorkingTreeExpanded) {
                if isWorkingTreeExpanded {
                    Button {
                        tab.scrollToWorkingChanges()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .frame(width: 16, alignment: .center)
                            Text("Working Changes")
                            Spacer()
                            if tab.totalChangesCount > 0 {
                                Text("\(tab.totalChangesCount)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionHeaderLabel(title: "WORKING TREE") { [] }
            }

            Section(isExpanded: $isLocalBranchesExpanded) {
                if isLocalBranchesExpanded {
                    ForEach(localBranchRows) { row in
                        switch row.kind {
                        case let .folder(name, folderID, isExpanded):
                            BranchFolderRowView(
                                name: name,
                                depth: row.depth,
                                isExpanded: isExpanded,
                                isTopLevelRemote: false
                            ) {
                                toggleFolder(folderID)
                            }
                        case let .branch(branch, leafName):
                            LocalBranchRowView(
                                tab: tab,
                                branch: branch,
                                displayName: leafName,
                                depth: row.depth
                            )
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "LOCAL BRANCHES") {
                    [.item("New Branch…") {
                        tab.newBranchStartPoint = nil
                        tab.isShowingNewBranchSheet = true
                    }]
                }
            }

            do {
                Section(isExpanded: $isRemotesExpanded) {
                    if isRemotesExpanded {
                        if tab.remotes.isEmpty {
                            Text("No remotes")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(remoteBranchRows) { row in
                            switch row.kind {
                            case let .folder(name, folderID, isExpanded):
                                BranchFolderRowView(
                                    name: name,
                                    depth: row.depth,
                                    isExpanded: isExpanded,
                                    isTopLevelRemote: row.depth == 0
                                ) {
                                    toggleFolder(folderID)
                                }
                            case let .branch(branch, leafName):
                                RemoteBranchRowView(
                                    tab: tab,
                                    branch: branch,
                                    displayName: leafName,
                                    depth: row.depth
                                )
                            }
                        }
                    }
                } header: {
                    SectionHeaderLabel(title: "REMOTES") {
                        var entries: [HeaderMenuEntry] = [
                            .item("Add Remote…") {
                                tab.remotesSheetStartsAdding = true
                                tab.isShowingRemotesSheet = true
                            },
                            .item("Manage Remotes…", enabled: !tab.remotes.isEmpty) {
                                tab.remotesSheetStartsAdding = false
                                tab.isShowingRemotesSheet = true
                            },
                        ]
                        if !tab.remotes.isEmpty {
                            entries.append(.separator)
                            for remote in tab.remotes {
                                entries.append(.item("Fetch \(remote.name)", enabled: !tab.isBusy) {
                                    tab.fetchRemote(remote.name)
                                })
                            }
                        }
                        return entries
                    }
                }
            }

            Section(isExpanded: $isTagsExpanded) {
                if isTagsExpanded {
                    if tab.tags.isEmpty {
                        Text("No tags")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tab.tags, id: \.fullRef) { tag in
                            HStack(spacing: 6) {
                                Image(systemName: "tag")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .frame(width: 16, alignment: .center)
                                Text(tag.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                tab.scrollToCommit(oidHex: tag.targetOidHex)
                            }
                            .contextMenu {
                                Button("Push \(tag.name) to origin") {
                                    tab.pushTag(tag.name)
                                }
                                Divider()
                                Button("Delete \(tag.name) (Local)…", role: .destructive) {
                                    tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: false)
                                }
                                Button("Delete \(tag.name) (Local & Remote)…", role: .destructive) {
                                    tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: true)
                                }
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "TAGS") {
                    [.item("New Tag…") {
                        tab.newTagTarget = nil
                        tab.isShowingNewTagSheet = true
                    }]
                }
            }

            Section(isExpanded: $isStashesExpanded) {
                if isStashesExpanded {
                    if tab.stashes.isEmpty {
                        Text("No stashes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tab.stashes, id: \.index) { stash in
                            HStack(spacing: 6) {
                                Image(systemName: "tray.and.arrow.down")
                                    .foregroundStyle(.purple)
                                    .font(.caption)
                                    .frame(width: 16, alignment: .center)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(stash.message)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text(stash.name)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Pop \(stash.name)") {
                                    tab.stashPop(stash.index)
                                }
                                Button("Apply \(stash.name)") {
                                    tab.stashApply(stash.index)
                                }
                                Divider()
                                Button("Drop \(stash.name)", role: .destructive) {
                                    tab.stashDrop(stash.index)
                                }
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(title: "STASHES") {
                    [.item("Stash Changes…", enabled: tab.totalChangesCount > 0 && !tab.isBusy) {
                        tab.isShowingStashSheet = true
                    }]
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct FlatBranchRow: Identifiable {
    enum Kind {
        case folder(name: String, folderID: String, isExpanded: Bool)
        case branch(branch: BranchInfo, leafName: String)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

final class BranchTreeNode {
    let name: String
    let pathID: String
    var branch: BranchInfo?
    var children: [BranchTreeNode] = []

    init(name: String, pathID: String, branch: BranchInfo? = nil) {
        self.name = name
        self.pathID = pathID
        self.branch = branch
    }

    var isFolder: Bool {
        !children.isEmpty
    }

    func insert(parts: ArraySlice<String>, branch: BranchInfo, scope: String, currentPath: String) {
        guard let first = parts.first else { return }
        let nextPath = currentPath.isEmpty ? "\(scope):\(first)" : "\(currentPath)/\(first)"
        let remaining = parts.dropFirst()

        if remaining.isEmpty {
            let leaf = BranchTreeNode(name: first, pathID: "leaf:\(branch.fullRef)", branch: branch)
            children.append(leaf)
        } else {
            if let existingFolder = children.first(where: { $0.isFolder && $0.name == first }) {
                existingFolder.insert(parts: remaining, branch: branch, scope: scope, currentPath: nextPath)
            } else {
                let folder = BranchTreeNode(name: first, pathID: "folder:\(nextPath)")
                folder.insert(parts: remaining, branch: branch, scope: scope, currentPath: nextPath)
                children.append(folder)
            }
        }
    }

    func sortTree() {
        for child in children where child.isFolder {
            child.sortTree()
        }
        // Keep root-level direct branches (e.g. main) above folders, or sort alphabetically within each group.
        children.sort { a, b in
            if a.isFolder != b.isFolder {
                return !a.isFolder
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func buildFlattenedRows(
        from branches: [BranchInfo],
        scope: String,
        collapsedFolderIDs: Set<String>
    ) -> [FlatBranchRow] {
        let root = BranchTreeNode(name: "", pathID: scope)
        for branch in branches {
            let parts = branch.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            root.insert(parts: ArraySlice(parts), branch: branch, scope: scope, currentPath: "")
        }
        root.sortTree()

        var rows: [FlatBranchRow] = []
        func flatten(nodes: [BranchTreeNode], depth: Int) {
            for node in nodes {
                if node.isFolder {
                    let isExpanded = !collapsedFolderIDs.contains(node.pathID)
                    rows.append(
                        FlatBranchRow(
                            id: node.pathID,
                            depth: depth,
                            kind: .folder(name: node.name, folderID: node.pathID, isExpanded: isExpanded)
                        )
                    )
                    if isExpanded {
                        flatten(nodes: node.children, depth: depth + 1)
                    }
                } else if let branch = node.branch {
                    rows.append(
                        FlatBranchRow(
                            id: node.pathID,
                            depth: depth,
                            kind: .branch(branch: branch, leafName: node.name)
                        )
                    )
                }
            }
        }
        flatten(nodes: root.children, depth: 0)
        return rows
    }
}

private struct BranchFolderRowView: View {
    let name: String
    let depth: Int
    let isExpanded: Bool
    let isTopLevelRemote: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .center)

            Image(systemName: isTopLevelRemote ? "icloud" : "folder")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16, alignment: .center)

            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

private struct LocalBranchRowView: View {
    @ObservedObject var tab: RepoTab
    let branch: BranchInfo
    let displayName: String
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            // Align leaf branch icon under folder icon when nested, or flush when top-level
            Image(systemName: branch.isHead ? "checkmark" : "arrow.triangle.branch")
                .foregroundStyle(branch.isHead ? Color.primary : Color.secondary)
                .font(.system(size: 11, weight: branch.isHead ? .bold : .regular))
                .frame(width: 16, alignment: .center)

            Text(displayName)
                .fontWeight(branch.isHead ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if branch.isMerged {
                Text("merged")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
                    .help("Fully merged into origin's default branch")
            }

            if branch.ahead > 0 || branch.behind > 0 {
                HStack(spacing: 4) {
                    if branch.ahead > 0 {
                        Text("↑\(branch.ahead)")
                    }
                    if branch.behind > 0 {
                        Text("↓\(branch.behind)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + (depth > 0 ? 15 : 0))
        .contentShape(Rectangle())
        // Single tap must fire immediately; a count:1 gesture declared next to a
        // count:2 one makes SwiftUI wait out the double-click interval first.
        .onTapGesture {
            tab.scrollToCommit(oidHex: branch.targetOidHex)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                tab.checkoutBranch(branch.name)
            }
        )
        .contextMenu {
            if !branch.isHead {
                Button("Checkout \(branch.name)") {
                    tab.checkoutBranch(branch.name)
                }
                Button("Merge \(branch.name) into Current") {
                    tab.mergeBranch(branch.name)
                }
            }
            Button("New Branch from \(branch.name)…") {
                tab.newBranchStartPoint = branch.name
                tab.isShowingNewBranchSheet = true
            }
            if !branch.isHead {
                Divider()
                Button("Delete \(branch.name)…", role: .destructive) {
                    tab.pendingConfirmation = .deleteBranch(name: branch.name, force: false)
                }
            }
        }
    }
}

private struct RemoteBranchRowView: View {
    @ObservedObject var tab: RepoTab
    let branch: BranchInfo
    let displayName: String
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16, alignment: .center)

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14 + (depth > 0 ? 15 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            tab.scrollToCommit(oidHex: branch.targetOidHex)
        }
    }
}

enum HeaderMenuEntry {
    case item(String, enabled: Bool = true, action: () -> Void)
    case separator
}

/// Section title row with a right-click menu. The menu is a plain `NSMenu`, because
/// SwiftUI's `.contextMenu` makes macOS append a system "Ask Siri" item on text rows.
private struct SectionHeaderLabel: View {
    let title: String
    let entries: () -> [HeaderMenuEntry]

    init(title: String, entries: @escaping () -> [HeaderMenuEntry]) {
        self.title = title
        self.entries = entries
    }

    var body: some View {
        // The disclosure chevron is drawn natively by the sidebar `Section(isExpanded:)`.
        HStack {
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .overlay(RightClickMenuArea(entries: entries))
    }
}

private struct RightClickMenuArea: NSViewRepresentable {
    let entries: () -> [HeaderMenuEntry]

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.entries = entries
    }
}

private final class RightClickView: NSView {
    var entries: () -> [HeaderMenuEntry] = { [] }

    /// Only claim right-clicks (and ctrl-clicks) so hover and left-clicks still reach
    /// the sidebar's native disclosure chevron underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            return super.hitTest(point)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(for: event) } else { super.mouseDown(with: event) }
    }

    private func showMenu(for event: NSEvent) {
        let entries = entries()
        guard !entries.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .item(title, enabled, action):
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target // keeps the target alive while the menu is open
                item.isEnabled = enabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        // popUp(...) rather than popUpContextMenu: the latter lets the system append
        // its own items (Ask Siri, Services).
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
}

private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

struct RemotesSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newURL = ""
    @State private var pendingRemoval: RemoteInfo?
    @FocusState private var isNewNameFocused: Bool

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !tab.isBusy
    }

    private func add() {
        guard canAdd else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        tab.addRemote(name: name, url: url) {
            newName = ""
            newURL = ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remotes")
                .font(.headline)

            if tab.remotes.isEmpty {
                Text("This repository has no remotes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(tab.remotes, id: \.name) { remote in
                        RemoteEditRow(tab: tab, remote: remote) {
                            pendingRemoval = remote
                        }
                        .id("\(remote.name)|\(remote.fetchUrl)")
                    }
                }
            }

            Divider()

            Text("Add Remote")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("Name (e.g. origin)", text: $newName)
                    .frame(width: 140)
                    .focused($isNewNameFocused)
                TextField("URL", text: $newURL)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!canAdd)
            }
            .textFieldStyle(.roundedBorder)

            if let error = tab.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Done") {
                    tab.errorMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            tab.errorMessage = nil
            if tab.remotesSheetStartsAdding || tab.remotes.isEmpty {
                isNewNameFocused = true
            }
        }
        .confirmationDialog(
            "Remove remote \"\(pendingRemoval?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { remote in
            Button("Remove", role: .destructive) {
                tab.removeRemote(remote.name)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This removes the remote and its remote-tracking branches from this repository. Local branches are kept. Nothing is changed on the server.")
        }
    }
}

private struct RemoteEditRow: View {
    @ObservedObject var tab: RepoTab
    let remote: RemoteInfo
    let onRemove: () -> Void
    @State private var name: String
    @State private var url: String

    init(tab: RepoTab, remote: RemoteInfo, onRemove: @escaping () -> Void) {
        self.tab = tab
        self.remote = remote
        self.onRemove = onRemove
        _name = State(initialValue: remote.name)
        _url = State(initialValue: remote.fetchUrl)
    }

    private var hasSeparatePushURL: Bool { remote.pushUrl != remote.fetchUrl }

    private var isChanged: Bool {
        name.trimmingCharacters(in: .whitespaces) != remote.name
            || url.trimmingCharacters(in: .whitespaces) != remote.fetchUrl
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .frame(width: 140)
                TextField("URL", text: $url)
                Button("Save") {
                    tab.updateRemote(remote, newName: name, newURL: url)
                }
                .disabled(!isChanged || !isValid || tab.isBusy)
                Button {
                    tab.fetchRemote(remote.name)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Fetch \(remote.name) (and prune deleted branches)")
                .disabled(tab.isBusy)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .help("Remove remote")
                .disabled(tab.isBusy)
            }
            .textFieldStyle(.roundedBorder)
            if hasSeparatePushURL {
                Text("Push URL: \(remote.pushUrl) (set separately; Save replaces both URLs)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct NewStashSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stash Changes")
                .font(.headline)

            TextField("Optional stash message…", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Toggle("Include untracked files", isOn: $includeUntracked)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stash") {
                    tab.stashPush(message: message, includeUntracked: includeUntracked)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

struct NewBranchSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var checkout = true
    @State private var localChanges: RepoTab.LocalChangesHandling = .stashAndReapply
    @FocusState private var isBranchNameFocused: Bool

    private var startPointDisplay: String {
        if let start = tab.newBranchStartPoint {
            // Shorten 40-char commit SHAs for display while keeping branch names intact.
            if start.count == 40, start.allSatisfy(\.isHexDigit) {
                return String(start.prefix(7))
            }
            return start
        }
        return tab.currentBranch.isEmpty ? "HEAD" : tab.currentBranch
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create Branch")
                        .font(.system(size: 14, weight: .bold))
                    Text("Create new branch")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Create branch at:")
                            .font(.system(size: 13))
                            .gridColumnAlignment(.trailing)

                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(startPointDisplay)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    GridRow {
                        Text("Branch name:")
                            .font(.system(size: 13))

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                TextField("Enter Branch Name", text: $branchName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .focused($isBranchNameFocused)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(width: 310)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        isBranchNameFocused
                                            ? Color.accentColor.opacity(0.65)
                                            : Color(nsColor: .separatorColor),
                                        lineWidth: isBranchNameFocused ? 2.5 : 1
                                    )
                            )

                            Toggle("Check out after create", isOn: $checkout)
                                .font(.system(size: 13))
                        }
                    }

                    GridRow(alignment: .top) {
                        Text("Local changes:")
                            .font(.system(size: 13))
                            .foregroundStyle(checkout ? .primary : .tertiary)

                        Picker("", selection: $localChanges) {
                            Text("Don't change")
                                .tag(RepoTab.LocalChangesHandling.doNotChange)
                            Text("Stash and reapply")
                                .tag(RepoTab.LocalChangesHandling.stashAndReapply)
                            Text("Discard")
                                .tag(RepoTab.LocalChangesHandling.discard)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .disabled(!checkout)
                    }
                }
                .padding(.top, 2)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                    Button(checkout ? "Create and Checkout" : "Create") {
                        tab.createBranch(
                            name: branchName,
                            startPoint: tab.newBranchStartPoint,
                            checkout: checkout,
                            localChanges: localChanges
                        )
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .onAppear {
            isBranchNameFocused = true
        }
    }
}

struct NewTagSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var message = ""
    @State private var pushToRemote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Tag")
                .font(.headline)

            if let target = tab.newTagTarget {
                Text("Target commit: \(String(target.prefix(7)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Target: HEAD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Tag name (e.g. v1.0.0)", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            TextField("Optional annotation message…", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Toggle("Push tag to origin", isOn: $pushToRemote)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Tag") {
                    tab.createTag(
                        name: tagName,
                        target: tab.newTagTarget,
                        message: message,
                        pushToRemote: pushToRemote
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

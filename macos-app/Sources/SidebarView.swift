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
            Section {
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
                CollapsibleSectionHeader(title: "WORKING TREE", isExpanded: $isWorkingTreeExpanded)
            }

            Section {
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
                CollapsibleSectionHeader(title: "LOCAL BRANCHES", isExpanded: $isLocalBranchesExpanded) {
                    Button {
                        tab.newBranchStartPoint = nil
                        tab.isShowingNewBranchSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help("Create new branch")
                }
            }

            if !remoteBranches.isEmpty {
                Section {
                    if isRemotesExpanded {
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
                    CollapsibleSectionHeader(title: "REMOTES", isExpanded: $isRemotesExpanded)
                }
            }

            Section {
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
                CollapsibleSectionHeader(title: "TAGS", isExpanded: $isTagsExpanded) {
                    Button {
                        tab.newTagTarget = nil
                        tab.isShowingNewTagSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help("Create new tag")
                }
            }

            Section {
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
                CollapsibleSectionHeader(title: "STASHES", isExpanded: $isStashesExpanded) {
                    Button {
                        tab.isShowingStashSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .disabled(tab.totalChangesCount == 0 || tab.isBusy)
                    .help("Stash working changes")
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

private struct CollapsibleSectionHeader<Trailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.trailing = trailing
    }

    init(
        title: String,
        isExpanded: Binding<Bool>
    ) where Trailing == EmptyView {
        self.title = title
        self._isExpanded = isExpanded
        self.trailing = { EmptyView() }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10, alignment: .center)
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            trailing()
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

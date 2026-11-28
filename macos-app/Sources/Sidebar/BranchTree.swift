import Foundation

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

    private var sortRank: Int {
        if branch?.isDefault == true { return 0 }
        if isFolder { return 1 }
        return 2
    }

    func sortTree() {
        for child in children where child.isFolder {
            child.sortTree()
        }
        // Default branch first, then folders, then direct branches not in folders (alphabetically within each group).
        children.sort { a, b in
            if a.sortRank != b.sortRank {
                return a.sortRank < b.sortRank
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func buildFlattenedRows(
        from branches: [BranchInfo],
        scope: String,
        foldersStartCollapsed: Bool = false,
        expandFolders: Bool = false,
        toggledFolderIDs: Set<String>
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
                    // Filtering expands matching paths so nested results are always visible.
                    // Otherwise, `toggledFolderIDs` records folders flipped from their default.
                    let isExpanded = expandFolders || foldersStartCollapsed == toggledFolderIDs.contains(node.pathID)
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

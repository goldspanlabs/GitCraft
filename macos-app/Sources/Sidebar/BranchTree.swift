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

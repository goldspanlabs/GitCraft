import Foundation

struct FlatFileRow: Identifiable {
    enum Kind {
        case folder(name: String, folderPath: String, isExpanded: Bool)
        case file(change: FileChange, name: String)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

/// Groups changed files into folders and flattens the result into list rows.
enum FileTree {
    private struct Folder {
        var folders: [String: Folder] = [:]
        var files: [(name: String, change: FileChange)] = []

        mutating func insert(_ change: FileChange, parts: ArraySlice<Substring>) {
            guard let first = parts.first.map(String.init) else { return }
            if parts.count == 1 {
                files.append((first, change))
            } else {
                folders[first, default: Folder()].insert(change, parts: parts.dropFirst())
            }
        }
    }

    /// Folders come before files, each alphabetically. A folder whose only content is another
    /// folder shares its row with it, as in `a/b/c`.
    static func rows(from changes: [FileChange], collapsedFolderPaths: Set<String>) -> [FlatFileRow] {
        var root = Folder()
        for change in changes {
            root.insert(change, parts: ArraySlice(change.path.split(separator: "/")))
        }

        var rows: [FlatFileRow] = []
        func flatten(_ folder: Folder, parentPath: String, depth: Int) {
            for key in folder.folders.keys.sorted(by: inNameOrder) {
                var name = key
                var child = folder.folders[key]!
                while child.files.isEmpty, child.folders.count == 1, let only = child.folders.first {
                    name += "/\(only.key)"
                    child = only.value
                }
                let path = parentPath + name
                let isExpanded = !collapsedFolderPaths.contains(path)
                rows.append(
                    FlatFileRow(
                        // The trailing slash keeps a folder's id apart from any file's path.
                        id: path + "/",
                        depth: depth,
                        kind: .folder(name: name, folderPath: path, isExpanded: isExpanded)
                    )
                )
                if isExpanded {
                    flatten(child, parentPath: path + "/", depth: depth + 1)
                }
            }
            for file in folder.files.sorted(by: { inNameOrder($0.name, $1.name) }) {
                rows.append(
                    FlatFileRow(
                        id: file.change.path,
                        depth: depth,
                        kind: .file(change: file.change, name: file.name)
                    )
                )
            }
        }
        flatten(root, parentPath: "", depth: 0)
        return rows
    }

    /// One tree on screen: its changes and which of its folders are closed.
    struct List {
        let changes: [FileChange]
        let collapsedFolderPaths: Set<String>
    }

    /// The file an up (`delta` < 0) or down (`delta` > 0) arrow press should select, running
    /// through the lists top to bottom, or nil when there is no visible file that way. With
    /// nothing selected, down picks the first file and up the last. A selection inside a
    /// collapsed folder still counts from where it sits.
    static func file(
        movingBy delta: Int,
        through lists: [List],
        from isSelected: (FileChange) -> Bool
    ) -> FileChange? {
        let all = lists.flatMap { files(in: $0.changes) }
        let visible = Set(lists.flatMap { files(in: $0.changes, collapsedFolderPaths: $0.collapsedFolderPaths) })
        let candidates: [FileChange]
        if let index = all.firstIndex(where: isSelected) {
            candidates = delta > 0 ? Array(all[(index + 1)...]) : all[..<index].reversed()
        } else {
            candidates = delta > 0 ? all : all.reversed()
        }
        return candidates.first { visible.contains($0) }
    }

    /// The files shown, top to bottom.
    static func files(in changes: [FileChange], collapsedFolderPaths: Set<String> = []) -> [FileChange] {
        rows(from: changes, collapsedFolderPaths: collapsedFolderPaths).compactMap { row in
            if case let .file(change, _) = row.kind { return change }
            return nil
        }
    }

    private static func inNameOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}

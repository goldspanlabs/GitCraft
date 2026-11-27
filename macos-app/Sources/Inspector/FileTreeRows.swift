import SwiftUI

private enum FileTreeMetrics {
    static let indent: CGFloat = 14
    static let chevronWidth: CGFloat = 10
}

/// The rows of a file tree, for the enclosing lazy stack. Not a stack of its own: that would
/// build every row at once.
struct FileTreeRows<FileRow: View, FolderControl: View>: View {
    let changes: [FileChange]
    @Binding var collapsedFolderPaths: Set<String>
    /// Keeps row ids apart when two trees share a stack. A file's row id, which the list
    /// scrolls to, is this followed by its path.
    var idPrefix = ""
    /// Margin between the pane edge and the row highlight (matches the 10pt header inset).
    var edgeInset: CGFloat = 10
    /// A control ahead of a folder's icon, such as a staging checkbox, given the folder's path.
    @ViewBuilder let folderControl: (String) -> FolderControl
    /// Draws a file, given its name within its folder and its depth in the tree.
    @ViewBuilder let fileRow: (FileChange, String, Int) -> FileRow

    private struct Item: Identifiable {
        let id: String
        let row: FlatFileRow
    }

    private var items: [Item] {
        FileTree.rows(from: changes, collapsedFolderPaths: collapsedFolderPaths).map {
            Item(id: idPrefix + $0.id, row: $0)
        }
    }

    var body: some View {
        ForEach(items) { item in
            Group {
                switch item.row.kind {
                case let .folder(name, folderPath, isExpanded):
                    FileTreeFolderRow(
                        name: name,
                        path: folderPath,
                        isExpanded: isExpanded,
                        depth: item.row.depth,
                        collapsedFolderPaths: $collapsedFolderPaths,
                        leading: { folderControl(folderPath) }
                    )
                case let .file(change, name):
                    fileRow(change, name, item.row.depth)
                }
            }
            .padding(.horizontal, edgeInset)
        }
    }
}

/// A folder in a file tree. Clicking it expands or collapses it.
private struct FileTreeFolderRow<Leading: View>: View {
    let name: String
    let path: String
    let isExpanded: Bool
    let depth: Int
    @Binding var collapsedFolderPaths: Set<String>
    @ViewBuilder var leading: () -> Leading

    private func toggle() {
        if isExpanded {
            collapsedFolderPaths.insert(path)
        } else {
            collapsedFolderPaths.remove(path)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: FileTreeMetrics.chevronWidth)
            // Outside the button, so a click on it doesn't also open or close the folder.
            leading()
            Button(action: toggle) {
                HStack(spacing: 6) {
                    PhosphorIcon(glyph: .folder, size: 14)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .fileTreeRowPadding(depth: depth)
        // The chevron and the row's margins open and close it too.
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help(path)
    }
}

/// A file's status badge and name, indented to its place in the tree.
struct FileTreeFileLabel<Leading: View>: View {
    let change: FileChange
    let name: String
    let depth: Int
    let isSelected: Bool
    /// A control ahead of the badge, such as a staging checkbox.
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 6) {
            // Stands in for a folder's chevron, so what follows lines up with sibling folder icons.
            Color.clear.frame(width: FileTreeMetrics.chevronWidth, height: 1)
            leading()
            StatusBadge(status: change.status)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .fileTreeRowPadding(depth: depth)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
    }
}

private extension View {
    func fileTreeRowPadding(depth: Int) -> some View {
        padding(.leading, CGFloat(depth) * FileTreeMetrics.indent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

import SwiftUI

private enum FileTreeMetrics {
    static let indent: CGFloat = 14
    static let chevronWidth: CGFloat = 10
}

/// The rows of a file tree, for the enclosing lazy stack. Not a stack of its own: that would
/// build every row at once.
struct FileTreeRows<FileRow: View>: View {
    let changes: [FileChange]
    @Binding var collapsedFolderPaths: Set<String>
    /// Keeps row ids apart when two trees share a stack. A file's row id, which the list
    /// scrolls to, is this followed by its path.
    var idPrefix = ""
    /// Margin between the pane edge and the row highlight (matches the 10pt header inset).
    var edgeInset: CGFloat = 10
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
                        collapsedFolderPaths: $collapsedFolderPaths
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
private struct FileTreeFolderRow: View {
    let name: String
    let path: String
    let isExpanded: Bool
    let depth: Int
    @Binding var collapsedFolderPaths: Set<String>

    var body: some View {
        Button {
            if isExpanded {
                collapsedFolderPaths.insert(path)
            } else {
                collapsedFolderPaths.remove(path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: FileTreeMetrics.chevronWidth)
                PhosphorIcon(glyph: .folder, size: 14)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .fileTreeRowPadding(depth: depth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
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

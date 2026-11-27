import SwiftUI

struct NewStashSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = true
    @FocusState private var isMessageFocused: Bool

    private var branchDisplay: String {
        tab.currentBranchLabel
    }

    private var changesSummary: String {
        let count = tab.totalChangesCount
        return count == 1 ? "1 changed file" : "\(count) changed files"
    }

    var body: some View {
        ActionSheetLayout(
            title: "Stash Changes",
            subtitle: "Save uncommitted working tree changes to a new stash entry.",
            confirmLabel: "Stash",
            onCancel: { dismiss() },
            onConfirm: stashNow
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    SheetFieldLabel("Branch:")

                    HStack(spacing: 5) {
                        PhosphorIcon(glyph: .branch)
                            .foregroundStyle(.secondary)
                        Text(branchDisplay)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(branchDisplay)
                        if tab.totalChangesCount > 0 {
                            Text("· \(changesSummary)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    SheetFieldLabel("Message:")
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 5) {
                        SheetInputBox(isFocused: isMessageFocused) {
                            PhosphorIcon(glyph: .archive)
                                .foregroundStyle(.secondary)
                            TextField("Optional stash message…", text: $message)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($isMessageFocused)
                        }
                        .frame(minWidth: 330, maxWidth: .infinity)

                        Text("Leave blank to use the default WIP description.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow {
                    Color.clear
                        .frame(width: 1, height: 1)

                    Toggle("Include untracked files", isOn: $includeUntracked)
                        .font(.system(size: 13))
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            isMessageFocused = true
        }
    }

    private func stashNow() {
        tab.stashPush(message: message, includeUntracked: includeUntracked)
        dismiss()
    }
}

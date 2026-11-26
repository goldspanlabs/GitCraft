import SwiftUI

struct NewTagSheet: View {
    private enum Field {
        case tagName
        case message
    }

    @ObservedObject var tab: RepoTab
    let target: String?
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var message = ""
    @State private var pushToRemote = true
    @FocusState private var focusedField: Field?

    private var trimmedTagName: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetCommit: CommitRow? {
        guard let target else { return nil }
        return tab.commits.first { $0.oidHex == target }
    }

    private var headDisplay: String {
        tab.currentBranch.isEmpty ? "HEAD" : tab.currentBranch
    }

    private var defaultRemoteName: String {
        tab.remotes.first(where: { $0.name == "origin" })?.name
            ?? tab.remotes.first?.name
            ?? "origin"
    }

    var body: some View {
        ActionSheetLayout(
            title: "Create Tag",
            subtitle: "Tag a commit to mark a release or milestone.",
            confirmLabel: "Create Tag",
            confirmDisabled: trimmedTagName.isEmpty,
            onCancel: { dismiss() },
            onConfirm: createTag
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    SheetFieldLabel("Target:")

                    if let target {
                        CommitPreviewRow(oid: target, commit: targetCommit)
                    } else {
                        HStack(spacing: 5) {
                            PhosphorIcon(glyph: .branch)
                                .foregroundStyle(.secondary)
                            Text(headDisplay)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GridRow {
                    SheetFieldLabel("Tag name:")

                    SheetInputBox(isFocused: focusedField == .tagName) {
                        PhosphorIcon(glyph: .tag)
                            .foregroundStyle(.secondary)
                        TextField("v1.0.0", text: $tagName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focusedField, equals: .tagName)
                    }
                    .frame(minWidth: 330, maxWidth: .infinity)
                }

                GridRow(alignment: .top) {
                    SheetFieldLabel("Message:")
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 5) {
                        SheetInputBox(isFocused: focusedField == .message, verticalPadding: 6) {
                            TextField("Optional annotation message…", text: $message, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .lineLimit(3...5)
                                .focused($focusedField, equals: .message)
                        }
                        .frame(minWidth: 330, maxWidth: .infinity, alignment: .topLeading)

                        Text("Leave blank to create a lightweight tag.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow {
                    Color.clear
                        .frame(width: 1, height: 1)

                    Toggle(
                        tab.remotes.isEmpty
                            ? "Push tag to remote (no remotes configured)"
                            : "Push tag to \(defaultRemoteName)",
                        isOn: $pushToRemote
                    )
                    .font(.system(size: 13))
                    .disabled(tab.remotes.isEmpty)
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            focusedField = .tagName
            if tab.remotes.isEmpty {
                pushToRemote = false
            }
        }
    }

    private func createTag() {
        guard !trimmedTagName.isEmpty else { return }
        tab.createTag(
            name: tagName,
            target: target,
            message: message,
            pushToRemote: pushToRemote && !tab.remotes.isEmpty
        )
        dismiss()
    }
}

import SwiftUI

struct NewBranchSheet: View {
    @ObservedObject var tab: RepoTab
    let startPoint: String?
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    // Remembered between uses of the dialog.
    @AppStorage("createBranchCheckout") private var checkout = true
    @State private var localChanges: RepoTab.LocalChangesHandling = .stashAndReapply
    @State private var confirmDiscard = false
    @FocusState private var isBranchNameFocused: Bool

    private var startPointDisplay: String {
        if let start = startPoint {
            // Shorten 40-char commit SHAs for display while keeping branch names intact.
            if start.count == 40, start.allSatisfy(\.isHexDigit) {
                return String(start.prefix(7))
            }
            return start
        }
        return tab.currentBranch.isEmpty ? "HEAD" : tab.currentBranch
    }

    var body: some View {
        ActionSheetLayout(
            title: "Create Branch",
            subtitle: "Create new branch",
            showsAppIcon: false,
            confirmLabel: checkout ? "Create and Checkout" : "Create",
            confirmDisabled: branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onCancel: { dismiss() },
            onConfirm: {
                if checkout && localChanges == .discard && tab.totalChangesCount > 0 {
                    confirmDiscard = true
                } else {
                    createBranchNow()
                }
            }
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Create branch at:")
                        .font(.system(size: 13))
                        .gridColumnAlignment(.trailing)

                    HStack(spacing: 5) {
                        PhosphorIcon(glyph: .branch)
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
                            PhosphorIcon(glyph: .branch)
                                .foregroundStyle(.secondary)
                            TextField("Enter Branch Name", text: $branchName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($isBranchNameFocused)
                                .onChange(of: branchName) { _, newValue in
                                    // Git forbids spaces; swap them as the user types.
                                    if let replacement = BranchSpaceReplacement.current.replacement,
                                       newValue.contains(" ")
                                    {
                                        branchName = newValue.replacingOccurrences(of: " ", with: replacement)
                                    }
                                }
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

                    LocalChangesPicker(selection: $localChanges, disabled: !checkout)
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            isBranchNameFocused = true
        }
        .discardLocalChangesConfirmation(
            isPresented: $confirmDiscard,
            changedCount: tab.totalChangesCount,
            actionLabel: "Discard Changes and Create",
            onConfirm: createBranchNow
        )
    }

    private func createBranchNow() {
        tab.createBranch(
            name: branchName,
            startPoint: startPoint,
            checkout: checkout,
            localChanges: localChanges
        )
        dismiss()
    }
}

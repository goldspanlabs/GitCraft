import SwiftUI

/// Checks a commit out detached, after asking what to do with local changes.
struct CheckoutCommitSheet: View {
    @ObservedObject var tab: RepoTab
    let oid: String
    @Environment(\.dismiss) private var dismiss
    @State private var localChanges: RepoTab.LocalChangesHandling = .doNotChange
    @State private var confirmDiscard = false

    private var commit: CommitRow? {
        tab.commits.first { $0.oidHex == oid }
    }

    var body: some View {
        ActionSheetLayout(
            title: "Checkout Commit",
            subtitle: "Checkout a particular commit. Repository will be in detached HEAD state",
            confirmLabel: "Checkout",
            onCancel: { dismiss() },
            onConfirm: {
                if localChanges == .discard && tab.totalChangesCount > 0 {
                    confirmDiscard = true
                } else {
                    checkoutNow()
                }
            }
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Commit to checkout:")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)

                    CommitPreviewRow(oid: oid, commit: commit)
                }

                GridRow(alignment: .top) {
                    Text("Local changes:")
                        .font(.system(size: 13))

                    LocalChangesPicker(selection: $localChanges)
                }
            }
            .padding(.top, 2)
        }
        .discardLocalChangesConfirmation(
            isPresented: $confirmDiscard,
            changedCount: tab.totalChangesCount,
            actionLabel: "Discard Changes and Checkout",
            onConfirm: checkoutNow
        )
    }

    private func checkoutNow() {
        tab.checkoutCommit(oid, localChanges: localChanges)
        dismiss()
    }
}

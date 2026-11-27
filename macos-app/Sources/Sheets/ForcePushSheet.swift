import SwiftUI

/// Confirms replacing a remote branch whose commits were rewritten here.
struct ForcePushSheet: View {
    @ObservedObject var tab: RepoTab
    let plan: ForcePushPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ActionSheetLayout(
            title: "Force push \"\(plan.branch)\"?",
            subtitle: "\(plan.destination) will be replaced.",
            confirmLabel: "Force Push",
            confirmDisabled: tab.isBusy,
            cancelIsDefault: true,
            onCancel: { dismiss() },
            onConfirm: {
                tab.forcePush(plan)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    column("Removed from remote", plan.removed)
                    column("Added", plan.added)
                }

                if plan.isDefaultBranch {
                    Label("\"\(plan.branch)\" is the default branch.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 520)
        }
    }

    private func column(_ title: String, _ commits: [PushCommit]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(commits.count))")
                .font(.system(size: 12, weight: .semibold))

            CommitListPanel(
                items: commits.map { .init(oid: $0.oidHex, shortOid: $0.shortOid, summary: $0.summary) },
                // Both columns share the height of the longer list.
                rows: max(plan.removed.count, plan.added.count, 1),
                limit: 8
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

/// Merge a commit into the checked-out branch, with the merge type and a conflict preview.
struct MergeCommitSheet: View {
    @ObservedObject var tab: RepoTab
    let oid: String
    @Environment(\.dismiss) private var dismiss
    @State private var mergeType: MergeType = .default
    /// nil until the check finishes, or when git couldn't run it.
    @State private var hasConflicts: Bool?
    @State private var conflictCheckFinished = false

    private var commit: CommitRow? {
        tab.commits.first { $0.oidHex == oid }
    }

    var body: some View {
        ActionSheetLayout(
            title: "Merge",
            subtitle: "Merge a commit into the checked-out branch",
            confirmLabel: "Merge",
            onCancel: { dismiss() },
            onConfirm: {
                tab.mergeCommit(oid, mergeType: mergeType)
                dismiss()
            }
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Merge:")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)

                    CommitPreviewRow(oid: oid, commit: commit)
                }

                GridRow {
                    Text("Into:")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                    Text(tab.currentBranch)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 330, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    Text("Merge Type:")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $mergeType) {
                            Text("Default (fast-forward if possible)").tag(MergeType.default)
                            Text("No fast-forward (always create a merge commit)").tag(MergeType.noFastForward)
                            Text("Fast-forward only").tag(MergeType.fastForwardOnly)
                            Text("Squash (stage the changes, don't commit)").tag(MergeType.squash)
                        }
                        .labelsHidden()
                        .frame(width: 330, alignment: .leading)

                        if mergeType == .squash {
                            Text("The changes are staged. Commit them yourself.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 2)

            conflictStatus
                .font(.system(size: 12))
        }
        .task(id: oid) {
            hasConflicts = await tab.checkMergeConflicts(oid)
            conflictCheckFinished = true
        }
    }

    @ViewBuilder
    private var conflictStatus: some View {
        if !conflictCheckFinished {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for conflicts…")
                    .foregroundStyle(.secondary)
            }
        } else if hasConflicts == true {
            Label("Merge will have conflicts to resolve", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if hasConflicts == false {
            Label("Merge can be done without conflicts", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

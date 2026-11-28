import SwiftUI

/// Confirms the exact direction of a branch/commit drop. Option is an accelerator; the
/// operation picker makes rebase discoverable without knowing the modifier.
struct GitDropSheet: View {
    @ObservedObject var tab: RepoTab
    let plan: GitDropPlan
    @Environment(\.dismiss) private var dismiss
    @State private var action: GitDropAction

    init(tab: RepoTab, plan: GitDropPlan) {
        self.tab = tab
        self.plan = plan
        _action = State(initialValue: plan.action)
    }

    private var message: String {
        switch action {
        case .rebase: return "Rebase \(plan.payload.branch) onto \(plan.payload.label)"
        case .merge: return "Merge \(plan.payload.label) into \(plan.payload.branch)"
        default: return plan.message
        }
    }

    var body: some View {
        ActionSheetLayout(title: action.rawValue, subtitle: message,
                          confirmLabel: action.rawValue, confirmDisabled: tab.isBusy,
                          onCancel: { dismiss() }, onConfirm: {
                              tab.executeGitDrop(plan, action: action)
                              dismiss()
                          }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Source: \(plan.payload.label) (\(plan.payload.oids[0].prefix(7)))")
                Text("Checked-out branch: \(plan.payload.branch)")
                if plan.payload.sourceRef != nil {
                    Picker("Operation", selection: $action) {
                        Text("Merge").tag(GitDropAction.merge)
                        Text("Rebase").tag(GitDropAction.rebase)
                    }
                    .accessibilityIdentifier("git-drop-operation")
                }
                if action == .rebase {
                    Label("Rewrites commits on \(plan.payload.branch). Published commits may need a force push.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Commit or stash local changes before integrating. Conflicts may need resolution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 440, alignment: .leading)
            .accessibilityIdentifier("git-drop-preview")
        }
    }
}

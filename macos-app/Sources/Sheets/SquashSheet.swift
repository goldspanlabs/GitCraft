import SwiftUI

/// Confirms a squash and takes the combined commit's message.
struct SquashSheet: View {
    private enum Field {
        case summary
        case description
    }

    @ObservedObject var tab: RepoTab
    let preview: SquashPreview
    let expectedCheckout: String?
    @State private var fixup: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var summary: String
    @State private var description: String
    @FocusState private var focusedField: Field?

    init(tab: RepoTab, preview: SquashPreview, fixup: Bool = false, expectedCheckout: String? = nil) {
        self.tab = tab
        self.preview = preview
        self.expectedCheckout = expectedCheckout
        _fixup = State(initialValue: fixup)
        let draft = SquashMessage.draft(for: preview.commits, fixup: fixup)
        _summary = State(initialValue: draft.summary)
        _description = State(initialValue: draft.description)
    }

    private var branch: String {
        (preview.head.branch ?? "").replacingOccurrences(of: "refs/heads/", with: "")
    }

    var body: some View {
        ActionSheetLayout(
            title: "\(fixup ? "Fixup" : "Squash") \(preview.commits.count) commits on \"\(branch)\"",
            subtitle: "Combine the selected commits into one.",
            confirmLabel: fixup ? "Fixup" : "Squash",
            confirmDisabled: summary.trimmed.isEmpty || tab.isBusy,
            onCancel: { dismiss() },
            onConfirm: {
                if let expectedCheckout, expectedCheckout != tab.activeCheckoutPath {
                    tab.showToast("The checkout changed. Start the drag again.")
                } else {
                    tab.squash(preview, summary: summary, description: description, fixup: fixup)
                }
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                commitList
                Text("Target: \(preview.commits[0].shortOid) — \(preview.commits[0].summary)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fixup — keep only the target commit message", isOn: $fixup)
                    .accessibilityIdentifier("squash-fixup")
                    .onChange(of: fixup) { _, value in
                        let draft = SquashMessage.draft(for: preview.commits, fixup: value)
                        summary = draft.summary
                        description = draft.description
                    }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        SheetFieldLabel("Summary:")
                        SheetInputBox(isFocused: focusedField == .summary) {
                            TextField("Commit summary", text: $summary)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($focusedField, equals: .summary)
                                .accessibilityIdentifier("squash-summary")
                        }
                    }
                    GridRow(alignment: .top) {
                        SheetFieldLabel("Description:")
                            .padding(.top, 5)
                        SheetInputBox(isFocused: focusedField == .description) {
                            TextEditor(text: $description)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(height: 110)
                                .focused($focusedField, equals: .description)
                                .accessibilityIdentifier("squash-description")
                        }
                    }
                }

                if preview.isPushed {
                    Label("Already pushed: needs a force push.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 460)
        }
        .onAppear { focusedField = .summary }
    }

    /// The commits being combined, oldest first.
    private var commitList: some View {
        CommitListPanel(
            items: preview.commits.map { .init(oid: $0.oidHex, shortOid: $0.shortOid, summary: $0.summary) },
            rows: preview.commits.count,
            limit: 6
        )
    }
}

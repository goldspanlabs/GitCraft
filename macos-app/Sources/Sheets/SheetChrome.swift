import AppKit
import SwiftUI

/// Shared macOS action-sheet chrome: title/subtitle header,
/// body content, and Cancel / Primary action buttons.
struct ActionSheetLayout<Content: View>: View {
    let title: String
    let subtitle: String
    let confirmLabel: String
    var confirmDisabled = false
    /// For actions that can't be taken back: Return cancels, and confirming takes a click.
    var cancelIsDefault = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()

                HStack(spacing: 10) {
                    Spacer()
                    if cancelIsDefault {
                        Button("Cancel", action: onCancel)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.large)

                        Button(confirmLabel, role: .destructive, action: onConfirm)
                            .controlSize(.large)
                            .disabled(confirmDisabled)
                    } else {
                        Button("Cancel", action: onCancel)
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.large)

                        Button(confirmLabel, action: onConfirm)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.large)
                            .disabled(confirmDisabled)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background {
            // A button takes one shortcut, so Escape needs its own when Cancel has Return.
            if cancelIsDefault {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Radio group for choosing what happens to uncommitted local changes during checkout or branch creation.
struct LocalChangesPicker: View {
    @Binding var selection: RepoTab.LocalChangesHandling
    var disabled = false

    var body: some View {
        Picker("", selection: $selection) {
            Text("Don't change")
                .tag(RepoTab.LocalChangesHandling.doNotChange)
            Text("Stash and reapply")
                .tag(RepoTab.LocalChangesHandling.stashAndReapply)
            Text("Discard")
                .tag(RepoTab.LocalChangesHandling.discard)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(disabled)
    }
}

/// One-line commit preview (`shortOid` + summary) used in commit-targeted sheets.
struct CommitPreviewRow: View {
    let oid: String
    let commit: CommitRow?

    var body: some View {
        HStack(spacing: 6) {
            Text(commit?.shortOid ?? oid.shortOid)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(commit?.summary ?? "")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 330, alignment: .leading)
    }
}

extension View {
    /// Confirmation dialog guarding sheets that offer a "Discard" local-changes option.
    func discardLocalChangesConfirmation(
        isPresented: Binding<Bool>,
        changedCount: Int,
        actionLabel: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Discard all local changes?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(actionLabel, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently reverts \(changedCount == 1 ? "1 changed file" : "\(changedCount) changed files") and deletes untracked files. It can't be undone.")
        }
    }
}

/// Right-aligned single-line field label for `Grid`-based action sheets.
struct SheetFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }
}

/// Rounded text-input container with focus ring used across action sheets.
struct SheetInputBox<Content: View>: View {
    let isFocused: Bool
    var verticalPadding: CGFloat = 5
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused
                        ? Color.accentColor.opacity(0.65)
                        : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 2.5 : 1
                )
        )
    }
}

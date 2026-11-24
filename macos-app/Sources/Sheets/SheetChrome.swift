import AppKit
import SwiftUI

/// The app icon matching the appearance: the light icon in light mode, the dark one in dark mode.
enum AppIconImage {
    static func image(for scheme: ColorScheme) -> NSImage {
        let name = scheme == .dark ? "AppIcon-Dark" : "AppIcon-Light"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }
}

/// Shared macOS action-sheet chrome: optional app icon, title/subtitle header,
/// body content, and Cancel / Primary action buttons.
struct ActionSheetLayout<Content: View>: View {
    let title: String
    let subtitle: String
    var showsAppIcon = true
    let confirmLabel: String
    var confirmDisabled = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if showsAppIcon {
                Image(nsImage: AppIconImage.image(for: colorScheme))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .padding(.top, 2)
            }

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
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)

                    Button(confirmLabel, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(confirmDisabled)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
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
            Text(commit?.shortOid ?? String(oid.prefix(7)))
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
            Text("This permanently reverts \(changedCount) changed file(s) and deletes untracked files. It can't be undone.")
        }
    }
}

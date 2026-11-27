import AppKit
import SwiftUI

/// Banner for an operation that is paused mid-way (merge or rebase).
struct OperationBanner: View {
    let title: String
    let abortLabel: String
    let onAbort: () -> Void
    var continueLabel: String?
    var onContinue: (() -> Void)?
    /// Why Continue is disabled, shown as its tooltip; nil when there's nothing to explain.
    var continueBlockedReason: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(title)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if let continueLabel {
                Button(continueLabel) { onContinue?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(onContinue == nil)
                    .help(onContinue == nil ? continueBlockedReason ?? "" : "")
                    .accessibilityHint(onContinue == nil ? continueBlockedReason ?? "" : "")
            }
            Button(abortLabel, action: onAbort)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14))
    }
}

/// Says a newer release is out. Draws nothing until the checker finds one.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    /// The version whose upgrade command was just copied, to confirm the click.
    @State private var copiedVersion: String?

    var body: some View {
        if let update = checker.availableUpdate {
            let install = InstallType.current
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("GitCraft v\(update.version) is available")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button("Skip This Version") { checker.skip(update) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(copiedVersion == update.version ? "Copied" : install.updateActionTitle) {
                    install.performUpdate(to: update)
                    if install == .homebrew { copiedVersion = update.version }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(install == .homebrew ? "Run in Terminal: \(InstallType.homebrewUpgradeCommand)" : "")
                Button { checker.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                }
                .buttonStyle(.plain)
                .help("Hide until GitCraft is reopened")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("update-banner")
        }
    }
}

/// Shared row used by both `ToastView` and `ErrorBannerView`: icon, summarized message,
/// optional `Show Details…` sheet trigger, and dismiss button.
private struct ErrorSummaryRow: View {
    let message: String
    let tint: Color
    var icon = "exclamationmark.triangle.fill"
    let lineLimit: Int
    let spacerMinLength: CGFloat
    let closeStyle: HierarchicalShapeStyle
    let showDetailsTooltip: Bool
    let onDismiss: () -> Void
    @State private var showingDetails = false

    private var parts: ErrorSummary { ErrorSummary(message) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(parts.summary)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: lineLimit > 1)
                .help(showDetailsTooltip && parts.hasDetails ? "Click Show Details for the full output" : "")
            Spacer(minLength: spacerMinLength)
            if parts.hasDetails {
                Button("Show Details…") { showingDetails = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(closeStyle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .sheet(isPresented: $showingDetails) {
            ErrorDetailsSheet(text: parts.full)
        }
    }
}

/// A brief note shown over the commit graph for a finished action, a no-op result or an error. It clears itself
/// after `autoDismissAfter` seconds when set, or stays until closed.
struct ToastView: View {
    let message: String
    var tint: Color = .yellow
    var icon = "exclamationmark.triangle.fill"
    /// Clears the toast by itself after this many seconds; nil keeps it until closed.
    var autoDismissAfter: Double?
    let onDismiss: () -> Void

    var body: some View {
        ErrorSummaryRow(
            message: message,
            tint: tint,
            icon: icon,
            lineLimit: 2,
            spacerMinLength: 4,
            closeStyle: .secondary,
            showDetailsTooltip: false,
            onDismiss: onDismiss
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 560)
        // Solid window colour with a light tint, so the toast reads as part of the window.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.14)))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .task(id: autoDismissAfter) {
            guard let autoDismissAfter else { return }
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            onDismiss()
        }
    }
}

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ErrorSummaryRow(
            message: message,
            tint: .red,
            lineLimit: 1,
            spacerMinLength: 8,
            closeStyle: .primary,
            showDetailsTooltip: true,
            onDismiss: onDismiss
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
    }
}

/// The full text of an error (for example a failing hook's output): scrollable,
/// selectable, and copyable.
private struct ErrorDetailsSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )

            HStack {
                Spacer()
                Button("Copy") {
                    Clipboard.copy(text)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 320, idealHeight: 420)
    }
}

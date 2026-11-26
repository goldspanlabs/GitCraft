import SwiftUI

struct WelcomeView: View {
    @ObservedObject var workspace: WorkspaceState
    /// Called after a repository was opened from this screen (the welcome window closes itself).
    var onOpened: () -> Void = {}

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(18)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 6) {
                Text("Welcome to GitCraft")
                    .font(.title2.weight(.semibold))
                Text("Fast, native Git client powered by Rust & AppKit")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if workspace.gitAvailability != .available {
                GitMissingCard(
                    availability: workspace.gitAvailability,
                    onInstallCLT: { workspace.installCommandLineTools() },
                    onDownloadGit: { workspace.openGitDownloadPage() },
                    onCheckAgain: {
                        if workspace.refreshGitAvailability() == .available,
                           workspace.restoreTabs()
                        {
                            onOpened()
                        }
                    }
                )
            } else {
                Button {
                    if workspace.chooseRepository() { onOpened() }
                } label: {
                    Label("Open Repository…", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if !workspace.recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT REPOSITORIES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 2) {
                        ForEach(workspace.recentPaths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            Button {
                                if workspace.openRepository(at: url) { onOpened() }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
                                        Text(path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(workspace.gitAvailability != .available)
                        }
                    }
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(width: 420)
                .opacity(workspace.gitAvailability == .available ? 1 : 0.5)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GitMissingCard: View {
    let availability: GitAvailability
    let onInstallCLT: () -> Void
    let onDownloadGit: () -> Void
    let onCheckAgain: () -> Void

    private var title: String {
        switch availability {
        case .needsCommandLineTools:
            return "Xcode Command Line Tools Required"
        case .missing, .available:
            return "Git Is Required to Use GitCraft"
        }
    }

    private var subtitle: String {
        switch availability {
        case .needsCommandLineTools:
            return "macOS has the git shim installed, but Xcode Command Line Tools are not set up yet."
        case .missing, .available:
            return "GitCraft couldn’t find git in PATH, Homebrew (/opt/homebrew/bin), or /usr/local/bin."
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Install Command Line Tools…", action: onInstallCLT)
                    .buttonStyle(.borderedProminent)
                if availability == .missing {
                    Button("Download Git…", action: onDownloadGit)
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.25))
        )
    }
}

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

            Button {
                if workspace.chooseRepository() { onOpened() }
            } label: {
                Label("Open Repository…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

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
                        }
                    }
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(width: 420)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

import SwiftUI

struct TabBarView: View {
    @ObservedObject var workspace: WorkspaceState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        RepoTabItem(
                            tab: tab,
                            isSelected: workspace.selectedTabID == tab.id,
                            onSelect: { workspace.selectedTabID = tab.id },
                            onClose: { workspace.closeTab(tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider()
                .frame(height: 18)

            Button {
                workspace.chooseRepository()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("Open Repository in New Tab (Cmd+T)")
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct RepoTabItem: View {
    @ObservedObject var tab: RepoTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tab.totalChangesCount > 0 ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
                .help(tab.totalChangesCount > 0 ? "\(tab.totalChangesCount) uncommitted changes" : "Clean")

            Text(tab.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            if !tab.currentBranch.isEmpty {
                Text(tab.currentBranch)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovering ? 1 : 0)
            .help("Close Tab (Cmd+W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color(nsColor: .controlBackgroundColor)
                        : (isHovering ? Color.secondary.opacity(0.10) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.secondary.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(perform: onSelect)
    }
}

struct WelcomeView: View {
    @ObservedObject var workspace: WorkspaceState

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
                Text("Welcome to MiniGit")
                    .font(.title2.weight(.semibold))
                Text("Fast, native Git client powered by Rust & AppKit")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                workspace.chooseRepository()
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
                                workspace.openRepository(at: url)
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

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    private var localBranches: [BranchInfo] {
        state.branches.filter { !$0.isRemote }
    }

    private var remoteBranches: [BranchInfo] {
        state.branches.filter { $0.isRemote }
    }

    var body: some View {
        List {
            Section("WORKING TREE") {
                Button {
                    state.scrollToWorkingChanges()
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.secondary)
                        Text("Working Changes")
                        Spacer()
                        if !state.changes.isEmpty {
                            Text("\(state.changes.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section("LOCAL BRANCHES") {
                ForEach(localBranches, id: \.fullRef) { branch in
                    HStack(spacing: 6) {
                        Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                            .foregroundStyle(branch.isHead ? Color.accentColor : Color.secondary)
                            .font(.caption)

                        Text(branch.name)
                            .fontWeight(branch.isHead ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if branch.ahead > 0 || branch.behind > 0 {
                            HStack(spacing: 4) {
                                if branch.ahead > 0 {
                                    Text("↑\(branch.ahead)")
                                }
                                if branch.behind > 0 {
                                    Text("↓\(branch.behind)")
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        state.checkoutBranch(branch.name)
                    }
                    .onTapGesture(count: 1) {
                        state.scrollToCommit(oidHex: branch.targetOidHex)
                    }
                }
            }

            if !remoteBranches.isEmpty {
                Section("REMOTES") {
                    ForEach(remoteBranches, id: \.fullRef) { branch in
                        HStack(spacing: 6) {
                            Image(systemName: "icloud")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(branch.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.scrollToCommit(oidHex: branch.targetOidHex)
                        }
                    }
                }
            }

            if !state.tags.isEmpty {
                Section("TAGS") {
                    ForEach(state.tags, id: \.fullRef) { tag in
                        HStack(spacing: 6) {
                            Image(systemName: "tag")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(tag.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.scrollToCommit(oidHex: tag.targetOidHex)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MiniGit")
    }
}

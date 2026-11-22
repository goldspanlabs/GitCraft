import SwiftUI

struct SidebarView: View {
    @ObservedObject var tab: RepoTab

    private var localBranches: [BranchInfo] {
        tab.branches.filter { !$0.isRemote }
    }

    private var remoteBranches: [BranchInfo] {
        tab.branches.filter { $0.isRemote }
    }

    var body: some View {
        List {
            Section("WORKING TREE") {
                Button {
                    tab.scrollToWorkingChanges()
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.secondary)
                        Text("Working Changes")
                        Spacer()
                        if tab.totalChangesCount > 0 {
                            Text("\(tab.totalChangesCount)")
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

            Section {
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
                        tab.checkoutBranch(branch.name)
                    }
                    .onTapGesture(count: 1) {
                        tab.scrollToCommit(oidHex: branch.targetOidHex)
                    }
                    .contextMenu {
                        if !branch.isHead {
                            Button("Checkout \(branch.name)") {
                                tab.checkoutBranch(branch.name)
                            }
                            Button("Merge \(branch.name) into Current") {
                                tab.mergeBranch(branch.name)
                            }
                        }
                        Button("New Branch from \(branch.name)…") {
                            tab.newBranchStartPoint = branch.name
                            tab.isShowingNewBranchSheet = true
                        }
                        if !branch.isHead {
                            Divider()
                            Button("Delete \(branch.name)", role: .destructive) {
                                tab.deleteBranch(branch.name, force: false)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("LOCAL BRANCHES")
                    Spacer()
                    Button {
                        tab.newBranchStartPoint = nil
                        tab.isShowingNewBranchSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Create new branch")
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
                            tab.scrollToCommit(oidHex: branch.targetOidHex)
                        }
                    }
                }
            }

            if !tab.tags.isEmpty {
                Section("TAGS") {
                    ForEach(tab.tags, id: \.fullRef) { tag in
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
                            tab.scrollToCommit(oidHex: tag.targetOidHex)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct NewBranchSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var checkout = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Branch")
                .font(.headline)

            if let start = tab.newBranchStartPoint {
                Text("Starting at \(start)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Branch name (e.g. feature/my-change)", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Toggle("Checkout after creating", isOn: $checkout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    tab.createBranch(
                        name: branchName,
                        startPoint: tab.newBranchStartPoint,
                        checkout: checkout
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

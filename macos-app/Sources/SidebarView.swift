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
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(width: 16, alignment: .center)
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
                            .frame(width: 16, alignment: .center)

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
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    // Single tap must fire immediately; a count:1 gesture declared next to a
                    // count:2 one makes SwiftUI wait out the double-click interval first.
                    .onTapGesture {
                        tab.scrollToCommit(oidHex: branch.targetOidHex)
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            tab.checkoutBranch(branch.name)
                        }
                    )
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
                            Button("Delete \(branch.name)…", role: .destructive) {
                                tab.pendingConfirmation = .deleteBranch(name: branch.name, force: false)
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
                                .frame(width: 16, alignment: .center)
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

            Section {
                if tab.tags.isEmpty {
                    Text("No tags")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(tab.tags, id: \.fullRef) { tag in
                        HStack(spacing: 6) {
                            Image(systemName: "tag")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .frame(width: 16, alignment: .center)
                            Text(tag.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tab.scrollToCommit(oidHex: tag.targetOidHex)
                        }
                        .contextMenu {
                            Button("Push \(tag.name) to origin") {
                                tab.pushTag(tag.name)
                            }
                            Divider()
                            Button("Delete \(tag.name) (Local)…", role: .destructive) {
                                tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: false)
                            }
                            Button("Delete \(tag.name) (Local & Remote)…", role: .destructive) {
                                tab.pendingConfirmation = .deleteTag(name: tag.name, deleteRemote: true)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("TAGS")
                    Spacer()
                    Button {
                        tab.newTagTarget = nil
                        tab.isShowingNewTagSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Create new tag")
                }
            }

            Section {
                if tab.stashes.isEmpty {
                    Text("No stashes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(tab.stashes, id: \.index) { stash in
                        HStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down")
                                .foregroundStyle(.purple)
                                .font(.caption)
                                .frame(width: 16, alignment: .center)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stash.message)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(stash.name)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Pop \(stash.name)") {
                                tab.stashPop(stash.index)
                            }
                            Button("Apply \(stash.name)") {
                                tab.stashApply(stash.index)
                            }
                            Divider()
                            Button("Drop \(stash.name)", role: .destructive) {
                                tab.stashDrop(stash.index)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("STASHES")
                    Spacer()
                    Button {
                        tab.isShowingStashSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.totalChangesCount == 0 || tab.isBusy)
                    .help("Stash working changes")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct NewStashSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stash Changes")
                .font(.headline)

            TextField("Optional stash message…", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Toggle("Include untracked files", isOn: $includeUntracked)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stash") {
                    tab.stashPush(message: message, includeUntracked: includeUntracked)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
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

struct NewTagSheet: View {
    @ObservedObject var tab: RepoTab
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var message = ""
    @State private var pushToRemote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Tag")
                .font(.headline)

            if let target = tab.newTagTarget {
                Text("Target commit: \(String(target.prefix(7)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Target: HEAD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Tag name (e.g. v1.0.0)", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            TextField("Optional annotation message…", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Toggle("Push tag to origin", isOn: $pushToRemote)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Tag") {
                    tab.createTag(
                        name: tagName,
                        target: tab.newTagTarget,
                        message: message,
                        pushToRemote: pushToRemote
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

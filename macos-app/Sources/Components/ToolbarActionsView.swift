import AppKit
import SwiftUI

/// The toolbar's centre cluster (Fetch/Pull/Push, Stash, branch filter).
/// Hosted in an `NSToolbarItem` by `RepoWindowController`.
struct RepoToolbarActionsView: View {
    let workspace: WorkspaceState
    @ObservedObject var tab: RepoTab

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button {
                    tab.runRemote(.fetch)
                } label: {
                    TopBarIconLabel(title: "Fetch") {
                        ToolbarIconView(icon: .fetch)
                    }
                }
                .buttonStyle(.plain)
                .disabled(tab.isBusy)
                .help("Fetch from remote")

                TopBarSeparator()

                Button {
                    tab.runRemote(.pull)
                } label: {
                    TopBarIconLabel(title: "Pull", badgeCount: tab.currentBranchBehindCount) {
                        ToolbarIconView(icon: .pull)
                    }
                }
                .buttonStyle(.plain)
                .disabled(tab.isBusy)
                .help("Pull from remote")

                TopBarSeparator()

                Button {
                    tab.runRemote(.push)
                } label: {
                    TopBarIconLabel(title: "Push", badgeCount: tab.currentBranchAheadCount) {
                        ToolbarIconView(icon: .push)
                    }
                }
                .buttonStyle(.plain)
                .disabled(tab.isBusy)
                .help("Push to remote")
            }

            TopBarStashItem(tab: tab)

            Button {
                tab.toggleScopeToCurrentBranch()
            } label: {
                TopBarIconLabel(title: tab.scopeToCurrentBranch ? "Branch" : "All") {
                    ToolbarIconView(icon: tab.scopeToCurrentBranch ? .filterFilled : .filter)
                        .opacity(tab.scopeToCurrentBranch ? 1 : 0.55)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("graph-scope-toggle")
            .help(tab.scopeToCurrentBranch
                ? "Showing the current branch and its base branch — click to show all branches"
                : "Showing all branches — click to show only the current branch and its base branch")
        }
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

private struct TopBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1, height: 18)
            .padding(.bottom, 12)
    }
}

private struct TopBarIconLabel<Icon: View>: View {
    let title: String
    var badgeCount: Int = 0
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                icon()
                    .frame(height: 20)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .secondaryLabelColor))
                        )
                        .offset(x: 18, y: -4)
                }
            }
            .frame(minWidth: 40, minHeight: 20)

            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct TopBarStashItem: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    tab.presentNewStash()
                } label: {
                    ToolbarIconView(icon: .stash)
                        .frame(height: 20)
                }
                .buttonStyle(.plain)
                .disabled(tab.totalChangesCount == 0 || tab.isBusy)
                .help("Stash working changes")

                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1, height: 15)

                StashMenuTriggerButton(tab: tab)
            }
            .frame(height: 20)

            Text("Stash")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct StashMenuTriggerButton: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Button {
            showMenu()
        } label: {
            ToolbarIconView(icon: .chevronDown)
                .frame(width: 14, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showMenu() {
        var entries: [MenuEntry] = [
            .item("Save Stash…", enabled: tab.totalChangesCount > 0 && !tab.isBusy) {
                tab.presentNewStash()
            },
        ]
        if let first = tab.stashes.first {
            entries.append(.separator)
            entries.append(.item("Pop Latest Stash (\(first.name))") {
                tab.stashPop(first.index)
            })
            entries.append(.item("Apply Latest Stash (\(first.name))") {
                tab.stashApply(first.index)
            })
        }
        NSMenu.build(from: entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

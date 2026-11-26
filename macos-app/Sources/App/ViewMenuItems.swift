import SwiftUI

/// View ▸ Show Tags / Show Current Branch Only.
struct GraphFilterMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabGraphFilterItems(tab: tab)
        } else {
            Button("Show Tags") {}
                .disabled(true)
            Button("Show Current Branch Only") {}
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(true)
        }
    }
}

private struct ActiveTabGraphFilterItems: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Toggle("Show Tags", isOn: $tab.showTags)
        Toggle("Show Current Branch Only", isOn: Binding(
            get: { tab.scopeToCurrentBranch },
            set: { _ in tab.toggleScopeToCurrentBranch() }
        ))
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

/// View ▸ Go to HEAD / Go to Working Changes.
struct NavigationMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabNavigationItems(tab: tab)
        } else {
            Button("Go to HEAD") {}
                .keyboardShortcut("0", modifiers: .command)
                .disabled(true)
            Button("Go to Working Changes") {}
                .keyboardShortcut("1", modifiers: .command)
                .disabled(true)
        }
    }
}

private struct ActiveTabNavigationItems: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Button("Go to HEAD") { tab.goToHead() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(tab.headCommitOid == nil)
        Button("Go to Working Changes") { tab.scrollToWorkingChanges() }
            .keyboardShortcut("1", modifiers: .command)
    }
}

/// View ▸ Maximize / Hide Bottom Panel: keyboard-reachable versions of the pane header's
/// maximize button and the divider drag that collapses it.
struct BottomPanelMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabBottomPanelItems(tab: tab)
        } else {
            Button("Maximize Bottom Panel") {}
                .disabled(true)
            Button("Hide Bottom Panel") {}
                .disabled(true)
        }
    }
}

private struct ActiveTabBottomPanelItems: View {
    @ObservedObject var tab: RepoTab
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false

    var body: some View {
        // Only a selected commit's inspector can be collapsed or maximized; the working-changes
        // inspector has neither control.
        let hasCommit = tab.selectedCommit != nil

        Button(isMaximized ? "Restore Bottom Panel Size" : "Maximize Bottom Panel") {
            withAnimation(.easeInOut(duration: 0.18)) {
                // Same steps as the pane header's button: a collapsed pane reopens first.
                if isCollapsed {
                    isCollapsed = false
                } else {
                    isMaximized.toggle()
                }
            }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!hasCommit)

        Button(isCollapsed ? "Show Bottom Panel" : "Hide Bottom Panel") {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isMaximized { isMaximized = false }
                isCollapsed.toggle()
            }
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(!hasCommit)
    }
}

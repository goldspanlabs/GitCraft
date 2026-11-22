import SwiftUI

@main
struct MiniGitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("MiniGit") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 640)
                .task { await state.openRecent() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository…", action: state.chooseRepository)
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            ChangesSidebar()
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(state.repositoryName).font(.headline)
                    Spacer()
                    Button("Fetch") { state.run(.fetch) }
                    Button("Pull") { state.run(.pull) }
                    Button("Push") { state.run(.push) }
                }.padding(10)
                Divider()
                CommitTableView(rows: state.commits)
            }
        }
        .toolbar { ToolbarItem { Button("Open…", action: state.chooseRepository) } }
    }
}

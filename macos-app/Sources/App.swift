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
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(state.repositoryName)
                        .font(.headline)
                    Spacer()
                    TextField("Filter commits…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: searchText) { newValue in
                            state.updateSearch(newValue)
                        }
                    Button("Fetch") { state.run(.fetch) }
                    Button("Pull") { state.run(.pull) }
                    Button("Push") { state.run(.push) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                CommitTableView(
                    rows: state.commits,
                    workingChangesCount: state.changes.count,
                    scrollRequest: state.scrollRequest,
                    onLoadMore: { state.loadMoreCommits() },
                    onSelectCommit: { state.selectCommit($0) }
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Open…", action: state.chooseRepository)
            }
        }
    }
}

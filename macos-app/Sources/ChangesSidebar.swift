import SwiftUI

struct ChangesSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section("WORKING CHANGES") {
                Label("Working Changes", systemImage: "square.and.pencil")
                ForEach(state.changes, id: \.self) { path in
                    Text(path).lineLimit(1)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MiniGit")
    }
}

import SwiftUI

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

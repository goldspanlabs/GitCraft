import SwiftUI

struct NewTagSheet: View {
    @ObservedObject var tab: RepoTab
    let target: String?
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var message = ""
    @State private var pushToRemote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Tag")
                .font(.headline)

            if let target {
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
                        target: target,
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

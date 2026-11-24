import SwiftUI

struct RemotesSheet: View {
    @ObservedObject var tab: RepoTab
    let startsAdding: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newURL = ""
    @State private var pendingRemoval: RemoteInfo?
    @FocusState private var isNewNameFocused: Bool

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !tab.isBusy
    }

    private func add() {
        guard canAdd else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        tab.addRemote(name: name, url: url) {
            newName = ""
            newURL = ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remotes")
                .font(.headline)

            if tab.remotes.isEmpty {
                Text("This repository has no remotes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(tab.remotes, id: \.name) { remote in
                        RemoteEditRow(tab: tab, remote: remote) {
                            pendingRemoval = remote
                        }
                        .id("\(remote.name)|\(remote.fetchUrl)")
                    }
                }
            }

            Divider()

            Text("Add Remote")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("Name (e.g. origin)", text: $newName)
                    .frame(width: 140)
                    .focused($isNewNameFocused)
                TextField("URL", text: $newURL)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!canAdd)
            }
            .textFieldStyle(.roundedBorder)

            if let error = tab.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Done") {
                    tab.errorMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            tab.errorMessage = nil
            if startsAdding || tab.remotes.isEmpty {
                isNewNameFocused = true
            }
        }
        .confirmationDialog(
            "Remove remote \"\(pendingRemoval?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { remote in
            Button("Remove", role: .destructive) {
                tab.removeRemote(remote.name)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This removes the remote and its remote-tracking branches from this repository. Local branches are kept. Nothing is changed on the server.")
        }
    }
}

private struct RemoteEditRow: View {
    @ObservedObject var tab: RepoTab
    let remote: RemoteInfo
    let onRemove: () -> Void
    @State private var name: String
    @State private var url: String

    init(tab: RepoTab, remote: RemoteInfo, onRemove: @escaping () -> Void) {
        self.tab = tab
        self.remote = remote
        self.onRemove = onRemove
        _name = State(initialValue: remote.name)
        _url = State(initialValue: remote.fetchUrl)
    }

    private var hasSeparatePushURL: Bool { remote.pushUrl != remote.fetchUrl }

    private var isChanged: Bool {
        name.trimmingCharacters(in: .whitespaces) != remote.name
            || url.trimmingCharacters(in: .whitespaces) != remote.fetchUrl
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .frame(width: 140)
                TextField("URL", text: $url)
                Button("Save") {
                    tab.updateRemote(remote, newName: name, newURL: url)
                }
                .disabled(!isChanged || !isValid || tab.isBusy)
                Button {
                    tab.fetchRemote(remote.name)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Fetch \(remote.name) (and prune deleted branches)")
                .disabled(tab.isBusy)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .help("Remove remote")
                .disabled(tab.isBusy)
            }
            .textFieldStyle(.roundedBorder)
            if hasSeparatePushURL {
                Text("Push URL: \(remote.pushUrl) (set separately; Save replaces both URLs)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

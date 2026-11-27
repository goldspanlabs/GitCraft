import AppKit
import SwiftUI

struct CreateRepositorySheet: View {
    @ObservedObject var workspace: WorkspaceState
    let onDismiss: () -> Void

    @State private var folderPath = ""
    @State private var initialBranch = "main"
    @State private var isCreating = false
    @State private var isDismissed = false
    @State private var errorMessage: String?

    private var trimmedPath: String {
        folderPath.trimmed
    }

    var body: some View {
        ActionSheetLayout(
            title: "Create New Local Repository",
            subtitle: "Initialize an empty Git repository in a local folder.",
            confirmLabel: isCreating ? "Creating…" : "Create",
            confirmDisabled: trimmedPath.isEmpty || isCreating,
            onCancel: {
                isDismissed = true
                onDismiss()
            },
            onConfirm: createRepository
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        TextField("/path/to/new-repo", text: $folderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCreating)
                        Button("Choose…") { chooseFolder() }
                            .disabled(isCreating)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Initial Branch")
                        .font(.system(size: 12, weight: .medium))
                    TextField("main", text: $initialBranch)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 380)
        }
    }

    private func chooseFolder() {
        guard let url = pickFolder() else { return }
        folderPath = url.path
        errorMessage = nil
    }

    private func createRepository() {
        let path = trimmedPath
        let branch = initialBranch.trimmed
        guard !path.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        Task {
            let outcome = await workspace.makeAndOpenRepository(
                at: path,
                openFailure: "Repository created, but failed to open.",
                isCancelled: { isDismissed }
            ) {
                try initRepository(path: path, initialBranch: branch.isEmpty ? nil : branch)
            }
            isCreating = false
            switch outcome {
            case .opened: onDismiss()
            case .cancelled: break
            case let .failed(message): errorMessage = message
            }
        }
    }
}

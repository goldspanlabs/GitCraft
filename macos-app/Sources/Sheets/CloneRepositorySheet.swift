import AppKit
import SwiftUI

struct CloneRepositorySheet: View {
    @ObservedObject var workspace: WorkspaceState
    let onDismiss: () -> Void

    @State private var urlText = ""
    @State private var parentFolderPath = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var folderName = ""
    @State private var hasEditedFolderName = false
    @State private var isCloning = false
    @State private var isDismissed = false
    @State private var errorMessage: String?

    private var trimmedURL: String {
        urlText.trimmed
    }

    private var trimmedParent: String {
        parentFolderPath.trimmed
    }

    private var trimmedFolderName: String {
        folderName.trimmed
    }

    private var destinationPath: String {
        guard !trimmedParent.isEmpty else { return "" }
        let parentURL = URL(fileURLWithPath: trimmedParent)
        return trimmedFolderName.isEmpty
            ? parentURL.path
            : parentURL.appendingPathComponent(trimmedFolderName).path
    }

    var body: some View {
        ActionSheetLayout(
            title: "Clone Repository",
            subtitle: "Clone a remote Git repository into a local folder.",
            confirmLabel: isCloning ? "Cloning…" : "Clone",
            confirmDisabled: trimmedURL.isEmpty || trimmedParent.isEmpty || trimmedFolderName.isEmpty || isCloning,
            onCancel: {
                isDismissed = true
                onDismiss()
            },
            onConfirm: cloneRepo
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository URL")
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://github.com/user/repo.git", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCloning)
                        .onChange(of: urlText) { _, newValue in
                            if !hasEditedFolderName {
                                folderName = Self.suggestedFolderName(from: newValue)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination Parent Folder")
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        TextField("/path/to/parent", text: $parentFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCloning)
                        Button("Choose…") { chooseParentFolder() }
                            .disabled(isCloning)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder Name")
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        "repo",
                        text: Binding(
                            get: { folderName },
                            set: { newValue in
                                folderName = newValue
                                hasEditedFolderName = true
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCloning)
                }

                if !destinationPath.isEmpty {
                    Text("Clone into: \(destinationPath)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isCloning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Cloning repository…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 400)
        }
    }

    static func suggestedFolderName(from urlString: String) -> String {
        let trimmed = urlString.trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        let lastSegment = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if lastSegment.hasSuffix(".git") {
            return String(lastSegment.dropLast(4))
        }
        return lastSegment
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentFolderPath = url.path
        errorMessage = nil
    }

    private func cloneRepo() {
        let url = trimmedURL
        let dest = destinationPath
        guard !url.isEmpty, !dest.isEmpty else { return }

        isCloning = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try cloneRepository(url: url, destination: dest)
                }.value
                isCloning = false
                guard !isDismissed else { return }
                if workspace.openRepository(at: URL(fileURLWithPath: dest)) {
                    onDismiss()
                } else {
                    errorMessage = workspace.openError ?? "Repository cloned, but failed to open."
                }
            } catch {
                isCloning = false
                errorMessage = error.displayMessage
            }
        }
    }
}

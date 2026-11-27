import AppKit

/// Asks for one folder in the standard open panel, starting in `directory` when given.
/// Returns nil when the person cancels.
@MainActor
func pickFolder(
    prompt: String = "Choose",
    canCreateFolders: Bool = true,
    startingIn directory: URL? = nil
) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = canCreateFolders
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    if let directory {
        panel.directoryURL = directory
    }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

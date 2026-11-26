import AppKit

/// What the update banner and the "Check for Updates…" dialog offer to do.
extension InstallType {
    static let current = detect(bundlePath: Bundle.main.bundlePath)

    var updateActionTitle: String {
        switch self {
        case .homebrew: return "Copy Upgrade Command"
        case .direct: return "Download"
        }
    }

    /// GitCraft isn't notarized, so it never replaces itself: Homebrew users get the command
    /// to run, everyone else gets the download.
    @MainActor
    func performUpdate(to update: AppUpdate) {
        switch self {
        case .homebrew: Clipboard.copy(Self.homebrewUpgradeCommand)
        case .direct: NSWorkspace.shared.open(update.downloadURL)
        }
    }
}

/// The "Check for Updates…" menu command, which always answers with a dialog.
@MainActor
enum UpdatePrompt {
    private static var isChecking = false

    static func checkNow(checker: UpdateChecker = .shared) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        switch await checker.checkManually() {
        case let .updateAvailable(update):
            offer(update, current: current, checker: checker)
        case .upToDate:
            show("You're up to date", "GitCraft v\(current) is the latest version.")
        case .unknownCurrentVersion:
            show("Can't check for updates", "This build of GitCraft has no version number to compare.")
        case let .failed(message):
            show("Couldn't check for updates", message)
        }
    }

    private static func offer(_ update: AppUpdate, current: String, checker: UpdateChecker) {
        let install = InstallType.current
        let alert = NSAlert()
        alert.messageText = "GitCraft v\(update.version) is available"
        alert.informativeText = "You have v\(current)."
        if install == .homebrew {
            alert.informativeText += " To upgrade, run this in Terminal:\n\n\(InstallType.homebrewUpgradeCommand)"
        }
        alert.addButton(withTitle: install.updateActionTitle)
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install.performUpdate(to: update)
        case .alertThirdButtonReturn: checker.skip(update)
        default: break
        }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

import Foundation

extension Error {
    /// The text to show a person for an error. Errors from the Rust core wrap git's own
    /// message in `GitCraftError.Message(msg:)`, whose default description is noisy.
    var displayMessage: String {
        if let error = self as? GitCraftError {
            switch error {
            case let .Message(msg), let .Warning(msg):
                return msg.trimmed
            case .GitNotFound:
                return "Git is not installed or could not be found. Install Git or Xcode Command Line Tools, then try again."
            }
        }
        return localizedDescription
    }

    /// True for core errors that report a no-op rather than a failure.
    var isWarning: Bool {
        if let error = self as? GitCraftError, case .Warning = error { return true }
        return false
    }

    /// True when the `git` CLI executable could not be found.
    var isGitNotFound: Bool {
        if let error = self as? GitCraftError, case .GitNotFound = error { return true }
        return false
    }
}

/// Splits an error message into a one-line summary for the banner and the full text for
/// the details sheet.
struct ErrorSummary: Equatable {
    /// Banner text: the line that reports the error, cut to a readable length.
    let summary: String
    /// The whole message, shown in the details sheet.
    let full: String
    /// True when the banner can't show everything (several lines, or a long line).
    let hasDetails: Bool

    static let maxSummaryLength = 140

    /// Lines such as "error: ..." or "fatal: ..." name the failure. Hook and step banners
    /// ("pre-push: cargo clippy") come before it, so the first line alone can mislead.
    private static func isErrorLine(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("error") || lowered.hasPrefix("fatal")
    }

    init(_ message: String) {
        let trimmed = message.trimmed
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        let first = lines.first(where: Self.isErrorLine) ?? lines.first ?? trimmed
        full = trimmed
        if first.count > Self.maxSummaryLength {
            summary = String(first.prefix(Self.maxSummaryLength)) + "…"
            hasDetails = true
        } else {
            summary = first
            hasDetails = lines.count > 1
        }
    }
}

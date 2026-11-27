import Foundation

extension String {
    /// The string without leading and trailing whitespace and newlines.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text on one line: line breaks at the ends are dropped, and each run of them in
    /// between, with the spaces around it, becomes one space. For text pasted into the commit
    /// message fields.
    var joinedOntoOneLine: String {
        trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "[ \\t]*[\\r\\n\u{2028}\u{2029}]+[ \\t]*", with: " ", options: .regularExpression)
    }

    /// The first seven characters of a commit SHA, as git abbreviates it. Matches the core's
    /// `shortOid` on commit rows.
    var shortOid: String {
        String(prefix(7))
    }

    /// The last component of this path, such as `repo` for `/Users/me/repo`. Checkouts are
    /// named by their folder.
    var folderName: String {
        URL(fileURLWithPath: self).lastPathComponent
    }
}

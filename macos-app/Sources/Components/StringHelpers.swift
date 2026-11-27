import Foundation

extension String {
    /// The string without leading and trailing whitespace and newlines.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first seven characters of a commit SHA, as git abbreviates it. Matches the core's
    /// `shortOid` on commit rows.
    var shortOid: String {
        String(prefix(7))
    }
}

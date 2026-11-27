import Foundation

/// The commit message a squash starts with, for the person to edit.
enum SquashMessage {
    private static let coAuthorPrefix = "co-authored-by:"

    /// `commits` is oldest first. The summary is the oldest commit's. The description is its
    /// body, then each later commit's summary and body, then one `Co-authored-by:` line per
    /// other author.
    static func draft(for commits: [SquashCommit]) -> (summary: String, description: String) {
        guard let oldest = commits.first else { return ("", "") }
        var paragraphs: [String] = []
        var coAuthors: [String] = []
        var credited = Set<String>()

        func credit(_ line: String, email: String) {
            if credited.insert(email.lowercased()).inserted {
                coAuthors.append(line)
            }
        }

        for (index, commit) in commits.enumerated() {
            var kept: [Substring] = []
            for line in commit.body.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line).trimmed
                if trimmed.lowercased().hasPrefix(coAuthorPrefix) {
                    credit(trimmed, email: email(in: trimmed))
                } else {
                    kept.append(line)
                }
            }
            if index > 0 { paragraphs.append(commit.summary) }
            paragraphs.append(kept.joined(separator: "\n").trimmed)
        }
        for commit in commits where commit.authorEmail.lowercased() != oldest.authorEmail.lowercased() {
            credit("Co-authored-by: \(commit.authorName) <\(commit.authorEmail)>", email: commit.authorEmail)
        }
        paragraphs.append(coAuthors.joined(separator: "\n"))

        return (oldest.summary, paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// The address between `<` and `>`, or the whole credit when there is none.
    private static func email(in line: String) -> String {
        guard let open = line.lastIndex(of: "<"), let close = line.lastIndex(of: ">"), open < close else {
            return String(line.dropFirst(coAuthorPrefix.count)).trimmed
        }
        return String(line[line.index(after: open)..<close])
    }
}

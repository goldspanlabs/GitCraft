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
            let (text, trailers) = splitTrailers(commit.body)
            var kept: [String] = []
            for line in trailers {
                if line.lowercased().hasPrefix(coAuthorPrefix) {
                    credit(line.trimmed, email: email(in: line.trimmed))
                } else {
                    kept.append(line)
                }
            }
            if index > 0 { paragraphs.append(commit.summary) }
            paragraphs.append(text)
            paragraphs.append(kept.joined(separator: "\n"))
        }
        for commit in commits where commit.authorEmail.lowercased() != oldest.authorEmail.lowercased() {
            credit("Co-authored-by: \(commit.authorName) <\(commit.authorEmail)>", email: commit.authorEmail)
        }
        paragraphs.append(coAuthors.joined(separator: "\n"))

        return (oldest.summary, paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// `body` apart from its trailer block, and that block's lines. As in git, only a last
    /// paragraph made up of `Token: value` lines (and their indented continuations) counts, so
    /// an example quoted elsewhere stays part of the text.
    private static func splitTrailers(_ body: String) -> (text: String, trailers: [String]) {
        let lines = body.trimmed.components(separatedBy: "\n")
        let start = lines.lastIndex { $0.trimmed.isEmpty }.map { $0 + 1 } ?? 0
        let block = Array(lines[start...])
        let isTrailer = { (line: String) in
            line.range(of: "^[A-Za-z0-9-]+:( |$)", options: .regularExpression) != nil
        }
        guard let first = block.first, isTrailer(first),
              block.allSatisfy({ isTrailer($0) || $0.first?.isWhitespace == true })
        else { return (body.trimmed, []) }
        return (lines[..<start].joined(separator: "\n").trimmed, block)
    }

    /// The address between `<` and `>`, or the whole credit when there is none.
    private static func email(in line: String) -> String {
        guard let open = line.lastIndex(of: "<"), let close = line.lastIndex(of: ">"), open < close else {
            return String(line.dropFirst(coAuthorPrefix.count)).trimmed
        }
        return String(line[line.index(after: open)..<close])
    }
}

import Foundation

extension RemoteOperation {
    /// What the title-bar spinner says while this operation runs.
    var busyLabel: String {
        switch self {
        case .fetch: return "Fetching…"
        case .pull: return "Pulling…"
        case .push: return "Pushing…"
        }
    }

    /// The note shown once the operation has finished, worked out from the branches before and
    /// after it. `remote` is the remote a first push publishes to.
    static func successMessage(
        for operation: RemoteOperation,
        before: [BranchInfo],
        after: [BranchInfo],
        remote: String
    ) -> String {
        let headBefore = before.first { $0.isHead && !$0.isRemote }
        let headAfter = after.first { $0.isHead && !$0.isRemote }

        switch operation {
        case .fetch:
            guard let head = headAfter else { return "Fetched." }
            if head.behind > 0 {
                return "Fetched. \"\(head.name)\" is \(commits(head.behind)) behind its upstream."
            }
            return "Fetched. \"\(head.name)\" is up to date."

        case .pull:
            guard let head = headAfter else { return "Pulled." }
            if let headBefore, headBefore.targetOidHex == head.targetOidHex {
                return "\"\(head.name)\" is already up to date."
            }
            return "Pulled into \"\(head.name)\"."

        case .push:
            guard let head = headBefore ?? headAfter else { return "Pushed." }
            // A branch with no upstream reports no ahead or behind counts. With no remote branch
            // of the same name either, this push published it (and set its upstream).
            let hasRemoteNamesake = before.contains { $0.isRemote && $0.name.hasSuffix("/\(head.name)") }
            if !hasRemoteNamesake, head.ahead == 0, head.behind == 0 {
                return "Published \"\(head.name)\" to \(remote)."
            }
            if head.ahead > 0 {
                return "Pushed \(commits(head.ahead)) from \"\(head.name)\"."
            }
            return "Nothing to push. \"\(head.name)\" is up to date."
        }
    }

    private static func commits(_ count: UInt32) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

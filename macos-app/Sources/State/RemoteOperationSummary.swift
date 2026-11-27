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

    /// The note shown once a fetch or pull has finished, worked out from the branches before
    /// and after it.
    static func successMessage(
        for operation: RemoteOperation,
        before: [BranchInfo],
        after: [BranchInfo]
    ) -> String {
        let headBefore = before.first { $0.isHead && !$0.isRemote }
        let headAfter = after.first { $0.isHead && !$0.isRemote }

        switch operation {
        case .fetch:
            guard let head = headAfter else { return "Fetched." }
            if head.behind > 0 {
                // Measured against its upstream or, with none set, the same-named branch on
                // origin, so this doesn't claim an upstream exists.
                return "Fetched. \"\(head.name)\" is \(commits(head.behind)) behind the remote."
            }
            return "Fetched. \"\(head.name)\" is up to date."

        case .pull:
            guard let head = headAfter else { return "Pulled." }
            if let headBefore, headBefore.targetOidHex == head.targetOidHex {
                return "\"\(head.name)\" is already up to date."
            }
            return "Pulled into \"\(head.name)\"."

        case .push:
            // Pushes are described from the core's `PushResult`; see `pushMessage`.
            return "Pushed."
        }
    }

    /// The note for a finished push, from what the core measured against the real destination.
    static func pushMessage(_ result: PushResult) -> String {
        if result.published {
            return "Published \"\(result.branch)\" to \(result.destination)."
        }
        if result.upToDate {
            return "Nothing to push. \(result.destination) already has \"\(result.branch)\"."
        }
        if result.forced {
            return "Force-pushed \"\(result.branch)\" to \(result.destination)."
        }
        if result.commits > 0 {
            return "Pushed \(commits(result.commits)) to \(result.destination)."
        }
        // Git didn't say, or the range couldn't be counted here; it still pushed.
        return "Pushed \"\(result.branch)\" to \(result.destination)."
    }

    private static func commits(_ count: UInt32) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

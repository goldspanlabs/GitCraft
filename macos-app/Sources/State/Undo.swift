import Foundation

/// One action that can be taken back, kept as data so the toast, the Edit menu and anything
/// added later all work from the same stack.
///
/// To make another action undoable: add a case, give `perform` a core call that refuses
/// (changing nothing) when the repository has moved on, and give `stillApplies` a cheap check
/// of the same thing. Then have the action call `RepoTab.recordUndo`.
enum UndoStep {
    /// Put HEAD back where it was before a reset, cherry-pick or revert, using `mode`.
    case moveHead(HeadMove, mode: ResetMode)

    /// Runs the undo. Throws, without changing anything, when it no longer applies.
    func perform(in session: RepoSession) throws {
        switch self {
        case let .moveHead(move, mode):
            try session.undoHeadMove(expected: move.after, target: move.before.oid, mode: mode)
        }
    }

    /// Whether undoing would still work. Runs off the main thread after each refresh.
    func stillApplies(in session: RepoSession) -> Bool {
        switch self {
        case let .moveHead(move, _):
            return session.headPosition() == move.after
        }
    }

    /// The note shown once the undo has worked.
    var doneMessage: String {
        switch self {
        case let .moveHead(move, _):
            let branch = move.before.branch.map { "\"\($0.replacingOccurrences(of: "refs/heads/", with: ""))\"" } ?? "HEAD"
            return "\(branch) is back at \(move.before.oid.shortOid)."
        }
    }
}

extension RepoTab {
    struct UndoEntry: Identifiable {
        let id = UUID()
        /// Names the action in menus and notes, as in "Undo Cherry Pick".
        let actionName: String
        let step: UndoStep
    }

    /// The most steps kept; recording past this forgets the oldest.
    static let maxUndoSteps = 20

    /// The step Undo would take back now.
    var latestUndo: UndoEntry? { undoStack.last }

    /// The Edit menu's title when there is nothing to name.
    static let genericUndoTitle = "Undo Repository Action"

    /// The Edit menu item's title, naming the step it would take back.
    var undoMenuTitle: String {
        latestUndo.map { "Undo \($0.actionName)" } ?? Self.genericUndoTitle
    }

    /// Whether Undo can run now.
    var canUndo: Bool { latestUndo != nil && !isBusy }

    /// Adds a step to the stack and shows `message` with an Undo button for it.
    func recordUndo(actionName: String, step: UndoStep, message: String) {
        let entry = UndoEntry(actionName: actionName, step: step)
        undoStack.append(entry)
        if undoStack.count > Self.maxUndoSteps {
            let dropped = undoStack.prefix(undoStack.count - Self.maxUndoSteps).map(\.id)
            undoStack.removeFirst(dropped.count)
            dropped.forEach(dismissToasts(forUndo:))
        }
        showToast(message, isSuccess: true, action: ToastAction(title: "Undo", undoEntryID: entry.id) { [weak self] in
            self?.undo(entry.id)
        })
    }

    /// Runs `work`, which reports how it moved HEAD, then records that move as undoable with
    /// `undoMode`. When HEAD didn't move, the note shows without an Undo button.
    func performUndoableHeadMove(
        actionName: String,
        message: String,
        undoMode: ResetMode,
        _ work: @escaping @Sendable (RepoSession) throws -> HeadMove?
    ) {
        let moved = SendableBox<HeadMove?>(nil)
        performMutation({ session in
            moved.value = try work(session)
        }, onSuccess: { [weak self] in
            guard let self else { return }
            if let move = moved.value {
                self.recordUndo(actionName: actionName, step: .moveHead(move, mode: undoMode), message: message)
            } else {
                self.showToast(message, isSuccess: true)
            }
        })
    }

    /// Undoes the latest step. Steps are undone newest first, so an `id` that isn't the
    /// latest does nothing.
    func undo(_ id: UUID? = nil) {
        guard canUndo, let entry = latestUndo, id == nil || id == entry.id else { return }
        let step = SendableBox(entry.step)
        performMutation(busyLabel: "Undoing \(entry.actionName)…", { session in
            try step.value.perform(in: session)
        }, onSuccess: { [weak self] in
            guard let self else { return }
            self.forgetUndo(entry.id)
            self.showToast("Undid \(entry.actionName). \(entry.step.doneMessage)", isSuccess: true)
        }, onFailure: { [weak self] _ in
            // It was refused because the repository moved on, or it failed: either way it
            // can't be undone now. The error still shows.
            self?.forgetUndo(entry.id)
            return false
        })
    }

    /// Clears the stack once the latest step no longer applies: something that can't be
    /// undone happened since (a commit, a checkout, a change made outside the app), and the
    /// older steps sit behind it. Called after each refresh.
    func pruneUndoStack() {
        guard let latest = latestUndo else { return }
        let step = SendableBox(latest.step)
        loadInBackground({ session in
            step.value.stillApplies(in: session)
        }, apply: { [weak self] applies in
            guard let self, !applies, self.latestUndo?.id == latest.id else { return }
            self.undoStack.map(\.id).forEach(self.dismissToasts(forUndo:))
            self.undoStack.removeAll()
        })
    }

    private func forgetUndo(_ id: UUID) {
        undoStack.removeAll { $0.id == id }
        dismissToasts(forUndo: id)
    }
}

/// Carries a value between a mutation's background work and the main actor. Each box is
/// written on one side and read on the other only after the work has been awaited, so the
/// unchecked `Sendable` is safe.
final class SendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

import AppKit

/// One action that can be taken back (or, once undone, done again), kept as data so the
/// toast, the Edit menu and anything added later all work from the same stacks.
///
/// To make another action undoable: add a case, give `perform` a core call that refuses
/// (changing nothing) when the repository has moved on, give `stillApplies` a cheap check of
/// the same thing, and give `inverse` the step that puts it back. Then have the action call
/// `RepoTab.recordUndo`.
enum UndoStep {
    /// Move HEAD from `move.after` back to `move.before`, using `mode`. Undoes a reset,
    /// cherry-pick or revert; its inverse redoes one.
    case moveHead(HeadMove, mode: ResetMode)

    /// Runs the step. Throws, without changing anything, when it no longer applies.
    func perform(in session: RepoSession) throws {
        switch self {
        case let .moveHead(move, mode):
            try session.undoHeadMove(expected: move.after, target: move.before.oid, mode: mode)
        }
    }

    /// Whether the step would still work. Runs off the main thread after each refresh.
    func stillApplies(in session: RepoSession) -> Bool {
        switch self {
        case let .moveHead(move, _):
            return session.headPosition() == move.after
        }
    }

    /// The step that takes this one back: what Redo runs after an undo, and Undo after a redo.
    var inverse: UndoStep {
        switch self {
        case let .moveHead(move, mode):
            // The same mode in the other direction: a soft reset is redone softly, and a
            // cherry-pick or revert is redone with keep, so local edits stay either way.
            return .moveHead(HeadMove(before: move.after, after: move.before), mode: mode)
        }
    }

    /// Where the step leaves things, for the note once it has run.
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

    /// The most steps kept on each stack; recording past this forgets the oldest.
    static let maxUndoSteps = 20

    /// The step Undo would take back now.
    var latestUndo: UndoEntry? { undoStack.last }

    /// The step Redo would do again now.
    var latestRedo: UndoEntry? { redoStack.last }

    /// The Edit menu's titles when there is no repository step to name.
    static let genericUndoTitle = "Undo"
    static let genericRedoTitle = "Redo"

    /// The Edit menu's Undo title. While a text field has focus, ⌘Z edits text, so the
    /// repository step isn't named.
    var undoMenuTitle: String {
        guard !isEditingText, let entry = latestUndo else { return Self.genericUndoTitle }
        return "Undo \(entry.actionName)"
    }

    var redoMenuTitle: String {
        guard !isEditingText, let entry = latestRedo else { return Self.genericRedoTitle }
        return "Redo \(entry.actionName)"
    }

    var canUndo: Bool { latestUndo != nil && !isBusy }
    var canRedo: Bool { latestRedo != nil && !isBusy }

    /// Records a new action as undoable and shows `message` with an Undo button for it. A new
    /// action means there's nothing left to redo.
    func recordUndo(actionName: String, step: UndoStep, message: String) {
        redoStack.removeAll()
        pushUndo(UndoEntry(actionName: actionName, step: step), message: message)
    }

    /// Runs `work`, which reports how it moved HEAD, then records that move as undoable with
    /// `undoMode`. When HEAD didn't move, the note shows without an Undo button.
    func performUndoableHeadMove(
        actionName: String,
        message: String,
        undoMode: ResetMode,
        _ work: @escaping @Sendable (RepoSession) throws -> HeadMove?
    ) {
        // One history change at a time: a second one finishing first would clear `isBusy`
        // under the first and let pruning drop the step it is about to record.
        guard !isBusy else { return }
        let moved = SendableBox<HeadMove?>(nil)
        performMutation({ session in
            moved.value = try work(session)
        }, onSuccess: { [weak self] in
            guard let self else { return }
            if let move = moved.value {
                self.recordUndo(actionName: actionName, step: .moveHead(move, mode: undoMode), message: message)
            } else {
                // HEAD stayed put, but a reset still changed the index or files, so what was
                // undone before can't be redone on top of it.
                self.redoStack.removeAll()
                self.showToast(message, isSuccess: true)
            }
        })
    }

    /// Undoes the latest step. Steps are undone newest first, so an `id` that isn't the
    /// latest does nothing.
    func undo(_ id: UUID? = nil) {
        guard canUndo, let entry = latestUndo, id == nil || id == entry.id else { return }
        run(entry, verb: "Undoing", onDone: { [weak self] in
            guard let self else { return }
            self.undoStack.removeAll { $0.id == entry.id }
            self.dismissToasts(forUndo: entry.id)
            self.pushRedo(UndoEntry(actionName: entry.actionName, step: entry.step.inverse))
            self.showToast("Undid \(entry.actionName). \(entry.step.doneMessage)", isSuccess: true)
        }, onRefused: { [weak self] in
            // `reset --keep` refuses over a local edit without moving HEAD; that step works
            // again once the edit is stashed, so only a step that no longer applies goes.
            self?.dropIfStale(entry) { [weak self] in self?.forgetUndo(entry.id) }
        })
    }

    /// Does the latest undone step again. Its note offers Undo once more.
    func redo() {
        guard canRedo, let entry = latestRedo else { return }
        run(entry, verb: "Redoing", onDone: { [weak self] in
            guard let self else { return }
            self.redoStack.removeAll { $0.id == entry.id }
            self.pushUndo(
                UndoEntry(actionName: entry.actionName, step: entry.step.inverse),
                message: "Redid \(entry.actionName). \(entry.step.doneMessage)"
            )
        }, onRefused: { [weak self] in
            self?.dropIfStale(entry) { [weak self] in self?.redoStack.removeAll { $0.id == entry.id } }
        })
    }

    /// Clears a stack once its latest step no longer applies: something that can't be undone
    /// happened since (a commit, a checkout, a change made outside the app), and the older
    /// steps sit behind it. Called after each refresh.
    ///
    /// Skipped while an action runs: it may have moved HEAD without having recorded its step
    /// yet, which would make the previous step look stale. Its own refresh checks afterwards.
    func pruneUndoStack() {
        guard !isBusy else { return }
        prune(latestUndo) { [weak self] in
            guard let self else { return }
            self.undoStack.map(\.id).forEach(self.dismissToasts(forUndo:))
            self.undoStack.removeAll()
        }
        prune(latestRedo) { [weak self] in self?.redoStack.removeAll() }
    }

    /// Forgets every step and its notes, for example when the tab switches checkout.
    func clearUndoHistory() {
        undoStack.map(\.id).forEach(dismissToasts(forUndo:))
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: Private

    private func pushUndo(_ entry: UndoEntry, message: String) {
        undoStack.append(entry)
        if undoStack.count > Self.maxUndoSteps {
            let dropped = undoStack.prefix(undoStack.count - Self.maxUndoSteps).map(\.id)
            undoStack.removeFirst(dropped.count)
            dropped.forEach(dismissToasts(forUndo:))
        }
        let action = ToastAction(title: "Undo", undoEntryID: entry.id, help: "Undo \(entry.actionName) (⌘Z)") { [weak self] in
            self?.undo(entry.id)
        }
        showToast(message, isSuccess: true, action: action)
    }

    private func pushRedo(_ entry: UndoEntry) {
        redoStack.append(entry)
        if redoStack.count > Self.maxUndoSteps {
            redoStack.removeFirst(redoStack.count - Self.maxUndoSteps)
        }
    }

    /// Runs `entry`'s step. A refusal (the repository moved on) or failure means it can't be
    /// run now, so `onRefused` drops it; the error still shows.
    private func run(
        _ entry: UndoEntry,
        verb: String,
        onDone: @escaping @MainActor () -> Void,
        onRefused: @escaping @MainActor () -> Void
    ) {
        let step = SendableBox(entry.step)
        performMutation(busyLabel: "\(verb) \(entry.actionName)…", { session in
            try step.value.perform(in: session)
        }, onSuccess: onDone, onFailure: { _ in
            onRefused()
            return false
        })
    }

    /// Checks `latest` off the main thread and calls `clear` if it no longer applies and is
    /// still the latest by then.
    private func prune(_ latest: UndoEntry?, clear: @escaping @MainActor () -> Void) {
        guard let latest else { return }
        dropIfStale(latest, requireLatest: true, drop: clear)
    }

    /// Checks `entry` off the main thread and calls `drop` if it no longer applies. With
    /// `requireLatest`, only while it is still the latest step by then. Never while an action
    /// runs (see `pruneUndoStack`).
    private func dropIfStale(
        _ entry: UndoEntry,
        requireLatest: Bool = false,
        drop: @escaping @MainActor () -> Void
    ) {
        let step = SendableBox(entry.step)
        loadInBackground({ session in
            step.value.stillApplies(in: session)
        }, apply: { [weak self] applies in
            guard let self, !applies, !self.isBusy else { return }
            if requireLatest, self.latestUndo?.id != entry.id, self.latestRedo?.id != entry.id { return }
            drop()
        })
    }

    private func forgetUndo(_ id: UUID) {
        undoStack.removeAll { $0.id == id }
        dismissToasts(forUndo: id)
    }
}

/// Where ⌘Z and ⇧⌘Z go. Text editing keeps the keys whenever a text field or text view has
/// focus, in a repository window or in a sheet, so typing is never confused with a repository
/// action.
enum UndoKeyRouting: Equatable {
    /// Hand the key to the responder chain: the focused text's own undo, or nothing.
    case text
    case repository

    static func route(firstResponderIsText: Bool, keyWindowIsRepository: Bool, hasRepositoryStep: Bool) -> Self {
        if firstResponderIsText || !keyWindowIsRepository || !hasRepositoryStep {
            return .text
        }
        return .repository
    }

    /// Decides for the window that has the keyboard right now.
    @MainActor
    static func current(hasRepositoryStep: Bool) -> Self {
        let window = NSApp.keyWindow
        return route(
            firstResponderIsText: window?.firstResponder is NSText,
            keyWindowIsRepository: window?.windowController is RepoWindowController,
            hasRepositoryStep: hasRepositoryStep
        )
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

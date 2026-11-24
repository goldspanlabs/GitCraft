import AppKit
import SwiftUI

/// User-selectable appearance for the whole app. Persisted in `UserDefaults`
/// under `storageKey` so `@AppStorage` views and the Settings window stay in sync.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Consumed by SwiftUI content (`preferredColorScheme`). `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Consumed by AppKit-backed views (`NSTableView` cells, layer colors, etc.).
    /// `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ preference: AppearancePreference) {
        NSApp.appearance = preference.nsAppearance
    }
}

/// How "Pull" reconciles diverged branches. Persisted under `storageKey`.
enum PullStrategyPreference: String, CaseIterable, Identifiable {
    case gitConfig
    case merge
    case rebase
    case fastForwardOnly

    static let storageKey = "pullStrategy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gitConfig: return "Git config"
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .fastForwardOnly: return "Fast-forward only"
        }
    }

    var detail: String {
        switch self {
        case .gitConfig:
            return "Follows pull.rebase / pull.ff in your git config, and merges if neither is set."
        case .merge: return "Creates a merge commit when your branch and the remote have diverged."
        case .rebase: return "Replays your local commits on top of the remote branch, keeping history linear."
        case .fastForwardOnly: return "Never creates a merge or rewrites commits; fails if the branches have diverged."
        }
    }

    var core: PullStrategy {
        switch self {
        case .gitConfig: return .gitConfig
        case .merge: return .merge
        case .rebase: return .rebase
        case .fastForwardOnly: return .fastForwardOnly
        }
    }

    static var current: PullStrategyPreference {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .gitConfig
    }
}

/// How often GitCraft fetches in the background. Stored as minutes (0 = never).
enum AutoFetchInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30

    static let storageKey = "autoFetchMinutes"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Never"
        case .fiveMinutes: return "Every 5 minutes"
        case .tenMinutes: return "Every 10 minutes"
        case .thirtyMinutes: return "Every 30 minutes"
        }
    }

    static var currentMinutes: Int {
        UserDefaults.standard.integer(forKey: storageKey)
    }
}

/// Git behaviour toggles shared by every repository window.
enum GitPreferences {
    static let fetchIncludeTagsKey = "fetchIncludeTags"
    static let pushOnCommitKey = "pushOnCommit"
    static let autoStageOnCommitKey = "autoStageOnCommit"

    static var fetchIncludesTags: Bool { UserDefaults.standard.bool(forKey: fetchIncludeTagsKey) }
    static var pushOnCommit: Bool { UserDefaults.standard.bool(forKey: pushOnCommitKey) }

    /// On by default: committing stages every change first, so the summary alone is enough.
    static var autoStageOnCommit: Bool {
        UserDefaults.standard.object(forKey: autoStageOnCommitKey) as? Bool ?? true
    }

    /// The Commit button needs a summary, something to commit, and no operation in progress.
    /// With auto-staging on, unstaged changes count as something to commit.
    static func canCommit(
        summary: String,
        stagedCount: Int,
        changedCount: Int,
        autoStage: Bool,
        isBusy: Bool
    ) -> Bool {
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSomethingToCommit = stagedCount > 0 || (autoStage && changedCount > 0)
        return hasSummary && hasSomethingToCommit && !isBusy
    }
}

/// Order of the commit graph. Persisted under `storageKey`.
enum CommitSortPreference: String, CaseIterable, Identifiable {
    case date
    case topological

    static let storageKey = "commitSort"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "By date"
        case .topological: return "Topologically"
        }
    }

    var detail: String {
        switch self {
        case .date: return "Newest commits first, even when branches interleave."
        case .topological: return "Keeps each line of history together, like git log --topo-order. Slower on very large repositories."
        }
    }

    var core: CommitSort {
        switch self {
        case .date: return .byDate
        case .topological: return .topological
        }
    }

    static var current: CommitSortPreference {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .date
    }
}

/// What to type in place of a space in a branch name (git forbids spaces).
enum BranchSpaceReplacement: String, CaseIterable, Identifiable {
    case dash
    case underscore
    case keep

    static let storageKey = "branchSpaceReplacement"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dash: return "- (dash)"
        case .underscore: return "_ (underscore)"
        case .keep: return "Keep spaces"
        }
    }

    var replacement: String? {
        switch self {
        case .dash: return "-"
        case .underscore: return "_"
        case .keep: return nil
        }
    }

    static var current: BranchSpaceReplacement {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .dash
    }
}

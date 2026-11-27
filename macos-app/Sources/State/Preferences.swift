import AppKit
import SwiftUI

/// String-backed preference enum stored in `UserDefaults`.
protocol UserDefaultsEnum: RawRepresentable, CaseIterable, Identifiable where RawValue == String {
    static var storageKey: String { get }
    static var defaultValue: Self { get }
}

extension UserDefaultsEnum {
    var id: String { rawValue }

    static var current: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

/// UserDefaults key for the "show avatars" preference (Settings ▸ Commits).
let showAvatarsStorageKey = "showAvatars"

/// Author avatars are fetched from Gravatar and GitHub, so they are off until the person turns
/// them on in Settings. While off, no avatar is drawn.
enum AvatarPreference {
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showAvatarsStorageKey) as? Bool ?? false
    }
}

/// Persistence keys and collapsed dimensions for the bottom inspector split panel.
enum BottomPanelDefaults {
    static let storageKey = "bottomPanelHeight"
    /// Whether the bottom panel is collapsed to just its tab strip.
    static let collapsedKey = "bottomPanelCollapsed"
    /// Whether the bottom panel is maximized to fill the whole split, hiding the graph.
    static let maximizedKey = "bottomPanelMaximized"
    /// Height of the tab strip (30pt) plus its divider: what stays visible when collapsed.
    static let collapsedHeight: CGFloat = 31
    /// How far past the minimum height the divider must be dragged down before the panel collapses.
    static let collapseDragThreshold: CGFloat = 60
    /// How far up from the collapsed strip the divider must be dragged before the panel reopens.
    static let expandDragThreshold: CGFloat = 40
}

/// User-selectable appearance for the whole app. Persisted in `UserDefaults`
/// under `storageKey` so `@AppStorage` views and the Settings window stay in sync.
enum AppearancePreference: String, UserDefaultsEnum {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"
    static let defaultValue: AppearancePreference = .system

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Matches the appearance set in System Settings."
        case .light: return "Always uses the light appearance."
        case .dark: return "Always uses the dark appearance."
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
enum PullStrategyPreference: String, UserDefaultsEnum {
    case gitConfig
    case merge
    case rebase
    case fastForwardOnly

    static let storageKey = "pullStrategy"
    static let defaultValue: PullStrategyPreference = .gitConfig

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
    static let autoStageOnCommitKey = "autoStageOnCommit"

    static var fetchIncludesTags: Bool { UserDefaults.standard.bool(forKey: fetchIncludeTagsKey) }

    /// On by default: when nothing is staged, committing stages every change first.
    static var autoStageOnCommit: Bool {
        UserDefaults.standard.object(forKey: autoStageOnCommitKey) as? Bool ?? true
    }

    /// Stage everything before committing only when the setting is on and nothing is staged.
    /// Files staged by hand always win, so only those are committed.
    static func shouldStageAll(autoStage: Bool, stagedCount: Int) -> Bool {
        autoStage && stagedCount == 0
    }

    /// The Commit button needs a summary, something to commit, and no operation in progress.
    /// With auto-staging on, unstaged changes count as something to commit. Amending can
    /// reword HEAD without any new changes.
    static func canCommit(
        summary: String,
        stagedCount: Int,
        changedCount: Int,
        autoStage: Bool,
        isBusy: Bool,
        amend: Bool = false
    ) -> Bool {
        let hasSummary = !summary.trimmed.isEmpty
        let hasSomethingToCommit = stagedCount > 0 || (autoStage && changedCount > 0) || amend
        return hasSummary && hasSomethingToCommit && !isBusy
    }
}

/// Order of the commit graph. Persisted under `storageKey`.
enum CommitSortPreference: String, UserDefaultsEnum {
    case date
    case topological

    static let storageKey = "commitSort"
    static let defaultValue: CommitSortPreference = .date

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
}

/// What to type in place of a space in a branch name (git forbids spaces).
enum BranchSpaceReplacement: String, UserDefaultsEnum {
    case dash
    case underscore
    case keep

    static let storageKey = "branchSpaceReplacement"
    static let defaultValue: BranchSpaceReplacement = .dash

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
}

import AppKit
import SwiftUI

/// Contents of the app's Settings window (GitCraft ▸ Settings… / ⌘,).
struct SettingsView: View {
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    @AppStorage(showAvatarsStorageKey) private var showAvatars = true
    @AppStorage(AutoFetchInterval.storageKey) private var autoFetchMinutes = 0
    @AppStorage(GitPreferences.fetchIncludeTagsKey) private var fetchIncludeTags = false
    @AppStorage(GitPreferences.pushOnCommitKey) private var pushOnCommit = false
    @AppStorage(GitPreferences.autoStageOnCommitKey) private var autoStageOnCommit = true
    @AppStorage(BranchSpaceReplacement.storageKey) private var spaceReplacementRaw = BranchSpaceReplacement.dash.rawValue
    @AppStorage(CommitSortPreference.storageKey) private var commitSortRaw = CommitSortPreference.date.rawValue
    @AppStorage(PullStrategyPreference.storageKey) private var pullStrategyRaw = PullStrategyPreference.gitConfig.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { appearance },
            set: { newValue in
                appearanceRaw = newValue.rawValue
                AppearancePreference.apply(newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(appearanceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("General")
            }

            Section {
                Picker("When pulling", selection: $pullStrategyRaw) {
                    ForEach(PullStrategyPreference.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Text((PullStrategyPreference(rawValue: pullStrategyRaw) ?? .gitConfig).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Fetch remotes", selection: $autoFetchMinutes) {
                    ForEach(AutoFetchInterval.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Toggle("Always include tags when fetching", isOn: $fetchIncludeTags)
                Toggle("Push automatically after committing", isOn: $pushOnCommit)
                Toggle("Stage all changes when committing", isOn: $autoStageOnCommit)
                Text("When on and nothing is staged, Commit stages every change first. Files you stage yourself are always committed alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Space in branch names", selection: $spaceReplacementRaw) {
                    ForEach(BranchSpaceReplacement.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Git")
            }

            Section {
                Picker("Sort commits", selection: $commitSortRaw) {
                    ForEach(CommitSortPreference.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((CommitSortPreference(rawValue: commitSortRaw) ?? .date).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show author avatars", isOn: $showAvatars)
                Text("Looks up avatars on Gravatar and GitHub using a hash of the author's email address. When off, nothing is sent and initials are shown instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Commits")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var appearanceDescription: String {
        switch appearance {
        case .system: return "Matches the appearance set in System Settings."
        case .light: return "Always uses the light appearance."
        case .dark: return "Always uses the dark appearance."
        }
    }
}

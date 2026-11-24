import AppKit
import SwiftUI

/// Contents of the app's Settings window (GitCraft ▸ Settings… / ⌘,).
struct SettingsView: View {
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    @AppStorage(showAvatarsStorageKey) private var showAvatars = true

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
                Toggle("Show author avatars", isOn: $showAvatars)
                Text("Looks up avatars on Gravatar and GitHub using a hash of the author's email address. When off, nothing is sent and initials are shown instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Commits")
            }
        }
        .formStyle(.grouped)
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

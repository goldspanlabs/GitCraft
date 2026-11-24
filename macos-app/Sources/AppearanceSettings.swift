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

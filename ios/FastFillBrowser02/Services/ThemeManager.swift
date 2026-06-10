import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Hashable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Single source of truth for the active color scheme. Observes `@AppStorage`
/// so every view picks up changes instantly without explicit environment plumbing.
@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var activeTheme: AppTheme = .system

    private enum Keys {
        static let theme = "ffb_theme"
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.theme) ?? ""
        activeTheme = AppTheme(rawValue: raw) ?? .system
    }

    func setTheme(_ theme: AppTheme) {
        activeTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
        applyToWindow()
    }

    /// Force the active color scheme onto the key window. Called on launch
    /// and whenever the user changes the picker.
    func applyToWindow() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        switch activeTheme {
        case .system:
            window.overrideUserInterfaceStyle = .unspecified
        case .light:
            window.overrideUserInterfaceStyle = .light
        case .dark:
            window.overrideUserInterfaceStyle = .dark
        }
    }

    var preferredColorScheme: ColorScheme? { activeTheme.colorScheme }
}

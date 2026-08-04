import Foundation

/// Bridges the editor's theme choice to the Quick Look extension via an App Group.
///
/// Compiled into both the main app (`MDViewer`) and the Quick Look extension
/// (`MDViewerQuickLook`). The App Group only shares state when the build is signed with a real
/// identity that has a provisioning profile for `appGroupID`. The local ad-hoc build falls back to
/// a read-only entitlement for the host application's preference domain.
enum ThemeSync {
    static let applicationID = "app.mdviewer"
    static let appGroupID = "group.app.mdviewer"
    static let themeKey = "theme"

    /// Preference values: "auto" (follow system, the default), "light", or "dark".
    static let auto = "auto"
    static let light = "light"
    static let dark = "dark"
    static let order = [auto, light, dark]

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// The host application's preference domain. This is also a useful fallback for the local,
    /// ad-hoc build: its Quick Look extension has a read-only shared-preference entitlement because
    /// App Groups are unavailable without a provisioning profile.
    static var applicationDefaults: UserDefaults? {
        UserDefaults(suiteName: applicationID)
    }

    /// The stored preference, normalized to one of `order` (default "auto").
    static var preference: String {
        if Bundle.main.bundleIdentifier == applicationID {
            return normalize(UserDefaults.standard.string(forKey: themeKey)
                             ?? sharedDefaults?.string(forKey: themeKey))
        }
        return normalize(sharedDefaults?.string(forKey: themeKey)
                         ?? applicationDefaults?.string(forKey: themeKey)
                         ?? UserDefaults.standard.string(forKey: themeKey))
    }

    static func setPreference(_ value: String) {
        let normalized = normalize(value)
        // Standard defaults make the main app's choice reliable even when an unprovisioned App
        // Group suite refuses a write. The suite remains the preferred bridge for signed builds.
        UserDefaults.standard.set(normalized, forKey: themeKey)
        applicationDefaults?.set(normalized, forKey: themeKey)
        sharedDefaults?.set(normalized, forKey: themeKey)
    }

    static func normalize(_ value: String?) -> String {
        switch value {
        case light: return light
        case dark: return dark
        default: return auto
        }
    }
}

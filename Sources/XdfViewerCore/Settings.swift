import Foundation
import Combine
import SwiftUI

/// User-configurable appearance options for the XDF preview. Persisted in
/// `UserDefaults` so choices survive between preview sessions.
///
/// Local/personal-use note: a paid Apple Developer membership is required to
/// share an App Group container between the host app and the sandboxed
/// extension. To avoid that dependency we default to each process's own
/// `UserDefaults` (which still persists the extension's own choices across
/// previews). If you have a team and add an App Group entitlement, set
/// `XdfViewerSettings.appGroupSuite` to your group id and both processes will
/// share.
public enum XdfAppearanceTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// `nil` means "follow system" — pass straight through to
    /// `.preferredColorScheme`.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A small curated palette for the waveform/sparkline accent, rather than a
/// full free-for-all `ColorPicker`.
public enum XdfAccentColor: String, CaseIterable, Identifiable {
    case system, blue, teal, purple, orange, green, red

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return "System"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .purple: return "Purple"
        case .orange: return "Orange"
        case .green: return "Green"
        case .red: return "Red"
        }
    }
    public var color: Color {
        switch self {
        case .system: return Color(nsColor: .controlAccentColor)
        case .blue: return .blue
        case .teal: return .teal
        case .purple: return .purple
        case .orange: return .orange
        case .green: return .green
        case .red: return .red
        }
    }
}

/// Named `XdfViewerSettings` (not `Settings`) to avoid colliding with
/// SwiftUI's `Settings<Content>` scene type in files that import SwiftUI.
public final class XdfViewerSettings: ObservableObject {

    /// Set to your App Group id (e.g. "group.com.example.XdfViewer") if you
    /// have a paid team and want host app + extension to share settings.
    public static var appGroupSuite: String? = nil

    public static let shared = XdfViewerSettings()

    private let defaults: UserDefaults

    public init() {
        if let suite = XdfViewerSettings.appGroupSuite,
           let shared = UserDefaults(suiteName: suite) {
            defaults = shared
        } else {
            defaults = .standard
        }
        _theme = XdfAppearanceTheme(rawValue: defaults.string(forKey: K.theme) ?? "") ?? .system
        _accentColor = XdfAccentColor(rawValue: defaults.string(forKey: K.accentColor) ?? "") ?? .system
    }

    private enum K {
        static let theme = "theme"
        static let accentColor = "accentColor"
    }

    // Backing storage + published accessors that persist on write.
    private var _theme: XdfAppearanceTheme
    private var _accentColor: XdfAccentColor

    public var theme: XdfAppearanceTheme {
        get { _theme }
        set { objectWillChange.send(); _theme = newValue; defaults.set(newValue.rawValue, forKey: K.theme) }
    }
    public var accentColor: XdfAccentColor {
        get { _accentColor }
        set { objectWillChange.send(); _accentColor = newValue; defaults.set(newValue.rawValue, forKey: K.accentColor) }
    }
}

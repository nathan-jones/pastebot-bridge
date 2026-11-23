import Observation
import SwiftUI

/// One appearance (light or dark) of a theme.
struct ThemePalette {
    let background: Color
    let surface: Color
    let raisedSurface: Color
    let overlay: Color
    let text: Color
    let mutedText: Color
    let border: Color
    let input: Color
    let accent: Color
    /// List column on wide screens (nil = `background`).
    var sidebar: Color? = nil
    /// Rounded highlight behind the selected clip on wide screens (nil = `overlay`).
    var selection: Color? = nil
    var showsSeparators = true
}

struct AppTheme: Identifiable {
    let id: String
    let name: String
    /// Nil for the System theme, which keeps iOS's default colors.
    let light: ThemePalette?
    let dark: ThemePalette?

    func palette(for scheme: ColorScheme) -> ThemePalette? {
        scheme == .dark ? dark : light
    }

    static let system = AppTheme(id: "system", name: "System", light: nil, dark: nil)

    static let iris = AppTheme(
        id: "iris", name: "Iris",
        light: ThemePalette(
            background: Color(hex: 0xF8F7F9), surface: Color(hex: 0xF8F7F9), raisedSurface: Color(hex: 0xF0EFF2),
            overlay: Color(hex: 0xEBE9ED), text: Color(hex: 0x221622), mutedText: Color(hex: 0x746C75),
            border: Color(hex: 0xE0DFE2), input: Color(hex: 0xCCC5D6), accent: Color(hex: 0x9B3784),
            sidebar: Color(hex: 0xEBE8F3), selection: Color(hex: 0xD3CCE6), showsSeparators: false),
        dark: ThemePalette(
            background: Color(hex: 0x1C1928), surface: Color(hex: 0x1C1928), raisedSurface: Color(hex: 0x332D47),
            overlay: Color(hex: 0x454250), text: Color(hex: 0xFEFAFF), mutedText: Color(hex: 0x8E8A94),
            border: Color(hex: 0x2E2B39), input: Color(hex: 0x5D527B), accent: Color(hex: 0xE49DD5),
            sidebar: Color(hex: 0x27223A), selection: Color(hex: 0x3D345C), showsSeparators: false)
    )

    static let grove = AppTheme(
        id: "grove", name: "Grove",
        light: ThemePalette(
            background: Color(hex: 0xF4F7F5), surface: Color(hex: 0xF4F7F5), raisedSurface: Color(hex: 0xECEFED),
            overlay: Color(hex: 0xE7E9E8), text: Color(hex: 0x221622), mutedText: Color(hex: 0x736C73),
            border: Color(hex: 0xDCDFDE), input: Color(hex: 0xBECBC5), accent: Color(hex: 0x896625),
            sidebar: Color(hex: 0xE2ECE7), selection: Color(hex: 0xC0D5C9), showsSeparators: false),
        dark: ThemePalette(
            background: Color(hex: 0x1D2722), surface: Color(hex: 0x1D2722), raisedSurface: Color(hex: 0x2F3D35),
            overlay: Color(hex: 0x444D49), text: Color(hex: 0xFEFAFF), mutedText: Color(hex: 0x919595),
            border: Color(hex: 0x2F3833), input: Color(hex: 0x4F725F), accent: Color(hex: 0xDCB560),
            sidebar: Color(hex: 0x28372E), selection: Color(hex: 0x395543), showsSeparators: false)
    )

    static let all = [system, iris, grove]
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The chosen theme and appearance, persisted in UserDefaults.
@MainActor @Observable
final class ThemeSettings {
    static let shared = ThemeSettings()

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "theme") }
    }
    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    var theme: AppTheme { AppTheme.all.first { $0.id == themeID } ?? .system }

    func palette(for scheme: ColorScheme) -> ThemePalette? {
        theme.palette(for: scheme)
    }

    private init() {
        themeID = UserDefaults.standard.string(forKey: "theme") ?? AppTheme.system.id
        appearance = UserDefaults.standard.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
    }
}

// MARK: - Applying the theme

extension View {
    /// Accent color and light/dark override. Apply at the root of each window and sheet.
    func themedRoot() -> some View { modifier(ThemedRoot()) }

    /// Theme background behind a screen (List, Form, ScrollView or plain view).
    /// `sidebar` uses the theme's list-column color (wide screens).
    func themedBackground(sidebar: Bool = false) -> some View { modifier(ThemedBackground(sidebar: sidebar)) }

    /// Theme row background and separators. `raised` for grouped rows (e.g. Settings) on the background.
    func themedRow(raised: Bool = false) -> some View { modifier(ThemedRow(raised: raised)) }

    /// Theme text colors: `.primary` text uses the theme's Text color and `.secondary` its Muted text.
    /// Apply to content, not to views that own toolbars (buttons there should keep the accent).
    func themedText() -> some View { modifier(ThemedText()) }

    /// A clip row in the wide-screen sidebar: transparent, with a rounded highlight when selected.
    func themedSidebarRow(selected: Bool) -> some View { modifier(ThemedSidebarRow(selected: selected)) }
}

private struct ThemedRoot: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let settings = ThemeSettings.shared
        content
            .tint(settings.palette(for: scheme)?.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
    }
}

private struct ThemedBackground: ViewModifier {
    let sidebar: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemeSettings.shared.palette(for: scheme)
        content
            .scrollContentBackground(palette == nil ? .automatic : .hidden)
            .background {
                if let palette {
                    (sidebar ? palette.sidebar ?? palette.background : palette.background).ignoresSafeArea()
                }
            }
    }
}

private struct ThemedText: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemeSettings.shared.palette(for: scheme)
        content.foregroundStyle(palette?.text ?? Color.primary, palette?.mutedText ?? Color.secondary)
    }
}

private struct ThemedSidebarRow: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemeSettings.shared.palette(for: scheme)
        let highlight = palette.map { $0.selection ?? $0.overlay } ?? Color(.systemGray5)
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? highlight : .clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            )
            .listRowSeparator(palette?.showsSeparators == false ? .hidden : .automatic)
            .listRowSeparatorTint(palette?.border)
    }
}

private struct ThemedRow: ViewModifier {
    let raised: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemeSettings.shared.palette(for: scheme)
        content
            .listRowBackground(palette.map { raised ? $0.raisedSurface : $0.surface })
            .listRowSeparator(!raised && palette?.showsSeparators == false ? .hidden : .automatic)
            .listRowSeparatorTint(palette?.border)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

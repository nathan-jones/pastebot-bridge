import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Bindable private var themeSettings = ThemeSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    ForEach(AppTheme.all) { theme in
                        Button { themeSettings.themeID = theme.id } label: {
                            HStack(spacing: 12) {
                                ThemeSwatch(palette: theme.palette(for: scheme))
                                Text(theme.name).foregroundStyle(.primary)
                                Spacer()
                                if themeSettings.themeID == theme.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                        }
                        .accessibilityAddTraits(themeSettings.themeID == theme.id ? .isSelected : [])
                    }
                    .themedRow(raised: true)
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $themeSettings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .themedRow(raised: true)
                }
            }
            .themedText()
            .themedBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .themedRoot()
    }
}

/// Sidebar, selection and accent of a theme in the current appearance.
private struct ThemeSwatch: View {
    let palette: ThemePalette?

    var body: some View {
        let colors: [Color] = if let palette {
            [palette.sidebar ?? palette.background, palette.selection ?? palette.overlay, palette.accent]
        } else {
            [Color(.systemBackground), Color(.secondarySystemBackground), .accentColor]
        }
        HStack(spacing: -6) {
            ForEach(colors.indices, id: \.self) { index in
                Circle()
                    .fill(colors[index])
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

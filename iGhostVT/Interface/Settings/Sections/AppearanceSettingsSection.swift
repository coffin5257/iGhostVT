//
//  AppearanceSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// Whether the interface follows the system's light or dark setting, then
/// the two theme slots, light and dark; each slot opens the catalog list.
/// The accent is the theme's (`InterfaceAccent`).
struct AppearanceSettingsSection: View {
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    private var appearanceTitle: String {
        (AppearancePreference(rawValue: appearance) ?? .system).title
    }

    var body: some View {
        Section {
            HStack {
                Text("Appearance")
                    .layoutPriority(1)
                Spacer()
                Menu {
                    AppearancePreferenceItems(rawValue: $appearance)
                } label: {
                    HStack(spacing: DS.Padding.xs) {
                        Text(verbatim: appearanceTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .accessibilityLabel("Appearance")
                .accessibilityValue(appearanceTitle)
            }
            NavigationLink {
                ThemeListView(slot: .light)
            } label: {
                VStack(alignment: .leading, spacing: DS.Padding.xs) {
                    Text("Light Theme")
                    Text(verbatim: ThemeSlot.light.label(in: theme.selection))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("Light Theme")
            .accessibilityValue(ThemeSlot.light.label(in: theme.selection))
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                VStack(alignment: .leading, spacing: DS.Padding.xs) {
                    Text("Dark Theme")
                    Text(verbatim: ThemeSlot.dark.label(in: theme.selection))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("Dark Theme")
            .accessibilityValue(ThemeSlot.dark.label(in: theme.selection))
        } header: {
            Text("Appearance")
                .font(DS.Font.caption)
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
                .font(DS.Font.detail)
        }
    }
}

/// The appearance menu's items, shared with the Mac's settings window; the
/// current choice is checked. Buttons rather than a Picker, as with the
/// shell menu (`ShellMenuItems`).
struct AppearancePreferenceItems: View {
    @Binding var rawValue: String

    var body: some View {
        ForEach(AppearancePreference.allCases) { choice in
            Button {
                rawValue = choice.rawValue
            } label: {
                if rawValue == choice.rawValue {
                    Label(choice.title, systemImage: "checkmark")
                } else {
                    Text(verbatim: choice.title)
                }
            }
        }
    }
}

extension ThemeSlot {
    /// What a settings row shows for the slot: the chosen theme's name, or
    /// the default's with a marker. Theme names are catalog data, so only
    /// the marker gets translated.
    @MainActor
    func label(in selection: AppTheme.Selection) -> String {
        let chosen = self == .light ? selection.lightName : selection.darkName
        if let chosen {
            return chosen
        }
        return String(
            format: NSLocalizedString("%@ (Default)", comment: "Theme name plus the default marker"),
            self == .light ? AppTheme.defaultLightName : AppTheme.defaultDarkName,
        )
    }
}

//
//  AppearanceSettingsSection.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Whether the interface follows the system's light or dark setting, the
/// size a new terminal opens at, then the two theme slots, light and dark
/// — each opens the catalog list. The accent is the theme's
/// (`InterfaceAccent`). The interface's own text size is the system's here
/// — Dynamic Type — and only the Mac, where Catalyst ignores it, has a
/// stepper for it.
struct AppearanceSettingsSection: View {
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue
    /// Read by `TerminalTab` when a surface is made; open tabs keep theirs.
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default

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
        }
        Section {
            Stepper(value: $terminalFontSize, in: TerminalFontSize.range) {
                SettingsValueRow(title: "Text Size", value: fontSizeDescription)
            }
            .accessibilityLabel("Text Size")
            .accessibilityValue(fontSizeDescription)
        } footer: {
            Text("Text size applies to new tabs.")
                .font(DS.Font.detail)
        }
        Section {
            NavigationLink {
                ThemeListView(slot: .light)
            } label: {
                themeLabel("Light Theme", slot: .light)
            }
            .accessibilityLabel("Light Theme")
            .accessibilityValue(ThemeSlot.light.label(in: theme.selection))
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                themeLabel("Dark Theme", slot: .dark)
            }
            .accessibilityLabel("Dark Theme")
            .accessibilityValue(ThemeSlot.dark.label(in: theme.selection))
        } footer: {
            Text("Themes come from the Ghostty theme catalog.")
                .font(DS.Font.detail)
        }
    }

    @ViewBuilder
    private func themeLabel(_ title: LocalizedStringKey, slot: ThemeSlot) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            VStack(alignment: .leading, spacing: DS.Padding.xs) {
                Text(title)
                    .lineLimit(1)
                Text(verbatim: slot.label(in: theme.selection))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: DS.Padding.m)
                Text(verbatim: slot.label(in: theme.selection))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var fontSizeDescription: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld pt", comment: "A font size in points"),
            terminalFontSize,
        )
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

//
//  ThemeShortlist.swift
//  iGhostVT
//

/// The themes the iOS list opens on, out of the catalog's nearly five
/// hundred: the best-known families, each with a light and a dark member
/// where the catalog has one. Picked by the VS Code Marketplace installs of
/// each family's theme and the GitHub stars of its project (2026-10-12),
/// with the Apple, One and Tokyo Night families kept whatever they ranked.
/// The rest stay one Show All away, and search always covers everything.
enum ThemeShortlist {
    static let names: Set<String> = [
        // Apple, and Xcode beside it
        "Apple Classic", "Apple System Colors", "Apple System Colors Light",
        "Xcode Dark", "Xcode Light",
        // One; Ghostty's own default is One Dark Pro's background
        "Atom One Dark", "Atom One Light", "One Half Dark", "One Half Light",
        "One Double Dark", "One Double Light", "Ghostty Default Style Dark",
        // Tokyo Night
        "TokyoNight", "TokyoNight Day", "TokyoNight Moon", "TokyoNight Night", "TokyoNight Storm",
        // The rest, most installed first
        "GitHub Light Default", "GitHub Dark Default", "GitHub Dark Dimmed",
        "Dracula",
        "Material", "Material Darker",
        "Ayu", "Ayu Mirage", "Ayu Light",
        "Monokai Pro", "Monokai Pro Light",
        "Night Owl", "Light Owl",
        "Shades Of Purple",
        "Cobalt2",
        "Andromeda",
        "Catppuccin Latte", "Catppuccin Frappe", "Catppuccin Macchiato", "Catppuccin Mocha",
        "Nord", "Nord Light",
        "Gruvbox Dark", "Gruvbox Light",
        "JetBrains Darcula",
        "Aura",
        "Bluloco Dark", "Bluloco Light",
        "Oceanic Next",
        "Horizon",
        "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn",
        "Kanagawa Wave", "Kanagawa Lotus",
        "Tomorrow", "Tomorrow Night",
        "iTerm2 Solarized Dark", "iTerm2 Solarized Light",
        "Everforest Dark Hard", "Everforest Light Med",
        "Nightfox", "Dayfox",
    ]
}

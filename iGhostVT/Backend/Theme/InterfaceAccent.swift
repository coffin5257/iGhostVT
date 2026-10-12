//
//  InterfaceAccent.swift
//  iGhostVT
//

import GhosttyTheme
import SwiftUI
import UIKit

/// The accent the interface is tinted with — selections, switches, links,
/// filled buttons, and on the Mac what AppKit draws in the accent itself.
/// It is the terminal theme's, never a setting of its own: the light and
/// dark themes already say how the app looks, and a fixed accent beside
/// them was one more choice that rarely matched either.
///
/// Each theme gives its blue — the bright one (palette 12) on a dark
/// background, the normal one (4) on a light one, the other as fallback —
/// the slot a theme keeps its own idea of blue in (Dracula's is a violet).
/// The user's Ghostty lines are read on top, exactly as the terminal reads
/// them, so `palette = 12=#…` there is how someone picks an accent.
/// The colour is darkened, hue kept, until white reads on it (a filled
/// button puts white text there) and it reads on a light background; one
/// that then sinks into a dark background, or a theme with neither slot,
/// gives the asset catalog's accent.
enum InterfaceAccent {
    /// An sRGB colour, plain values so AppKit's drawing threads can read it.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let white = RGB(red: 1, green: 1, blue: 1)

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#rrggbb` or `rrggbb`, as ghostty writes them; anything else is nil.
        init?(hex: String) {
            var hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
            )
        }

        init(_ color: UIColor) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.init(red: red, green: green, blue: blue)
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ channel: Double) -> Double {
                let channel = min(max(channel, 0), 1)
                return channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Every channel scaled alike: HSB brightness, hue and saturation kept.
        func darkened(by factor: Double) -> RGB {
            RGB(red: red * factor, green: green * factor, blue: blue * factor)
        }

        var uiColor: UIColor {
            UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
    }

    /// The accent for each appearance, always resolved — a theme without
    /// one has the asset catalog's in its place.
    struct Pair: Equatable {
        var light: RGB
        var dark: RGB
    }

    private static let minimumContrast = 3.0

    /// The accent of one theme with the user's lines read over it; nil
    /// when nothing in it qualifies. A line whose colour is not hex (an
    /// X11 name, which ghostty also takes) is passed over and the theme's
    /// own colour stands.
    static func derive(from definition: GhosttyThemeDefinition?, custom: [(key: String, value: String)]) -> RGB? {
        guard let definition else { return nil }
        var palette = definition.palette
        var backgroundHex = definition.background
        for entry in custom {
            switch entry.key {
            case "background" where RGB(hex: entry.value) != nil:
                backgroundHex = entry.value
            case "palette":
                // `N=#rrggbb`; a later line wins, as in ghostty.
                let parts = entry.value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, RGB(hex: String(parts[1])) != nil,
                   let index = Int(parts[0].trimmingCharacters(in: .whitespaces))
                {
                    palette[index] = String(parts[1])
                }
            default:
                break
            }
        }
        guard let background = RGB(hex: backgroundHex) else { return nil }
        let isDark = background.luminance < 0.5
        for slot in isDark ? [12, 4] : [4, 12] {
            guard var color = palette[slot].flatMap(RGB.init(hex:)) else { continue }
            let mustReadOn = isDark ? [RGB.white] : [RGB.white, background]
            var steps = 0
            while mustReadOn.contains(where: { color.contrast(with: $0) < minimumContrast }), steps < 60 {
                color = color.darkened(by: 0.95)
                steps += 1
            }
            if isDark, color.contrast(with: background) < minimumContrast { continue }
            return color
        }
        return nil
    }

    /// The accent for what Settings holds now.
    @MainActor
    static var current: Pair {
        let theme = AppTheme.shared
        let custom = GhosttyAppConfiguration.customConfiguration
        if let cached, cached.selection == theme.selection, cached.custom == custom {
            return cached.pair
        }
        let entries = GhosttyAppConfiguration.customEntries(in: custom)
        let fallback = UIColor(named: "AccentColor") ?? .systemBlue
        let pair = Pair(
            light: derive(from: theme.lightDefinition, custom: entries)
                ?? RGB(fallback.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))),
            dark: derive(from: theme.darkDefinition, custom: entries)
                ?? RGB(fallback.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))),
        )
        cached = (theme.selection, custom, pair)
        return pair
    }

    @MainActor
    private static var cached: (selection: AppTheme.Selection, custom: String, pair: Pair)?

    /// The colour, following light and dark as a system colour does.
    ///
    /// The provider is `@Sendable` so it is nonisolated: written inside
    /// this `@MainActor` getter it inherited the main actor, and Swift 6
    /// checks that on entry — but SwiftUI resolves colours on its async
    /// renderer thread (iOS 27), and the check trapped there
    /// (`_dispatch_assert_queue_fail`, GhostRemote 1.6.4).
    @MainActor
    static var uiColor: UIColor {
        let light = current.light.uiColor
        let dark = current.dark.uiColor
        return UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    /// UIKit's half: every window's `tintColor`, which every UIKit control
    /// and the text system inherit. Windows made later pick it up from the
    /// root modifier's first appearance. On the Mac, AppKit's own accent
    /// follows too (`CatalystAccentColor`).
    @MainActor
    static func applyToWindows() {
        #if targetEnvironment(macCatalyst)
            CatalystAccentColor.update(current)
        #endif
        let tint = uiColor
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = tint
            }
        }
    }
}

/// SwiftUI's half: the tint and the accent colour every view under a
/// hosting controller's root reads (`Color.accentColor` included), and the
/// windows' UIKit tint kept in step as the theme or the user's lines change.
private struct InterfaceAccentModifier: ViewModifier {
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage(GhosttyAppConfiguration.customConfigurationKey) private var customConfiguration = ""

    func body(content: Content) -> some View {
        let color = Color(uiColor: InterfaceAccent.uiColor)
        content
            .accentColor(color)
            .tint(color)
            .onAppear(perform: InterfaceAccent.applyToWindows)
            .onChange(of: theme.selection) { _ in
                InterfaceAccent.applyToWindows()
            }
            .onChange(of: customConfiguration) { _ in
                InterfaceAccent.applyToWindows()
            }
    }
}

extension View {
    /// Tints everything under this view with the theme's accent; goes at
    /// the root of every hosting controller, beside `interfaceTextSize()`.
    func interfaceAccent() -> some View {
        modifier(InterfaceAccentModifier())
    }
}

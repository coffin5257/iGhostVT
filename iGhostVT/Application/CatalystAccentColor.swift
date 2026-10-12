//
//  CatalystAccentColor.swift
//  iGhostVT
//

import Foundation

#if targetEnvironment(macCatalyst)
    import ObjectiveC

    /// The theme accent's AppKit half (`InterfaceAccent`). What AppKit draws
    /// itself — a menu's highlighted item, focus rings — never asks UIKit
    /// for a tint; it asks `+[NSColor controlAccentColor]`, which answers
    /// the app's own accent (`NSAccentColorName`). `install()` puts a
    /// wrapper on that class method that answers the theme's accent
    /// instead, as a dynamic `NSColor` that resolves light or dark against
    /// the appearance it is drawn in; until the first `update` it calls
    /// straight through.
    ///
    /// Not everything AppKit tints asks that method: the settings window's
    /// selected toolbar pane reads the application's own accent
    /// (`-[NSApplication _effectiveAccentColor]`, which is `_accentColor`
    /// when one is set and the asset catalog's otherwise), so `update` sets
    /// that too (`_setAccentColor:`).
    ///
    /// AppKit is reached through the ObjC runtime, as in
    /// `CatalystWindowChrome`: a class or selector that no longer exists
    /// leaves AppKit's own accent in place.
    enum CatalystAccentColor {
        /// The `NSColor` answered for the accent; nil is no override.
        /// AppKit asks from whatever thread it draws on.
        private nonisolated(unsafe) static var override: AnyObject?
        private static let lock = NSLock()
        /// The accent `override` was made from. Main thread only.
        private nonisolated(unsafe) static var overridePair: InterfaceAccent.Pair?
        /// What `NSApp` was last given; nil until the app is up.
        /// Main thread only, where `update` is called once the app is up.
        private nonisolated(unsafe) static var applicationAccent: InterfaceAccent.Pair?

        @MainActor
        static func install() {
            guard let colorClass = NSClassFromString("NSColor"),
                  let metaclass = object_getClass(colorClass)
            else { return }
            let selector = sel_registerName("controlAccentColor")
            guard let method = class_getClassMethod(colorClass, selector) else { return }
            let original = method_getImplementation(method)
            typealias Original = @convention(c) (AnyObject, Selector) -> AnyObject
            let block: @convention(block) (AnyObject) -> AnyObject = { target in
                lock.lock()
                let chosen = override
                lock.unlock()
                return chosen ?? unsafeBitCast(original, to: Original.self)(target, selector)
            }
            class_replaceMethod(
                metaclass,
                selector,
                imp_implementationWithBlock(block),
                method_getTypeEncoding(method),
            )
            update(InterfaceAccent.current, includingApplication: false)
        }

        /// Swaps the colour AppKit answers and has every AppKit view redraw
        /// with it, as a change in System Settings would.
        /// Every hosting root calls this as it appears, so only an actual
        /// change tells AppKit to redraw.
        ///
        /// The application's own accent is set only once the app is up
        /// (`install` runs before `UIApplicationMain`, and asking for
        /// `NSApp` there would make one too early), so the first hosting
        /// root to appear is what applies it.
        @MainActor
        static func update(_ pair: InterfaceAccent.Pair, includingApplication: Bool = true) {
            let changed = pair != overridePair
            if changed, let color = makeColor(pair) {
                overridePair = pair
                lock.lock()
                override = color
                lock.unlock()
            }
            if includingApplication, applicationAccent != pair {
                applicationAccent = pair
                setApplicationAccent(currentOverride)
            }
            guard changed else { return }
            NotificationCenter.default.post(
                name: Notification.Name("NSSystemColorsDidChangeNotification"),
                object: nil,
            )
        }

        private static var currentOverride: AnyObject? {
            lock.lock()
            defer { lock.unlock() }
            return override
        }
    }

    fileprivate extension CatalystAccentColor {
        /// `+[NSColor colorWithName:dynamicProvider:]` over the two sRGB
        /// colours, picking by `-[NSAppearance
        /// bestMatchFromAppearancesWithNames:]`; nil if either is gone.
        static func makeColor(_ pair: InterfaceAccent.Pair) -> AnyObject? {
            guard let colorClass = NSClassFromString("NSColor") as? NSObject.Type else { return nil }
            let srgbSelector = sel_registerName("colorWithSRGBRed:green:blue:alpha:")
            let dynamicSelector = sel_registerName("colorWithName:dynamicProvider:")
            guard let srgbMethod = class_getClassMethod(colorClass, srgbSelector),
                  let dynamicMethod = class_getClassMethod(colorClass, dynamicSelector)
            else { return nil }
            typealias SRGB = @convention(c) (AnyObject, Selector, CGFloat, CGFloat, CGFloat, CGFloat) -> AnyObject
            typealias Provider = @convention(block) (AnyObject) -> AnyObject
            typealias Dynamic = @convention(c) (AnyObject, Selector, AnyObject?, Provider) -> AnyObject
            let srgb = unsafeBitCast(method_getImplementation(srgbMethod), to: SRGB.self)
            func color(_ rgb: InterfaceAccent.RGB) -> AnyObject {
                srgb(colorClass, srgbSelector, rgb.red, rgb.green, rgb.blue, 1)
            }
            let light = color(pair.light)
            let dark = color(pair.dark)
            let matchSelector = sel_registerName("bestMatchFromAppearancesWithNames:")
            let names = ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"] as NSArray
            let provider: Provider = { appearance in
                guard appearance.responds(to: matchSelector),
                      let match = appearance.perform(matchSelector, with: names)?.takeUnretainedValue() as? String
                else { return light }
                return match == "NSAppearanceNameDarkAqua" ? dark : light
            }
            let dynamic = unsafeBitCast(method_getImplementation(dynamicMethod), to: Dynamic.self)
            return dynamic(colorClass, dynamicSelector, nil, provider)
        }

        /// `NSApp._setAccentColor:`; a selector that is gone is left alone.
        static func setApplicationAccent(_ color: AnyObject?) {
            guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let application = applicationClass.value(forKey: "sharedApplication") as? NSObject
            else { return }
            let setter = sel_registerName("_setAccentColor:")
            guard application.responds(to: setter) else { return }
            application.perform(setter, with: color)
        }
    }
#endif

//
//  KeyboardSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// Shortcuts on every platform; the accessory bar is a software-keyboard
/// fixture, and a Mac has none.
struct KeyboardSettingsSection: View {
    var body: some View {
        Section {
            #if !targetEnvironment(macCatalyst)
                NavigationLink {
                    KeyboardBarSettingsView()
                } label: {
                    Text("Accessory Keys")
                }
            #endif
            NavigationLink {
                ShortcutsSettingsView()
            } label: {
                Text("Shortcuts")
            }
        } header: {
            Text("Keyboard")
                .font(DS.Font.caption)
        }
    }
}

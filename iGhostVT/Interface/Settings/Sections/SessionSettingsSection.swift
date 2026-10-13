//
//  SessionSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What a launch opens and what the new-tab menu remembers.
/// Ghost Remote has no shell of its own to start,
/// so it has no launch switch.
struct SessionSettingsSection: View {
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    @ObservedObject private var recents = RecentDirectoryStore.shared

    var body: some View {
        if !AppEdition.isRemoteOnly {
            Section {
                Toggle("New Session at Launch", isOn: $opensNewSession)
            } footer: {
                Text("New Session at Launch starts a shell on this device when there is nothing to resume.")
                    .font(DS.Font.detail)
            }
        }
        Section {
            Toggle("Recent Directories", isOn: $recents.isEnabled)
        } footer: {
            Text("Recent Directories lists where your terminals have been in New Tab.")
                .font(DS.Font.detail)
        }
    }
}

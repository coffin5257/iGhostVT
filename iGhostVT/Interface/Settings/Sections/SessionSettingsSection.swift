//
//  SessionSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What a launch opens, what the new-tab menu remembers, and the way into
/// Settings ▸ Remote Access. Ghost Remote has no shell of its own to start,
/// so it has no launch switch.
struct SessionSettingsSection: View {
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    @ObservedObject private var recents = RecentDirectoryStore.shared

    var body: some View {
        Section {
            if !AppEdition.isRemoteOnly {
                Toggle("New Session at Launch", isOn: $opensNewSession)
            }
            Toggle("Recent Directories", isOn: $recents.isEnabled)
            NavigationLink {
                RemoteAccessView()
            } label: {
                Text("Remote Access")
            }
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            Group {
                if AppEdition.isRemoteOnly {
                    Text("Recent Directories lists where your terminals have been in New Tab.")
                } else {
                    Text(
                        """
                        New Session at Launch starts a shell on this device when there \
                        is nothing to resume. Recent Directories lists where your \
                        terminals have been in New Tab.
                        """,
                    )
                }
            }
            .font(DS.Font.detail)
        }
    }
}

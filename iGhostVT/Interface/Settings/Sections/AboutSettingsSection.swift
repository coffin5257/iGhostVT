//
//  AboutSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// Version, the licenses, and the raw Ghostty configuration.
struct AboutSettingsSection: View {
    var body: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionDescription)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Version")
            .accessibilityValue(Self.versionDescription)
            NavigationLink {
                LicensesView()
            } label: {
                Text("Licenses")
            }
            NavigationLink {
                GhosttyConfigurationView()
            } label: {
                Text("Ghostty Configuration")
            }
        }
    }

    /// "1.1.0 (87)", shared with the Mac's About pane.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

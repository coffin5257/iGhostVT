//
//  iGhostVTWidgetsBundle.swift
//  iGhostVTWidgets
//

import SwiftUI
import WidgetKit

/// The extension deploys to the app's floor, iOS 15.0, because the system
/// launches it there too — a jailbreak install registers it whatever its
/// minimum OS says, and an extension built for 16.2 died in dyld on 15
/// (ActivityKit is not there). Below 16.2 the bundle is empty; ActivityKit
/// is linked weakly (`-weak_framework ActivityKit` on both widget targets).
@main
struct iGhostVTWidgetsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            TerminalSessionActivityWidget()
        }
    }
}

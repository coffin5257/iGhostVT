import SwiftUI
import UIKit

/// The tab overview as UIKit presents it.
///
/// `fullScreenCover` presents on the change of a bool and keeps that bool up
/// when UIKit refuses the request; the panel's being on screen is the state
/// here instead (`WindowInterfaceState.openSwitcher` says why). It is the
/// whole window, sliding up the way the cover did, and it hosts the same
/// `TabSwitcherView` the cover did.
final class TabSwitcherPanel: OverlayPanelController {
    private let tabManager: TabManager
    private let onClose: () -> Void

    /// It has taken the window.
    var onAppear: (() -> Void)?
    /// It has left it, whichever way.
    var onDisappear: (() -> Void)?

    init(tabManager: TabManager, onClose: @escaping () -> Void) {
        self.tabManager = tabManager
        self.onClose = onClose
        super.init()
        // The base class is the alert's cross-dissolve over the pane; the
        // overview replaces the window's content, as the cover did.
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .coverVertical
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        install(TabSwitcherView(tabManager: tabManager) { [weak self] in
            self?.onClose()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

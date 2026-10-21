//
//  TabDragHover.swift
//  iGhostVT
//

import SwiftUI
import UniformTypeIdentifiers

/// A drag from elsewhere — a file out of the Finder, a snippet of text, an
/// image — held over a tab brings that tab to the front, the way a
/// browser's tab strip does, so the drop can land on its terminal. That is
/// all a tab does with it: it accepts nothing, a release over it ends the
/// drag with nothing pasted, and the drop itself still goes to the terminal
/// (`TerminalDropDelegate`) and takes its usual path. The tab waits a beat
/// (`dwell`) before it switches, so a drag crossing the sidebar on its way
/// to the terminal does not flip every tab it passes. A tab's own drag is
/// the reorder's (`TabReorder`) and never switches anything.
@MainActor
enum TabDragHover {
    /// How long the pointer rests on a tab before the tab comes forward.
    static let dwellNanoseconds: UInt64 = 400_000_000

    /// The type a hover target registers for: everything, since whatever
    /// the terminal could take is worth switching for. A tab's own drag
    /// conforms to nothing and so is not among it (`TabReorder.itemType`).
    static let types: [UTType] = [.item]

    /// The tab the pointer rests on and the switch waiting for it. One drag
    /// at a time is all the system allows, so one record suffices.
    private static var pending: (tabID: UUID, switch: Task<Void, Never>)?

    /// Whether this hover answers `info`: anything but a tab's own drag.
    static func answers(_ info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [TabReorder.itemType])
    }

    static func enter(_ tab: TerminalTab, in tabManager: TabManager) {
        guard pending?.tabID != tab.id else { return }
        pending?.switch.cancel()
        let switchTab = Task { @MainActor [weak tab, weak tabManager] in
            try? await Task.sleep(nanoseconds: dwellNanoseconds)
            guard !Task.isCancelled, let tab, let tabManager else { return }
            pending = nil
            tabManager.activate(tab)
        }
        pending = (tab.id, switchTab)
    }

    static func leave(_ tab: TerminalTab) {
        guard let pending, pending.tabID == tab.id else { return }
        pending.switch.cancel()
        self.pending = nil
    }
}

/// A tab presentation that only switches (the top bar's chips); a sidebar
/// row reorders as well, and its slot delegate answers both
/// (`TabReorderSlotDelegate`).
struct TabDragHoverDelegate: DropDelegate {
    let tab: TerminalTab
    let tabManager: TabManager

    func validateDrop(info: DropInfo) -> Bool {
        TabDragHover.answers(info)
    }

    func dropEntered(info _: DropInfo) {
        TabDragHover.enter(tab, in: tabManager)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }

    func dropExited(info _: DropInfo) {
        TabDragHover.leave(tab)
    }

    func performDrop(info _: DropInfo) -> Bool {
        TabDragHover.leave(tab)
        return false
    }
}

extension View {
    /// Brings `tab` forward when a drag from elsewhere rests on this view.
    func switchesOnDragHover(_ tab: TerminalTab, in tabManager: TabManager) -> some View {
        onDrop(of: TabDragHover.types, delegate: TabDragHoverDelegate(tab: tab, tabManager: tabManager))
    }
}

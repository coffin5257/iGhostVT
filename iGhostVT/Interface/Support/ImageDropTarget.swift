//
//  ImageDropTarget.swift
//  iGhostVT
//

import SwiftUI
import UIKit

extension View {
    /// Accepts an image dropped anywhere on the screen this view belongs to.
    ///
    /// SwiftUI's `onDrop` on a `Form` never saw a drop: the form is a
    /// collection view with a drop delegate of its own over the whole
    /// screen, and at the moment of release UIKit hands the drop to it — the
    /// deeper view — which declines anything that is not a row to insert.
    /// So this hangs a `UIDropInteraction` on the hosting controller's own
    /// view, an ancestor of the list, and takes the list's drop delegate
    /// away; a screen asking for an image has no row to insert.
    func onImageDrop(perform action: @escaping (UIImage) -> Void) -> some View {
        background(ImageDropTarget(onImage: action).frame(width: 0, height: 0))
    }
}

private struct ImageDropTarget: UIViewRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIView(context _: Context) -> AnchorView {
        AnchorView()
    }

    func updateUIView(_ view: AnchorView, context _: Context) {
        view.delegate.onImage = onImage
        // SwiftUI may hand the list its delegate back as it updates.
        DispatchQueue.main.async { view.disableListDrops() }
    }

    final class AnchorView: UIView {
        let delegate = Delegate()
        private var interaction: UIDropInteraction?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let interaction {
                interaction.view?.removeInteraction(interaction)
                self.interaction = nil
            }
            guard window != nil, let host = hostingView() else { return }
            let interaction = UIDropInteraction(delegate: delegate)
            host.addInteraction(interaction)
            self.interaction = interaction
            // After SwiftUI has built the list.
            DispatchQueue.main.async { [weak self] in self?.disableListDrops() }
        }

        func disableListDrops() {
            if let host = interaction?.view {
                Self.disableListDrops(in: host)
            }
        }

        private static func disableListDrops(in view: UIView) {
            if let list = view as? UICollectionView {
                list.dropDelegate = nil
            }
            view.subviews.forEach(disableListDrops(in:))
        }

        /// The nearest ancestor that is a view controller's root view.
        private func hostingView() -> UIView? {
            var view = superview
            while let current = view {
                if current.next is UIViewController {
                    return current
                }
                view = current.superview
            }
            return nil
        }
    }

    final class Delegate: NSObject, UIDropInteractionDelegate {
        var onImage: ((UIImage) -> Void)?

        func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.canLoadObjects(ofClass: UIImage.self)
        }

        func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
            guard let item = session.items.first(where: { $0.itemProvider.canLoadObject(ofClass: UIImage.self) })
            else { return }
            item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    self?.onImage?(image)
                }
            }
        }
    }
}

//
//  DraggableHUDOverlay.swift
//  rootshellVNC
//
//  Hosts the floating HUD menu over the remote desktop and drags it with a
//  native UIPanGestureRecognizer instead of a SwiftUI DragGesture. A SwiftUI
//  drag on a control-laden HUD stutters and fights the controls for touches;
//  hosting the content in a UIHostingController with a native pan fixes that.
//

#if canImport(UIKit)
import SwiftUI
import UIKit

/// Wraps `content` in a UIKit host that fills the available area, anchors the
/// HUD at the bottom-trailing corner, and lets a native pan move it. Touches
/// outside the HUD fall through to whatever is below (the remote desktop).
struct DraggableHUDOverlay<Content: View>: UIViewRepresentable {
    var inset: CGFloat = 12
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> DraggableHUDOverlayHostView {
        let view = DraggableHUDOverlayHostView()
        view.inset = inset

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        // Self-size to the SwiftUI content instead of the proposed bounds.
        host.sizingOptions = .intrinsicContentSize
        context.coordinator.host = host

        view.hostController = host
        view.hostedView = host.view
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        view.attachPan()
        return view
    }

    func updateUIView(_ uiView: DraggableHUDOverlayHostView, context: Context) {
        // Keep the hosted SwiftUI view in sync. The HUD's position lives on
        // the UIView and is untouched by content updates.
        context.coordinator.host?.rootView = AnyView(content())
        uiView.inset = inset
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(
        _ uiView: DraggableHUDOverlayHostView,
        coordinator: Coordinator
    ) {
        coordinator.host?.willMove(toParent: nil)
        coordinator.host?.view.removeFromSuperview()
        coordinator.host?.removeFromParent()
        coordinator.host = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Erased to UIHostingController<AnyView> (not <Content>) and given an
    // explicit deinit: the swift-frontend optimizer crashes in EarlyPerfInliner
    // while inlining the synthesized deinit of a coordinator holding a generic
    // UIHostingController<Content> at -O (swiftlang/swift#89851, #90150).
    // Release-only; Debug (-Onone) is unaffected.
    final class Coordinator {
        var host: UIHostingController<AnyView>?

        deinit {
            host = nil
        }
    }
}

/// Non-generic host so the pan handler can be an `@objc` selector target
/// (a generic UIView cannot expose `@objc` members to the Obj-C runtime).
@MainActor
final class DraggableHUDOverlayHostView: UIView, UIGestureRecognizerDelegate {
    weak var hostController: UIViewController?
    weak var hostedView: UIView?
    var inset: CGFloat = 12

    /// Once the user drags the HUD we preserve their chosen position. Before
    /// that, the HUD is re-anchored bottom-trailing on every layout pass so a
    /// wrong intermediate measurement (SwiftUI not having computed the
    /// content's ideal size yet) self-corrects instead of latching.
    private var userHasDragged = false
    private var panStartCenter: CGPoint = .zero

    // MARK: VC containment

    /// Adopt the hosting controller as a proper child VC once we're in a
    /// window. Required for the hosted Menu to present its popup when this
    /// overlay is nested inside a UIKit container.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil,
              let controller = hostController, controller.parent == nil,
              let parent = nearestViewController() else { return }
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: Dragging

    func attachPan() {
        guard let bar = hostedView else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        // Default cancelsTouchesInView == true: a tap never reaches the pan's
        // movement threshold (so the menu button gets it), but once a drag
        // starts the underlying control's touch is cancelled and the HUD
        // moves cleanly.
        bar.addGestureRecognizer(pan)
    }

    /// Yield to a scroll view so dragging a hosted list scrolls it; the HUD
    /// is dragged by its chrome. `override` because UIView declares this too
    /// (it also satisfies the UIGestureRecognizerDelegate requirement).
    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let bar = hostedView else { return false }
        let point = gestureRecognizer.location(in: bar)
        var view = bar.hitTest(point, with: nil)
        while let current = view, current !== bar {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                return false
            }
            view = current.superview
        }
        return true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let bar = hostedView else { return }
        switch gesture.state {
        case .began:
            userHasDragged = true
            panStartCenter = bar.center
        case .changed:
            let translation = gesture.translation(in: self)
            bar.center = clamp(
                CGPoint(
                    x: panStartCenter.x + translation.x,
                    y: panStartCenter.y + translation.y),
                size: bar.bounds.size)
        default:
            break
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bar = hostedView, bounds.width > 0, bounds.height > 0 else { return }

        // Ask the hosting controller for the SwiftUI content's ideal size
        // directly. This forces layout of the content synchronously, so the
        // FIRST measurement is already correct, unlike systemLayoutSizeFitting
        // which returns a near-full-bounds size before SwiftUI has computed
        // the content and makes the HUD flash at the wrong size/position.
        var size: CGSize
        if let host = hostController as? UIHostingController<AnyView> {
            size = host.sizeThatFits(in: UIView.layoutFittingCompressedSize)
        } else {
            size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        size.width = min(size.width, max(0, bounds.width - inset * 2))
        size.height = min(size.height, max(0, bounds.height - inset * 2))

        // Ignore degenerate measurements taken before SwiftUI computes the
        // content's ideal size; anchoring to them strands the HUD off-screen.
        guard size.width > 10, size.height > 10 else { return }

        if userHasDragged {
            // Preserve where the user dropped it; just resize and re-clamp on
            // rotation/resize.
            let center = bar.center
            bar.bounds = CGRect(origin: .zero, size: size)
            bar.center = clamp(center, size: size)
        } else {
            // Keep pinned bottom-trailing until the first drag. Re-anchoring
            // every pass means a wrong first measurement is corrected on the
            // next layout rather than latched.
            bar.frame = CGRect(
                x: bounds.width - size.width - inset,
                y: bounds.height - size.height - inset,
                width: size.width,
                height: size.height)
        }
    }

    private func clamp(_ center: CGPoint, size: CGSize) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        return CGPoint(
            x: min(max(center.x, halfW + inset), bounds.width - halfW - inset),
            y: min(max(center.y, halfH + inset), bounds.height - halfH - inset))
    }

    /// Only intercept touches that land on the HUD; everything else passes
    /// through to the remote desktop underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let bar = hostedView, bar.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif

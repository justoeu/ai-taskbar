import AppKit
import SwiftUI

/// An invisible AppKit tracking helper that centers its enclosing `NSScrollView`
/// on this view whenever `shouldCenter` becomes true.
/// Bypasses SwiftUI `ScrollViewReader` limitations inside `MenuBarExtra` windows.
@MainActor
public struct ScrollToCenterView: NSViewRepresentable {
    public let shouldCenter: Bool

    public init(shouldCenter: Bool) {
        self.shouldCenter = shouldCenter
    }

    public func makeNSView(context: Context) -> CenterTrackingNSView {
        let view = CenterTrackingNSView()
        view.isTargeted = shouldCenter
        if shouldCenter {
            view.triggerCenterScroll()
        }
        return view
    }

    public func updateNSView(_ nsView: CenterTrackingNSView, context: Context) {
        nsView.isTargeted = shouldCenter
        if shouldCenter {
            nsView.triggerCenterScroll()
        }
    }
}

@MainActor
public final class CenterTrackingNSView: NSView {
    var isTargeted: Bool = false

    public func triggerCenterScroll() {
        isTargeted = true
        // Run with staged delays to ensure parent transitions and layout passes are settled.
        for delay in [0.05, 0.20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isTargeted else { return }
                self.performCenterScroll()
            }
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isTargeted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performCenterScrollIfTargeted()
            }
        }
    }

    private func performCenterScrollIfTargeted() {
        guard isTargeted, enclosingScrollView != nil else { return }
        performCenterScroll()
    }

    private func performCenterScroll() {
        guard let scrollView = self.enclosingScrollView,
              let documentView = scrollView.documentView else { return }

        let rectInDocument = self.convert(self.bounds, to: documentView)
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0, rectInDocument.height > 0 else { return }

        let targetY = rectInDocument.midY - (visibleHeight / 2)
        let maxScrollY = max(0, documentView.bounds.height - visibleHeight)
        let clampedY = max(0, min(targetY, maxScrollY))
        let targetOrigin = NSPoint(x: scrollView.contentView.bounds.origin.x, y: clampedY)

        // Only animate if the delta is non-trivial (> 2 points)
        let currentY = scrollView.contentView.bounds.origin.y
        guard abs(currentY - clampedY) > 2 else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

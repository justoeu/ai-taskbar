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
        let changed = nsView.isTargeted != shouldCenter
        nsView.isTargeted = shouldCenter
        if shouldCenter && changed {
            nsView.triggerCenterScroll()
        }
    }
}

@MainActor
public final class CenterTrackingNSView: NSView {
    var isTargeted: Bool = false
    private var hasScrolled: Bool = false

    public func triggerCenterScroll() {
        isTargeted = true
        hasScrolled = false
        // Run with staged delays to ensure parent transitions and layout passes are settled.
        for delay in [0.05, 0.15, 0.30] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isTargeted, !self.hasScrolled else { return }
                self.performCenterScroll()
            }
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isTargeted && !hasScrolled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.isTargeted, !self.hasScrolled else { return }
                self.performCenterScroll()
            }
        }
    }

    private func performCenterScroll() {
        guard !hasScrolled else { return }
        guard let scrollView = self.enclosingScrollView,
              let documentView = scrollView.documentView else {
            return
        }

        let rectInDocument = self.convert(self.bounds, to: documentView)
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0, rectInDocument.height > 0 else {
            return
        }

        let targetY = rectInDocument.midY - (visibleHeight / 2)
        let maxScrollY = max(0, documentView.bounds.height - visibleHeight)
        let clampedY = max(0, min(targetY, maxScrollY))
        let targetOrigin = NSPoint(x: 0, y: clampedY)

        let currentY = scrollView.contentView.bounds.origin.y
        // Only animate if the delta is non-trivial (> 2 points)
        guard abs(currentY - clampedY) > 2 else {
            hasScrolled = true
            return
        }

        hasScrolled = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }, completionHandler: {
            MainActor.assumeIsolated {
                scrollView.contentView.scroll(to: targetOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        })
    }
}

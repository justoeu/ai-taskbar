import AppKit
import SwiftUI
import Combine
import AiTaskbarCore

@MainActor
public final class MainStatusItemHolder {
    public static let shared = MainStatusItemHolder()
    public weak var mainButton: NSStatusBarButton? {
        didSet {
            // The main item now exists, so pinned items created from here on
            // are placed to its left — the order the user expects.
            if oldValue == nil, mainButton != nil {
                PinnedStatusItemManager.shared.mainStatusItemDidAppear()
            }
        }
    }
    private init() {}
}

final class FinderTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        findAndStore()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        findAndStore()
    }

    private func findAndStore() {
        var current: NSView? = self
        while let c = current {
            if let btn = c as? NSStatusBarButton {
                MainStatusItemHolder.shared.mainButton = btn
                btn.toolTip = L10n.localizedString("app_name")
                btn.sendAction(on: [.leftMouseDown])
                return
            }
            current = c.superview
        }
        if let btn = window?.contentView as? NSStatusBarButton {
            MainStatusItemHolder.shared.mainButton = btn
            btn.toolTip = L10n.localizedString("app_name")
            btn.sendAction(on: [.leftMouseDown])
        }
    }
}

public struct StatusItemButtonFinder: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        FinderTrackingView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

public struct PinnedStatusBadgeView: View {
    public let vendorId: VendorId
    public let weekly: Double?
    public let current: Double
    public let thresholds: ThresholdsConfig

    public init(vendorId: VendorId, weekly: Double?, current: Double, thresholds: ThresholdsConfig) {
        self.vendorId = vendorId
        self.weekly = weekly
        self.current = current
        self.thresholds = thresholds
    }

    /// The standard menu-bar font (13 pt regular) — what the system draws
    /// the main item's percentage in. Both badge layouts use it so a pinned
    /// LLM reads exactly like the main icon, single line or stacked.
    private static let menuBarFont = Font(NSFont.menuBarFont(ofSize: 0))

    private var isFull: Bool {
        let maxVal = max(weekly ?? 0, current)
        return SeverityColor.showsFlame(forPercent: maxVal, thresholds: thresholds)
    }

    private var flameColor: Color {
        let maxVal = max(weekly ?? 0, current)
        return SeverityColor.flameTint(forPercent: maxVal, thresholds: thresholds)
    }

    public var body: some View {
        HStack(spacing: 3.5) {
            VendorIconView(vendorId: vendorId, size: 16)
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)

            if let weekly = weekly {
                VStack(alignment: .trailing, spacing: -1) {
                    Text("\(Int(saturating: weekly.rounded()))%")
                        .font(Self.menuBarFont)
                        .foregroundStyle(itemTint(for: weekly))
                    Text("\(Int(saturating: current.rounded()))%")
                        .font(Self.menuBarFont)
                        .foregroundStyle(itemTint(for: current))
                }
            } else {
                // The main MenuBarExtra label ignores its custom font: the
                // system draws it in the standard menu-bar font. This badge is
                // our own NSHostingView, so a custom font here WOULD apply and
                // render visibly larger than the main icon's percentage.
                // Use the very font the system uses for the main item.
                Text("\(Int(saturating: current.rounded()))%")
                    .font(Self.menuBarFont)
                    .foregroundStyle(itemTint(for: current))
            }

            if isFull {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(flameColor)
            }
        }
        .padding(.horizontal, 3)
        .allowsHitTesting(false)
    }

    private func itemTint(for percent: Double) -> Color {
        // Conforme solicitado: Quando o valor estiver tanto em laranja quanto em vermelho,
        // deixa em branco (primary) mas acrescenta o ícone de fogo.
        return .primary
    }
}

@MainActor
public final class PinnedStatusItemManager: ObservableObject {
    public static let shared = PinnedStatusItemManager()

    public struct SpaceCheckResult: Equatable, Sendable {
        public let allowed: Bool
        public let reason: String?

        public static let allowedResult = SpaceCheckResult(allowed: true, reason: nil)
        public static func denied(reason: String) -> SpaceCheckResult {
            SpaceCheckResult(allowed: false, reason: reason)
        }
    }

    public private(set) var statusItems: [VendorId: NSStatusItem] = [:]
    public var physicalItems: [NSStatusItem] { Array(statusItems.values) }
    public private(set) var currentOrderedPinned: [VendorId] = []
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: UsageStore?
    /// False until the main MenuBarExtra item is on the bar. A new status
    /// item is placed LEFT of every existing one, so a pinned item created
    /// before SwiftUI installs the main item ends up on its RIGHT. `configure`
    /// runs in `App.init`, before the scene exists, and neither the initial
    /// `@Published` emission nor a `DispatchQueue.main.async` reliably waits
    /// long enough — measured: the same build placed xAI on either side of
    /// the main icon from one launch to the next.
    private var mainItemReady = false
    /// Upper bound on waiting for the main item, so a lookup that never fires
    /// degrades to "possibly misordered" rather than "never shown".
    nonisolated static let mainItemWaitLimit: TimeInterval = 3

    public init() {}

    public func configure(store: UsageStore) {
        self.store = store
        cancellables.removeAll()

        store.$pinnedVendorOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncIfMainItemReady()
            }
            .store(in: &cancellables)

        store.$sortedVendors
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncIfMainItemReady()
            }
            .store(in: &cancellables)

        let stateStreams = store.vendors.map { $0.$state.map { _ in () }.eraseToAnyPublisher() }
        Publishers.MergeMany(stateStreams)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.syncIfMainItemReady()
            }
            .store(in: &cancellables)

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshTooltips()
            }
            .store(in: &cancellables)

        if MainStatusItemHolder.shared.mainButton != nil {
            mainStatusItemDidAppear()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mainItemWaitLimit) { [weak self] in
                self?.mainStatusItemDidAppear()
            }
        }
    }

    /// Called once the main status item is on the bar (or the wait expired).
    public func mainStatusItemDidAppear() {
        guard !mainItemReady else { return }
        mainItemReady = true
        syncIfMainItemReady()
    }

    private func syncIfMainItemReady() {
        guard mainItemReady else { return }
        syncStatusItems()
    }

    public func syncStatusItems() {
        guard let store else { return }

        let desiredOrder = store.pinnedVendorOrder
        let desiredSet = Set(desiredOrder)

        // 1. Remove status items for vendors that were unpinned.
        // Operating per-vendor leaves all other items intact without visual flicker or jumping.
        let toRemove = statusItems.filter { !desiredSet.contains($0.key) }
        for (vid, item) in toRemove {
            NSStatusBar.system.removeStatusItem(item)
            statusItems.removeValue(forKey: vid)
        }

        // 2. Add status items for newly pinned vendors in order. A new item
        // lands immediately left of this app's existing items, so creating
        // them in `pinnedVendorOrder` keeps the first pin next to the main
        // icon and each later pin one slot further left.
        for vid in desiredOrder where statusItems[vid] == nil {
            let item = Self.makePinnedStatusItem(for: vid)
            statusItems[vid] = item
            if let vm = store.vendorVM(vid) {
                updateButton(for: item, vm: vm, store: store)
            }
        }

        // 3. Update buttons for existing pinned items in-place.
        for vid in desiredOrder {
            if let item = statusItems[vid], let vm = store.vendorVM(vid) {
                updateButton(for: item, vm: vm, store: store)
            }
        }

        self.currentOrderedPinned = desiredOrder

        if let focused = lastFocusedPinnedVendor, !desiredSet.contains(focused) {
            lastFocusedPinnedVendor = nil
        }
    }

    public func removeAll() {
        for item in statusItems.values {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItems.removeAll()
        currentOrderedPinned.removeAll()
        lastFocusedPinnedVendor = nil
    }

    public func statusItem(for vendorId: VendorId) -> NSStatusItem? {
        statusItems[vendorId]
    }

    /// Stable per-vendor identity for the status item.
    ///
    /// Without one, AppKit hands each item an anonymous slot name, and on
    /// macOS 26 an item created after another was removed in the same process
    /// never reaches the screen: its window reports x = 0 (or a stale slot)
    /// and WindowServer lists no window for it. That is exactly the
    /// unpin → re-pin path, which is why a freshly pinned LLM did not appear
    /// next to the main icon. Measured with a standalone probe: anonymous
    /// re-add → invisible every time; named re-add → visible, leftmost of the
    /// app's items, in every sequence tried (including a relaunch).
    nonisolated static func autosaveName(for vendorId: VendorId) -> String {
        "ai-taskbar.pinned.\(vendorId.rawValue)"
    }

    private static func makePinnedStatusItem(for vendorId: VendorId) -> NSStatusItem {
        let name = autosaveName(for: vendorId)
        // AppKit restores a remembered position/visibility for a named item.
        // Pinning is an explicit request to show the item next to the main
        // icon, so a stale slot (or a "hidden" left by a Cmd-drag out of the
        // bar) must not override it.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
        defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        item.isVisible = true
        return item
    }

    /// Leftmost x of any status item WindowServer is actually drawing on the
    /// menu-bar screen, across every app. On macOS 26 all of them are owned by
    /// Control Center, so ownership cannot be filtered on — and does not need
    /// to be: space is shared, whoever holds it. Items the system has hidden
    /// for lack of room are simply absent from this list.
    public static func visibleStatusItemsMinX(screen: NSScreen) -> CGFloat? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let rects = list.compactMap { w -> CGRect? in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return statusItemsMinX(windowRects: rects, screenFrame: screen.frame)
    }

    /// Pure filter behind `visibleStatusItemsMinX`: status-item-sized windows
    /// in the menu-bar strip of the given screen (CoreGraphics coordinates,
    /// top-left origin — identical to AppKit's x on the menu-bar screen).
    nonisolated static func statusItemsMinX(windowRects: [CGRect], screenFrame: CGRect) -> CGFloat? {
        windowRects
            .filter { $0.minY >= 0 && $0.minY <= 45 && $0.width > 0 && $0.width < 300 }
            .filter { $0.minX > screenFrame.minX && $0.minX < screenFrame.maxX }
            .map(\.minX)
            .min()
    }

    public func canAddPinnedStatusItem(currentPinnedCount: Int? = nil) -> SpaceCheckResult {
        let count = currentPinnedCount ?? store?.pinnedVendorIds.count ?? 0
        let absoluteMax = 5
        if count >= absoluteMax {
            return .denied(reason: L10n.localizedString("pin_limit_count_message"))
        }

        // Only a manager attached to the live menu bar measures geometry.
        // Deliberately NOT keyed on finding the main button: that lookup
        // failing used to return "allowed", which is how every LLM could be
        // pinned into an overflowing bar.
        guard let store, let screen = NSScreen.screens.first else {
            return .allowedResult
        }

        let mainButton = MainStatusItemHolder.shared.mainButton ?? findMainStatusBarButton()
        var ownFrames: [CGRect] = []
        if let frame = mainButton?.window?.frame { ownFrames.append(frame) }
        ownFrames += statusItems.values.compactMap { $0.button?.window?.frame }

        guard let minX = Self.menuBarLeftmostX(
            visibleMinX: Self.visibleStatusItemsMinX(screen: screen),
            ownFrames: ownFrames
        ) else {
            return .allowedResult
        }

        let notchEdge: CGFloat?
        if #available(macOS 12.0, *), let rightArea = screen.auxiliaryTopRightArea {
            notchEdge = rightArea.minX
        } else {
            notchEdge = nil
        }
        return Self.evaluateSpaceMath(
            minX: minX,
            estimatedItemWidth: Self.worstCaseBadgeWidth(thresholds: store.thresholds),
            notchRightEdge: notchEdge,
            safeNotchMargin: 8.0,
            screenVisibleOriginX: screen.visibleFrame.origin.x,
            screenWidth: screen.frame.width
        )
    }

    /// Where the occupied part of the status area begins.
    ///
    /// WindowServer's list is the truth for what is drawn, but it omits items
    /// the system already hid; this app's own item frames still report where
    /// such an item WOULD sit (left of, or under, the notch). Taking the
    /// minimum of both means an overflow that has already happened always
    /// reads as "no room", instead of the hidden items silently not counting.
    /// Frames at x <= 0 are placeholders for items that were never placed.
    nonisolated static func menuBarLeftmostX(visibleMinX: CGFloat?, ownFrames: [CGRect]) -> CGFloat? {
        let own = ownFrames.map(\.minX).filter { $0 > 0 }
        return (own + [visibleMinX].compactMap { $0 }).min()
    }

    /// Widest a pinned badge can become: two stacked "100%" lines plus the
    /// flame, or one larger "100%" plus the flame, whichever is wider. The
    /// check runs before the item exists, and a badge grows once its data
    /// loads (loading → numbers → flame), so measuring the real view at its
    /// widest replaces the old 50 pt guess — which was narrower than a
    /// loaded badge (56 pt measured on a real bar) and let the last pin slide
    /// under the notch.
    static func worstCaseBadgeWidth(thresholds: ThresholdsConfig) -> CGFloat {
        let layouts: [Double?] = [100, nil]
        let widest = layouts.map { weekly -> CGFloat in
            NSHostingView(rootView: PinnedStatusBadgeView(
                vendorId: .anthropic, weekly: weekly, current: 100, thresholds: thresholds
            )).fittingSize.width
        }.max() ?? 0
        return pinnedItemLength(forContentWidth: widest)
    }

    /// Status item length for a badge whose content is `width` wide — the one
    /// formula both sizing a live item and the space check use.
    nonisolated static func pinnedItemLength(forContentWidth width: CGFloat) -> CGFloat {
        max(42, width + 6)
    }

    public static func evaluateSpaceMath(
        minX: CGFloat,
        estimatedItemWidth: CGFloat = 50.0,
        notchRightEdge: CGFloat?,
        safeNotchMargin: CGFloat = 8.0,
        screenVisibleOriginX: CGFloat = 0.0,
        screenWidth: CGFloat = 1800.0
    ) -> SpaceCheckResult {
        let projectedMinX = minX - estimatedItemWidth

        if let notchRightEdge = notchRightEdge {
            if projectedMinX < (notchRightEdge + safeNotchMargin) {
                return .denied(reason: L10n.localizedString("pin_limit_notch_message"))
            }
        } else {
            let leftBoundary = screenVisibleOriginX + max(350.0, screenWidth * 0.35)
            if projectedMinX < leftBoundary {
                return .denied(reason: L10n.localizedString("pin_limit_screen_message"))
            }
        }

        return .allowedResult
    }

    private func updateButton(for item: NSStatusItem, vm: VendorViewModel, store: UsageStore) {
        guard let button = item.button else { return }

        let (weekly, current) = vm.state.outcome?.snapshot.menuBarDisplayPercentages
            ?? (nil, vm.state.outcome?.snapshot.maxUtilization ?? 0)

        let badgeView = PinnedStatusBadgeView(
            vendorId: vm.vendorId,
            weekly: weekly,
            current: current,
            thresholds: store.thresholds
        )

        if let existingHosting = button.subviews.first(where: { $0 is NSHostingView<PinnedStatusBadgeView> }) as? NSHostingView<PinnedStatusBadgeView> {
            existingHosting.rootView = badgeView
            existingHosting.layoutSubtreeIfNeeded()
            let width = Self.pinnedItemLength(forContentWidth: existingHosting.fittingSize.width)
            if item.length != width {
                item.length = width
            }
        } else {
            let hosting = NSHostingView(rootView: badgeView)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            let width = Self.pinnedItemLength(forContentWidth: hosting.fittingSize.width)
            item.length = width

            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseDown])
        button.toolTip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: vm.vendorId,
            snapshot: vm.state.outcome?.snapshot,
            currentPercent: current
        )
    }

    public func refreshTooltips() {
        guard let store else { return }
        let now = Date()
        for (vid, item) in statusItems {
            guard let button = item.button, let vm = store.vendorVM(vid) else { continue }
            let current = vm.state.outcome?.snapshot.menuBarDisplayPercentages.current
                ?? vm.state.outcome?.snapshot.maxUtilization ?? 0
            button.toolTip = MenuBarTooltipBuilder.buildTooltip(
                vendorId: vid,
                snapshot: vm.state.outcome?.snapshot,
                currentPercent: current,
                now: now
            )
        }
    }

    public private(set) var lastFocusedPinnedVendor: VendorId?

    public func clearLastFocusedPinnedVendor() {
        lastFocusedPinnedVendor = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let (vid, _) = statusItems.first(where: { $0.value.button == sender }) else { return }
        let mainButton = MainStatusItemHolder.shared.mainButton ?? findMainStatusBarButton()

        let isPresented = store?.isPopoverPresented ?? false
        let isAlreadyFocused = (lastFocusedPinnedVendor == vid)

        if isPresented && isAlreadyFocused {
            // Clicking again on the currently opened/focused LLM toggles the popover closed
            lastFocusedPinnedVendor = nil
            triggerStatusBarButton(mainButton)
        } else {
            lastFocusedPinnedVendor = vid
            store?.focusVendor(vid)
            if !isPresented {
                triggerStatusBarButton(mainButton)
            }
        }
    }

    private func triggerStatusBarButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        if let target = button.target, let action = button.action {
            NSApplication.shared.sendAction(action, to: target, from: button)
        } else {
            button.performClick(nil)
        }
    }

    private func findMainStatusBarButton() -> NSStatusBarButton? {
        if let cached = MainStatusItemHolder.shared.mainButton {
            return cached
        }
        let pinnedButtons = Set(statusItems.values.compactMap(\.button))
        for window in NSApplication.shared.windows {
            if let button = findButton(in: window.contentView, excluding: pinnedButtons) {
                MainStatusItemHolder.shared.mainButton = button
                button.sendAction(on: [.leftMouseDown])
                return button
            }
        }
        return nil
    }

    private func findButton(in view: NSView?, excluding: Set<NSStatusBarButton>) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let btn = view as? NSStatusBarButton, !excluding.contains(btn) {
            return btn
        }
        for sub in view.subviews {
            if let found = findButton(in: sub, excluding: excluding) {
                return found
            }
        }
        return nil
    }
}

import AppKit
import SwiftUI
import Combine
import AiTaskbarCore

@MainActor
public final class MainStatusItemHolder {
    public static let shared = MainStatusItemHolder()
    public weak var mainButton: NSStatusBarButton?
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

    private var isFull: Bool {
        let maxVal = max(weekly ?? 0, current)
        return maxVal >= thresholds.warning || maxVal >= 100
    }

    private var flameColor: Color {
        let maxVal = max(weekly ?? 0, current)
        return (maxVal >= thresholds.critical || maxVal >= 100) ? .red : .orange
    }

    public var body: some View {
        HStack(spacing: 3.5) {
            VendorIconView(vendorId: vendorId, size: 16)
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)

            if let weekly = weekly {
                VStack(alignment: .trailing, spacing: -1) {
                    Text("\(Int(weekly.rounded()))%")
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .foregroundStyle(itemTint(for: weekly))
                    Text("\(Int(current.rounded()))%")
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .foregroundStyle(itemTint(for: current))
                }
            } else {
                Text("\(Int(current.rounded()))%")
                    .font(.system(size: 15.5, weight: .bold, design: .monospaced))
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

    private(set) var physicalItems: [NSStatusItem] = []
    private var statusItems: [VendorId: NSStatusItem] = [:]
    private var currentOrderedPinned: [VendorId] = []
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: UsageStore?

    public init() {}

    public func configure(store: UsageStore) {
        self.store = store
        cancellables.removeAll()

        store.$pinnedVendorIds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncStatusItems()
            }
            .store(in: &cancellables)

        store.$sortedVendors
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncStatusItems()
            }
            .store(in: &cancellables)

        let stateStreams = store.vendors.map { $0.$state.map { _ in () }.eraseToAnyPublisher() }
        Publishers.MergeMany(stateStreams)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.syncStatusItems()
            }
            .store(in: &cancellables)

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshTooltips()
            }
            .store(in: &cancellables)

        syncStatusItems()
    }

    public func syncStatusItems() {
        guard let store else { return }

        let ordered = store.sortedVendors.map(\.vendorId).filter { store.isPinned($0) }
        let leftovers = store.pinnedVendorIds.subtracting(ordered)
        let desiredOrderedPinned = ordered + leftovers.sorted(by: { $0.rawValue < $1.rawValue })

        let desiredCount = desiredOrderedPinned.count
        let currentCount = physicalItems.count

        if desiredCount < currentCount {
            // Unpinned: remove excess status items from the leftmost position.
            // Items are anchored to the left of the main menu bar item.
            // Removing the outer leftmost slots leaves existing slots adjacent to the main
            // button untouched and avoids physical jumping or redrawing.
            let excess = currentCount - desiredCount
            for _ in 0..<excess {
                let item = physicalItems.removeFirst()
                NSStatusBar.system.removeStatusItem(item)
            }
        } else if desiredCount > currentCount {
            // Pinned: create only the missing status items.
            // macOS WindowServer inserts new status items to the LEFT of existing items.
            // We insert each newly created item at the front (index 0).
            let needed = desiredCount - currentCount
            for _ in 0..<needed {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                physicalItems.insert(item, at: 0)
            }
        }

        // Align physical items left-to-right once window frames are established on screen.
        let frames = physicalItems.compactMap { $0.button?.window?.frame }
        if frames.count == physicalItems.count && frames.allSatisfy({ $0.origin.x > 0 }) {
            physicalItems.sort { (a, b) in
                (a.button?.window?.frame.origin.x ?? 0) < (b.button?.window?.frame.origin.x ?? 0)
            }
        }

        // Update all status item views and mapping in-place without destroying NSStatusItem slots.
        var newStatusItems: [VendorId: NSStatusItem] = [:]
        for (index, vid) in desiredOrderedPinned.enumerated() {
            guard index < physicalItems.count else { break }
            let item = physicalItems[index]
            newStatusItems[vid] = item
            if let vm = store.vendorVM(vid) {
                updateButton(for: item, vm: vm, store: store)
            }
        }

        self.statusItems = newStatusItems
        self.currentOrderedPinned = desiredOrderedPinned

        if let focused = lastFocusedPinnedVendor, !desiredOrderedPinned.contains(focused) {
            lastFocusedPinnedVendor = nil
        }
    }

    public func removeAll() {
        for item in physicalItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        physicalItems.removeAll()
        statusItems.removeAll()
        currentOrderedPinned.removeAll()
        lastFocusedPinnedVendor = nil
    }

    public func canAddPinnedStatusItem(currentPinnedCount: Int? = nil) -> SpaceCheckResult {
        let count = currentPinnedCount ?? store?.pinnedVendorIds.count ?? 0
        let absoluteMax = 5
        if count >= absoluteMax {
            return .denied(reason: L10n.localizedString("pin_limit_count_message"))
        }

        return .allowedResult
    }

    public static func evaluateSpace(
        screen: NSScreen,
        currentFrames: [CGRect],
        estimatedItemWidth: CGFloat = 72.0
    ) -> SpaceCheckResult {
        let validFrames = currentFrames.filter { $0.origin.x > 0 }
        guard let minX = validFrames.map(\.origin.x).min() else {
            return .allowedResult
        }

        let notchEdge: CGFloat?
        if #available(macOS 12.0, *), let rightArea = screen.auxiliaryTopRightArea {
            notchEdge = rightArea.origin.x
        } else {
            notchEdge = nil
        }

        return evaluateSpaceMath(
            minX: minX,
            estimatedItemWidth: estimatedItemWidth,
            notchRightEdge: notchEdge,
            safeNotchMargin: 30.0,
            screenVisibleOriginX: screen.visibleFrame.origin.x,
            screenWidth: screen.frame.width
        )
    }

    public static func evaluateSpaceMath(
        minX: CGFloat,
        estimatedItemWidth: CGFloat = 72.0,
        notchRightEdge: CGFloat?,
        safeNotchMargin: CGFloat = 30.0,
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
            let size = existingHosting.fittingSize
            let width = max(42, size.width + 6)
            if item.length != width {
                item.length = width
            }
        } else {
            let hosting = NSHostingView(rootView: badgeView)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            let size = hosting.fittingSize
            let width = max(42, size.width + 6)
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

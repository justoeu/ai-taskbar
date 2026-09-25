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

    private var statusItems: [VendorId: NSStatusItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: UsageStore?

    public init() {}

    public func configure(store: UsageStore) {
        self.store = store
        cancellables.removeAll()

        store.$pinnedVendorIds
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in
                self?.syncStatusItems(pinnedIds: pinned)
            }
            .store(in: &cancellables)

        let stateStreams = store.vendors.map { $0.$state.map { _ in () }.eraseToAnyPublisher() }
        Publishers.MergeMany(stateStreams)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, let store = self.store else { return }
                self.syncStatusItems(pinnedIds: store.pinnedVendorIds)
            }
            .store(in: &cancellables)

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshTooltips()
            }
            .store(in: &cancellables)

        syncStatusItems(pinnedIds: store.pinnedVendorIds)
    }

    private func syncStatusItems(pinnedIds: Set<VendorId>) {
        guard let store else { return }

        // Remove unpinned items
        for (vid, item) in statusItems where !pinnedIds.contains(vid) {
            NSStatusBar.system.removeStatusItem(item)
            statusItems.removeValue(forKey: vid)
        }

        // Add or update pinned items
        for vid in pinnedIds {
            guard let vm = store.vendorVM(vid) else { continue }
            let item = statusItems[vid] ?? {
                let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItems[vid] = newItem
                return newItem
            }()

            updateButton(for: item, vm: vm, store: store)
        }
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
            NSApp.sendAction(action, to: target, from: button)
        } else {
            button.performClick(nil)
        }
    }

    private func findMainStatusBarButton() -> NSStatusBarButton? {
        if let cached = MainStatusItemHolder.shared.mainButton {
            return cached
        }
        let pinnedButtons = Set(statusItems.values.compactMap(\.button))
        for window in NSApp.windows {
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

import SwiftUI
import AiTaskbarCore

public struct MenuBarLabelView: View {
    @ObservedObject var store: UsageStore
    public let mode: MenuBarMode
    @State private var rotateIndex: Int = 0

    public init(store: UsageStore, mode: MenuBarMode = .iconAndPercent) {
        self.store = store
        self.mode = mode
    }

    public var body: some View {
        HStack(spacing: 0) {
            defaultModeView
            StatusItemButtonFinder()
                .frame(width: 0, height: 0)
        }
        .task(id: mode) {
            guard mode == .rotating else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                let n = store.sortedVendors.count
                guard n > 0 else { continue }
                rotateIndex = (rotateIndex + 1) % n
            }
        }
    }

    @ViewBuilder
    private var defaultModeView: some View {
        switch mode {
        case .icon:
            iconForMaxPercent
        case .iconAndPercent:
            iconForMaxPercent
            let percent = store.maxUtilization
            if percent > 0 {
                let isFull = percent >= store.thresholds.warning || percent >= 100
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 15.0, weight: .bold, design: .monospaced))
                    .foregroundStyle(isFull ? .primary : SeverityColor.tint(forPercent: percent,
                                                                            thresholds: store.thresholds))
                if isFull {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13.0, weight: .bold))
                        .foregroundStyle((percent >= store.thresholds.critical || percent >= 100) ? Color.red : Color.orange)
                }
            }
        case .rotating:
            rotatingContent
        }
    }

    private var iconForMaxPercent: some View {
        let percent = store.maxUtilization
        return Image(systemName: symbolName(for: percent))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(SeverityColor.tint(forPercent: percent, thresholds: store.thresholds))
    }

    @ViewBuilder
    private var rotatingContent: some View {
        let rotating = store.sortedVendors.isEmpty ? store.vendors : store.sortedVendors
        if rotating.isEmpty {
            iconForMaxPercent
        } else {
            let vm = rotating[rotateIndex % rotating.count]
            let percent = vm.state.outcome?.snapshot.maxUtilization ?? 0
            let isFull = percent >= store.thresholds.warning || percent >= 100
            Image(systemName: symbolName(for: percent))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(SeverityColor.tint(forPercent: percent, thresholds: store.thresholds))
            Text("\(shortLabel(for: vm.vendorId)) \(Int(percent.rounded()))%")
                .font(.system(size: 14.0, weight: .bold, design: .monospaced))
                .foregroundStyle(isFull ? .primary : SeverityColor.tint(forPercent: percent, thresholds: store.thresholds))
            if isFull {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13.0, weight: .bold))
                    .foregroundStyle((percent >= store.thresholds.critical || percent >= 100) ? Color.red : Color.orange)
            }
        }
    }

    private func shortLabel(for v: VendorId) -> String {
        switch v {
        case .anthropic:  return "Cl"
        case .openai:     return "GPT"
        case .openrouter: return "OR"
        case .zai:        return "ZAI"
        case .kimi:       return "Km"
        case .gemini:     return "Gm"
        case .deepseek:   return "DS"
        case .xai:        return "xAI"
        }
    }

    private func symbolName(for percent: Double) -> String {
        switch percent {
        case ..<25:   return "gauge.with.dots.needle.0percent"
        case ..<50:   return "gauge.with.dots.needle.33percent"
        case ..<75:   return "gauge.with.dots.needle.50percent"
        case ..<95:   return "gauge.with.dots.needle.67percent"
        default:      return "gauge.with.dots.needle.100percent"
        }
    }
}

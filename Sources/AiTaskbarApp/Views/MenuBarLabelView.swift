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
        HStack(spacing: 4) {
            switch mode {
            case .icon:
                iconForMaxPercent
            case .iconAndPercent:
                iconForMaxPercent
                let percent = store.maxUtilization
                if percent > 0 {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(SeverityColor.tint(forPercent: percent,
                                                            thresholds: store.thresholds))
                }
            case .rotating:
                rotatingContent
            }
        }
        .task(id: mode) {
            guard mode == .rotating else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                let n = store.vendors.count
                guard n > 0 else { continue }
                rotateIndex = (rotateIndex + 1) % n
            }
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
        if store.vendors.isEmpty {
            iconForMaxPercent
        } else {
            let vm = store.vendors[rotateIndex % store.vendors.count]
            let percent = vm.state.outcome?.snapshot.maxUtilization ?? 0
            Image(systemName: symbolName(for: percent))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(SeverityColor.tint(forPercent: percent, thresholds: store.thresholds))
            Text("\(shortLabel(for: vm.vendorId)) \(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SeverityColor.tint(forPercent: percent, thresholds: store.thresholds))
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

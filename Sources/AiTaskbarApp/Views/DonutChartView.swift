import Foundation
import SwiftUI

public struct DonutSlice: Identifiable, Sendable, Equatable {
    public let id: String
    public let value: Double
    public let color: Color
    public let label: String

    public init(id: String = UUID().uuidString, value: Double, color: Color, label: String = "") {
        self.id = id
        self.value = value
        self.color = color
        self.label = label
    }
}

public struct DonutSegment: Sendable, Equatable {
    public let startAngleDegrees: Double
    public let endAngleDegrees: Double

    public init(startAngleDegrees: Double, endAngleDegrees: Double) {
        self.startAngleDegrees = startAngleDegrees
        self.endAngleDegrees = endAngleDegrees
    }
}

public enum DonutSegmentMath {
    public static func compute(values: [Double]) -> [DonutSegment] {
        let total = values.reduce(0, +)
        guard total > 0 else { return [] }

        var segments: [DonutSegment] = []
        var currentAngle: Double = 0

        for val in values {
            let portion = max(0, val) / total
            let sweep = portion * 360.0
            let start = currentAngle
            let end = currentAngle + sweep
            segments.append(DonutSegment(startAngleDegrees: start, endAngleDegrees: end))
            currentAngle = end
        }

        return segments
    }
}

public struct DonutChartView<CenterContent: View>: View {
    public let slices: [DonutSlice]
    public let lineWidth: CGFloat
    public let emptyRingColor: Color
    @Binding public var hoveredId: String?
    public let centerView: () -> CenterContent

    @State private var internalHoveredId: String?

    public init(
        slices: [DonutSlice],
        lineWidth: CGFloat = 16,
        emptyRingColor: Color = Color.secondary.opacity(0.15),
        hoveredId: Binding<String?> = .constant(nil),
        @ViewBuilder centerView: @escaping () -> CenterContent
    ) {
        self.slices = slices
        self.lineWidth = lineWidth
        self.emptyRingColor = emptyRingColor
        self._hoveredId = hoveredId
        self.centerView = centerView
    }

    private var activeHoveredId: String? {
        hoveredId ?? internalHoveredId
    }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = (size - lineWidth) / 2
            let segments = DonutSegmentMath.compute(values: slices.map(\.value))

            ZStack {
                // Background ring
                Circle()
                    .stroke(emptyRingColor, lineWidth: lineWidth)
                    .frame(width: radius * 2, height: radius * 2)

                // Segments
                if !segments.isEmpty {
                    ForEach(Array(zip(slices.indices, segments)), id: \.0) { index, segment in
                        let slice = slices[index]
                        let isHovered = activeHoveredId == slice.id

                        DonutArcShape(
                            startAngle: .degrees(segment.startAngleDegrees - 90),
                            endAngle: .degrees(segment.endAngleDegrees - 90)
                        )
                        .stroke(
                            slice.color,
                            style: StrokeStyle(lineWidth: isHovered ? lineWidth + 4 : lineWidth, lineCap: .butt)
                        )
                        .scaleEffect(isHovered ? 1.07 : 1.0)
                        .shadow(color: slice.color.opacity(isHovered ? 0.5 : 0), radius: 5, x: 0, y: 0)
                        .opacity(activeHoveredId == nil || isHovered ? 1.0 : 0.3)
                        .zIndex(isHovered ? 10 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                    }
                }

                // Center content
                centerView()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let dx = location.x - center.x
                    let dy = location.y - center.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist >= (radius - lineWidth * 1.2) && dist <= (radius + lineWidth * 1.2) {
                        var deg = atan2(dy, dx) * 180.0 / .pi + 90.0
                        if deg < 0 { deg += 360.0 }
                        deg = deg.truncatingRemainder(dividingBy: 360.0)

                        if let idx = segments.firstIndex(where: { deg >= $0.startAngleDegrees && deg < $0.endAngleDegrees }) {
                            let sid = slices[idx].id
                            if activeHoveredId != sid {
                                hoveredId = sid
                                internalHoveredId = sid
                            }
                        }
                    } else {
                        if activeHoveredId != nil {
                            hoveredId = nil
                            internalHoveredId = nil
                        }
                    }
                case .ended:
                    if activeHoveredId != nil {
                        hoveredId = nil
                        internalHoveredId = nil
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct DonutArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

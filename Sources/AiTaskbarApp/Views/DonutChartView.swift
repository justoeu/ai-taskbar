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
    public let centerView: () -> CenterContent

    public init(
        slices: [DonutSlice],
        lineWidth: CGFloat = 16,
        emptyRingColor: Color = Color.secondary.opacity(0.15),
        @ViewBuilder centerView: @escaping () -> CenterContent
    ) {
        self.slices = slices
        self.lineWidth = lineWidth
        self.emptyRingColor = emptyRingColor
        self.centerView = centerView
    }

    public var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(emptyRingColor, lineWidth: lineWidth)

            // Segments
            let segments = DonutSegmentMath.compute(values: slices.map(\.value))
            if !segments.isEmpty {
                ForEach(Array(zip(slices.indices, segments)), id: \.0) { index, segment in
                    let slice = slices[index]
                    DonutArcShape(
                        startAngle: .degrees(segment.startAngleDegrees - 90),
                        endAngle: .degrees(segment.endAngleDegrees - 90)
                    )
                    .stroke(slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }

            // Center content
            centerView()
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

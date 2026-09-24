import Testing
import Foundation
import SwiftUI
@testable import AiTaskbarApp

@Suite("DonutChart & AnalyticsTimeframePicker")
struct DonutChartTests {
    @Test("DonutSlice calculates percentage of total")
    func slice_percentage() {
        let slices = [
            DonutSlice(id: "1", value: 30, color: .orange, label: "Claude"),
            DonutSlice(id: "2", value: 70, color: .green, label: "OpenAI")
        ]
        let total = slices.reduce(0) { $0 + $1.value }
        #expect(total == 100)
        #expect(slices[0].value / total == 0.3)
        #expect(slices[1].value / total == 0.7)
    }

    @Test("DonutSegmentMath computes non-overlapping angles")
    func segment_math_angles() {
        let values = [25.0, 75.0]
        let segments = DonutSegmentMath.compute(values: values)
        #expect(segments.count == 2)
        #expect(segments[0].startAngleDegrees == 0)
        #expect(segments[0].endAngleDegrees == 90)
        #expect(segments[1].startAngleDegrees == 90)
        #expect(segments[1].endAngleDegrees == 360)
    }

    @Test("DonutSegmentMath handles all zero values cleanly")
    func segment_math_zeros() {
        let values = [0.0, 0.0]
        let segments = DonutSegmentMath.compute(values: values)
        #expect(segments.isEmpty)
    }
}

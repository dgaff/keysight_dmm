import Charts
import DMMKit
import SwiftUI

/// Trend (value against time) or histogram of the samples, kept smooth by decimating
/// off the main thread and refreshing a few times a second rather than on every reading.
struct MeasureChart: View {
    enum Mode: String, CaseIterable, Identifiable {
        case trend = "Trend", histogram = "Histogram"
        var id: String { rawValue }
    }

    /// Everything the chart draws, computed away from the main thread.
    struct Snapshot: Sendable, Equatable {
        var points: [ChartMath.Point] = []
        var bins: [ChartMath.Bin] = []
        var scale = ChartMath.AxisScale.identity
        var yRange: ClosedRange<Double> = 0...1
        var xMax: Double = 1
        var validCount = 0
        var unitText = ""
    }

    let controller: MeterController
    @State private var mode: Mode = .trend
    @State private var snapshot = Snapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            ZStack {
                switch mode {
                case .trend: trend
                case .histogram: histogram
                }
                if snapshot.validCount == 0 {
                    Text(controller.isLive ? "Waiting for readings…" : "Press Run to start reading.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
        }
        .task(id: controller.unit) { await refreshLoop() }
    }

    // MARK: Charts

    private var axisTitle: String {
        snapshot.unitText.isEmpty ? "Value" : snapshot.unitText
    }

    private var trend: some View {
        Chart {
            ForEach(snapshot.points) { p in
                LineMark(x: .value("Time", p.seconds), y: .value(axisTitle, snapshot.scale.scaled(p.value)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .foregroundStyle(.tint)
                if snapshot.points.count < 40 {
                    PointMark(x: .value("Time", p.seconds), y: .value(axisTitle, snapshot.scale.scaled(p.value)))
                        .symbolSize(18)
                        .foregroundStyle(.tint)
                }
            }
        }
        .chartYScale(domain: snapshot.yRange)
        .chartXScale(domain: 0...max(snapshot.xMax, 1e-3))
        .chartYAxisLabel(position: .top, alignment: .leading) { Text(axisTitle).foregroundStyle(.secondary) }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text("Elapsed time").foregroundStyle(.secondary) }
        .chartYAxis { valueAxis(.leading) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Self.timeLabel(v)) }
                }
            }
        }
    }

    private var histogram: some View {
        Chart(snapshot.bins) { bin in
            BarMark(
                xStart: .value("From", snapshot.scale.scaled(bin.lower)),
                xEnd: .value("To", snapshot.scale.scaled(bin.upper)),
                y: .value("Readings", bin.count)
            )
            .foregroundStyle(.tint.opacity(0.8))
        }
        .chartYAxisLabel(position: .top, alignment: .leading) { Text("Readings").foregroundStyle(.secondary) }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text(axisTitle).foregroundStyle(.secondary) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(EngineeringNotation.compact(v, unit: .none, significantDigits: 7)) }
                }
            }
        }
    }

    private func valueAxis(_ position: AxisMarkPosition) -> some AxisContent {
        AxisMarks(position: position, values: .automatic(desiredCount: 5)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let v = value.as(Double.self) { Text(EngineeringNotation.compact(v, unit: .none, significantDigits: 7)) }
            }
        }
    }

    /// Seconds below one second read as milliseconds or microseconds; larger values stay in seconds.
    static func timeLabel(_ seconds: Double) -> String {
        if seconds == 0 { return "0 s" }
        if abs(seconds) < 1 { return EngineeringNotation.compact(seconds, unit: .second, significantDigits: 4) }
        return EngineeringNotation.compact(seconds, unit: .none, significantDigits: 5) + " s"
    }

    // MARK: Data

    private func refreshLoop() async {
        var lastKey: [Int] = []
        while !Task.isCancelled {
            let samples = controller.samples
            let unit = controller.unit
            let key = [samples.count, samples.last?.index ?? -1, samples.first?.index ?? -1]
            if key != lastKey {
                lastKey = key
                let result = await Task.detached(priority: .userInitiated) {
                    Self.makeSnapshot(samples: samples, unit: unit)
                }.value
                if !Task.isCancelled { snapshot = result }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    nonisolated static func makeSnapshot(samples: [Sample], unit: MeasurementUnit) -> Snapshot {
        let points = ChartMath.decimate(samples: samples)
        var snapshot = Snapshot()
        snapshot.points = points
        snapshot.bins = ChartMath.histogram(samples: samples)
        snapshot.validCount = points.count
        guard let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return snapshot }
        let scale = ChartMath.axisScale(maxMagnitude: max(abs(low), abs(high)), unit: unit)
        snapshot.scale = scale
        snapshot.unitText = scale.prefix + unit.symbol
        let padded = ChartMath.paddedRange(low: low, high: high)
        snapshot.yRange = scale.scaled(padded.lowerBound)...scale.scaled(padded.upperBound)
        snapshot.xMax = points.last?.seconds ?? 1
        return snapshot
    }
}

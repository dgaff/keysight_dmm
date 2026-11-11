import Charts
import DMMKit
import SwiftUI

enum ChartMode: String, CaseIterable, Identifiable {
    case trend = "Trend", histogram = "Histogram"
    var id: String { rawValue }
}

/// What a chart draws, as a cheap value (arrays are copy-on-write) that can be handed
/// to a background task.
struct ChartInput: Sendable {
    enum Source: Sendable {
        case samples([Sample])
        case recording(Recording)
    }

    struct Key: Hashable, Sendable {
        var recording: UUID?
        var count: Int
        var first: Int
        var last: Int
        var unit: MeasurementUnit
    }

    var source: Source
    var unit: MeasurementUnit

    static let empty = ChartInput(source: .samples([]), unit: .none)

    init(source: Source, unit: MeasurementUnit) {
        self.source = source
        self.unit = unit
    }

    init(samples: [Sample], unit: MeasurementUnit) { self.init(source: .samples(samples), unit: unit) }
    init(recording: Recording) { self.init(source: .recording(recording), unit: recording.unit) }

    var key: Key {
        switch source {
        case .samples(let samples):
            Key(recording: nil, count: samples.count, first: samples.first?.index ?? -1, last: samples.last?.index ?? -1, unit: unit)
        case .recording(let recording):
            Key(recording: recording.id, count: recording.count, first: 0, last: 0, unit: unit)
        }
    }

    var series: ChartMath.Series {
        switch source {
        case .samples(let samples): ChartMath.Series(samples: samples)
        case .recording(let recording): ChartMath.Series(recording: recording)
        }
    }
}

/// Everything a chart draws, computed away from the main thread.
struct ChartSnapshot: Sendable, Equatable {
    var points: [ChartMath.Point] = []
    var bins: [ChartMath.Bin] = []
    var scale = ChartMath.AxisScale.identity
    var yRange: ClosedRange<Double> = 0...1
    var yTicks = ChartMath.Ticks()
    var histogramRange: ClosedRange<Double> = 0...1
    var histogramTicks = ChartMath.Ticks()
    var timeDivisor = 1.0
    var timeUnit = "s"
    var xMax = 1.0
    var xTicks = ChartMath.Ticks()
    var validCount = 0
    var unitText = ""
    /// Limits in axis units.
    var lower: Double?
    var upper: Double?

    var axisTitle: String { unitText.isEmpty ? "Value" : unitText }

    nonisolated static func make(series: ChartMath.Series, unit: MeasurementUnit, limits: Limits) -> ChartSnapshot {
        let points = ChartMath.decimate(series)
        var snapshot = ChartSnapshot()
        snapshot.points = points
        snapshot.validCount = points.count
        guard var low = points.map(\.value).min(), var high = points.map(\.value).max() else { return snapshot }
        snapshot.bins = ChartMath.histogram(values: series.values)
        if let l = limits.lower { low = min(low, l) }
        if let u = limits.upper { high = max(high, u) }
        let scale = ChartMath.axisScale(maxMagnitude: max(abs(low), abs(high)), unit: unit)
        snapshot.scale = scale
        snapshot.unitText = scale.prefix + unit.symbol
        let padded = ChartMath.paddedRange(low: low, high: high)
        snapshot.yRange = scale.scaled(padded.lowerBound)...scale.scaled(padded.upperBound)
        snapshot.yTicks = ChartMath.ticks(in: snapshot.yRange)
        snapshot.lower = limits.lower.map(scale.scaled)
        snapshot.upper = limits.upper.map(scale.scaled)

        let xMax = points.last?.seconds ?? 1
        let axis = ChartMath.timeAxis(maxSeconds: xMax)
        snapshot.timeDivisor = axis.divisor
        snapshot.timeUnit = axis.unit
        snapshot.xMax = max(xMax / axis.divisor, 1e-3)
        snapshot.xTicks = ChartMath.ticks(in: 0...snapshot.xMax)

        if let first = snapshot.bins.first, let last = snapshot.bins.last {
            snapshot.histogramRange = scale.scaled(first.lower)...scale.scaled(last.upper)
            snapshot.histogramTicks = ChartMath.ticks(in: snapshot.histogramRange)
        }
        return snapshot
    }
}

/// Trend line with optional limit rules. A plain view of a snapshot, so it can also be
/// rendered to an image.
struct TrendPlot: View {
    let snapshot: ChartSnapshot

    var body: some View {
        Chart {
            ForEach(snapshot.points) { p in
                LineMark(x: .value("Time", p.seconds / snapshot.timeDivisor), y: .value(snapshot.axisTitle, snapshot.scale.scaled(p.value)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .foregroundStyle(.tint)
                if snapshot.points.count < 40 {
                    PointMark(x: .value("Time", p.seconds / snapshot.timeDivisor), y: .value(snapshot.axisTitle, snapshot.scale.scaled(p.value)))
                        .symbolSize(18)
                        .foregroundStyle(.tint)
                }
            }
            if let upper = snapshot.upper {
                limitRule(upper, title: "Upper limit")
            }
            if let lower = snapshot.lower {
                limitRule(lower, title: "Lower limit")
            }
        }
        .chartYScale(domain: snapshot.yRange)
        .chartXScale(domain: 0...snapshot.xMax)
        .chartYAxisLabel(position: .top, alignment: .leading) { Text(snapshot.axisTitle).foregroundStyle(.secondary) }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text("Elapsed time (\(snapshot.timeUnit))").foregroundStyle(.secondary) }
        .chartYAxis {
            AxisMarks(position: .leading, values: snapshot.yTicks.values) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(ChartMath.tickLabel(v, decimals: snapshot.yTicks.decimals)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: snapshot.xTicks.values) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(ChartMath.tickLabel(v, decimals: snapshot.xTicks.decimals)) }
                }
            }
        }
    }

    private func limitRule(_ y: Double, title: String) -> some ChartContent {
        RuleMark(y: .value(title, y))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(Color.red.opacity(0.75))
            .annotation(position: .top, alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.red)
            }
    }
}

struct HistogramPlot: View {
    let snapshot: ChartSnapshot

    var body: some View {
        Chart(snapshot.bins) { bin in
            BarMark(
                xStart: .value("From", snapshot.scale.scaled(bin.lower)),
                xEnd: .value("To", snapshot.scale.scaled(bin.upper)),
                y: .value("Readings", bin.count)
            )
            .foregroundStyle(.tint.opacity(0.8))
        }
        .chartXScale(domain: snapshot.histogramRange)
        .chartYAxisLabel(position: .top, alignment: .leading) { Text("Readings").foregroundStyle(.secondary) }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text(snapshot.axisTitle).foregroundStyle(.secondary) }
        .chartXAxis {
            AxisMarks(values: snapshot.histogramTicks.values) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(ChartMath.tickLabel(v, decimals: snapshot.histogramTicks.decimals)) }
                }
            }
        }
    }
}

/// Trend or histogram of any series: live samples, a log in progress, or a saved
/// recording. Snapshots are computed off the main thread whenever the input changes.
struct SeriesChart: View {
    let input: ChartInput
    let mode: ChartMode
    var limits = Limits.none
    var emptyMessage = "No readings yet."
    @State private var snapshot = ChartSnapshot()

    private struct TaskKey: Hashable {
        var input: ChartInput.Key
        var limits: Limits
    }

    var body: some View {
        ZStack {
            switch mode {
            case .trend: TrendPlot(snapshot: snapshot)
            case .histogram: HistogramPlot(snapshot: snapshot)
            }
            if snapshot.validCount == 0 {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 150, idealHeight: 300, maxHeight: .infinity)
        .task(id: TaskKey(input: input.key, limits: limits)) {
            let input = input
            let limits = limits
            let result = await Task.detached(priority: .userInitiated) {
                ChartSnapshot.make(series: input.series, unit: input.unit, limits: limits)
            }.value
            if !Task.isCancelled { snapshot = result }
        }
    }
}

/// The Measure page's chart of live readings, refreshed a few times a second rather
/// than on every reading.
struct MeasureChart: View {
    let controller: MeterController
    @State private var mode: ChartMode = .trend
    @State private var input = ChartInput.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart", selection: $mode) {
                ForEach(ChartMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            SeriesChart(
                input: input, mode: mode,
                emptyMessage: controller.isLive ? "Waiting for readings…" : "Press Run to start reading.")
        }
        .task(id: controller.unit) { await refreshLoop() }
    }

    private func refreshLoop() async {
        var lastKey: ChartInput.Key?
        while !Task.isCancelled {
            let next = ChartInput(samples: controller.samples, unit: controller.unit)
            if next.key != lastKey {
                lastKey = next.key
                input = next
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

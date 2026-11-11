import DMMKit
import SwiftUI

/// Chart, statistics and readings table for a recording, whether it is still being
/// collected or already saved. It polls `provider` a few times a second and does the
/// heavy work (statistics, limit counts) off the main thread.
struct RecordingView: View {
    enum ViewMode: String, CaseIterable, Identifiable {
        case trend = "Trend", histogram = "Histogram", table = "Readings"
        var id: String { rawValue }
    }

    let provider: @MainActor () -> Recording?
    var limits = Limits.none
    var emptyMessage = "No readings yet."
    /// Elapsed time of the trigger instant, to mark on the trend chart.
    var triggerSeconds: Double?
    /// Called after each analysis with the recording's id and how many readings are outside the limits.
    var onAnalysis: (@MainActor (Recording.ID, Int) -> Void)?

    @State private var mode: ViewMode = .trend
    @State private var shown: Recording?
    @State private var statistics = RunningStatistics()
    @State private var outside = 0

    private struct PollKey: Hashable { var limits: Limits }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recording = shown, recording.count > 0 {
                let digits = recording.instrument.truevoltModel?.digits == 7.5 ? 7 : 6
                StatisticsView(statistics: statistics, unit: recording.unit, digits: digits)
                if !limits.isEmpty { limitLine(count: recording.count) }
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                switch mode {
                case .trend:
                    SeriesChart(input: ChartInput(recording: recording), mode: .trend, limits: limits, triggerSeconds: triggerSeconds)
                case .histogram:
                    SeriesChart(input: ChartInput(recording: recording), mode: .histogram, limits: limits)
                case .table:
                    ReadingsTable(recording: recording, limits: limits, digits: digits + 1)
                }
            } else {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: PollKey(limits: limits)) { await pollLoop() }
    }

    private func limitLine(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outside > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(outside > 0 ? Color.red : Color.green)
            Text(outside == 0 ? "All readings are within the limits." : "\(outside) of \(count) readings are outside the limits.")
                .foregroundStyle(outside > 0 ? Color.red : Color.secondary)
        }
        .font(.callout)
    }

    private func pollLoop() async {
        var lastID: UUID?
        var lastCount = -1
        while !Task.isCancelled {
            let recording = provider()
            if recording?.id != lastID || (recording?.count ?? 0) != lastCount {
                lastID = recording?.id
                lastCount = recording?.count ?? 0
                if let recording {
                    let limits = limits
                    let result = await Task.detached(priority: .userInitiated) {
                        (recording.statistics, limits.outsideCount(in: recording.values))
                    }.value
                    if Task.isCancelled { return }
                    shown = recording
                    statistics = result.0
                    outside = result.1
                    onAnalysis?(recording.id, result.1)
                } else {
                    shown = nil
                    statistics = RunningStatistics()
                    outside = 0
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Row `id` is the reading's index. Rows are made on demand so a table of 100,000
/// readings costs nothing until it is scrolled.
private struct ReadingRow: Identifiable {
    let id: Int
}

private struct ReadingRows: RandomAccessCollection {
    let count: Int
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(position: Int) -> ReadingRow { ReadingRow(id: position) }
}

struct ReadingsTable: View {
    let recording: Recording
    var limits = Limits.none
    let digits: Int

    var body: some View {
        Table(ReadingRows(count: recording.count)) {
            TableColumn("Index") { row in
                Text(String(row.id)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Time") { row in
                Text(EngineeringNotation.compact(recording.time(at: row.id), unit: .second, significantDigits: 7))
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 130)
            TableColumn("Value") { row in
                let value = recording.values[row.id]
                Text(valueText(value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(limits.isOutside(value) ? Color.red : Color.primary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Status") { row in
                let value = recording.values[row.id]
                Text(value.isNaN ? "Invalid" : (value.isInfinite ? "Overload" : (limits.isOutside(value) ? "Outside limits" : "OK")))
                    .foregroundStyle(value.isFinite && !limits.isOutside(value) ? Color.secondary : Color.red)
            }
            .width(min: 90, ideal: 120)
        }
    }

    private func valueText(_ value: Double) -> String {
        if value.isNaN { return "–" }
        if value.isInfinite { return value < 0 ? "−overload" : "overload" }
        return EngineeringNotation.string(value, unit: recording.unit, significantDigits: digits)
    }
}

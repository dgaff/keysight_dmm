import DMMKit
import SwiftUI

/// Count, minimum, maximum, mean, standard deviation and peak-to-peak of the readings so far.
struct StatisticsStrip: View {
    let controller: MeterController

    var body: some View {
        StatisticsView(
            statistics: controller.statistics, unit: controller.unit,
            digits: controller.model?.digits == 7.5 ? 7 : 6)
    }
}

/// The statistics cells for any set of readings.
struct StatisticsView: View {
    let statistics: RunningStatistics
    let unit: MeasurementUnit
    /// Significant digits for minimum, maximum and mean.
    let digits: Int

    var body: some View {
        let stats = statistics
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 10) {
            cell("Count", stats.isEmpty ? nil : String(stats.count))
            cell("Min", number(stats.isEmpty ? nil : stats.minimum, digits: digits))
            cell("Max", number(stats.isEmpty ? nil : stats.maximum, digits: digits))
            cell("Mean", number(stats.isEmpty ? nil : stats.mean, digits: digits))
            // Spread is noise-level information: four digits say all there is to say.
            cell("Std dev", number(stats.standardDeviation, digits: 4))
            cell("Peak to peak", number(stats.peakToPeak, digits: 4))
        }
        .accessibilityElement(children: .contain)
    }

    private func number(_ value: Double?, digits: Int) -> String? {
        value.map { EngineeringNotation.string($0, unit: unit, significantDigits: digits) }
    }

    private func cell(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

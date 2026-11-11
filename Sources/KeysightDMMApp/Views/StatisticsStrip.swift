import DMMKit
import SwiftUI

/// Count, minimum, maximum, mean, standard deviation and peak-to-peak of the readings so far.
struct StatisticsStrip: View {
    let controller: MeterController

    private var digits: Int { controller.model?.digits == 7.5 ? 7 : 6 }

    var body: some View {
        let stats = controller.statistics
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 10) {
            cell("Count", stats.isEmpty ? nil : String(stats.count))
            cell("Min", number(stats.isEmpty ? nil : stats.minimum))
            cell("Max", number(stats.isEmpty ? nil : stats.maximum))
            cell("Mean", number(stats.isEmpty ? nil : stats.mean))
            cell("Std dev", number(stats.standardDeviation))
            cell("Peak to peak", number(stats.peakToPeak))
        }
        .accessibilityElement(children: .contain)
    }

    private func number(_ value: Double?) -> String? {
        value.map { EngineeringNotation.string($0, unit: controller.unit, significantDigits: digits) }
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

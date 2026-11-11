import DMMKit
import SwiftUI

/// What the bar meter spans and marks. Pure, so it can be reasoned about apart from drawing.
struct BarMeterScale: Equatable {
    /// Ends of the bar, in SI base units.
    var lower: Double
    var upper: Double
    /// Where the bar grows from: zero if it is on the scale, otherwise the lower end.
    var origin: Double { lower <= 0 && upper >= 0 ? 0 : lower }
    /// True when the scale is the meter's measurement range (so the bar shows how much
    /// of the range is in use), false when it simply frames the readings seen so far.
    var isRange: Bool

    func fraction(_ value: Double) -> Double {
        guard upper > lower, value.isFinite else { return value == .infinity ? 1 : 0 }
        return min(1, max(0, (value - lower) / (upper - lower)))
    }

    /// Functions whose readings can be negative get a scale centred on zero.
    static func isBipolar(_ function: MeasurementFunction) -> Bool {
        function == .dcVoltage || function == .dcCurrent
    }

    /// - Parameters:
    ///   - range: the meter's present range for the function, if it has one and the
    ///     reading is in the range's own unit (not scaled to dB, %, …).
    ///   - statistics: readings so far, used when there is no range to go by.
    static func make(function: MeasurementFunction, range: Double?, latest: Double?, statistics: RunningStatistics) -> BarMeterScale {
        if let range, range > 0 {
            return BarMeterScale(lower: isBipolar(function) ? -range : 0, upper: range, isRange: true)
        }
        var low = statistics.isEmpty ? (latest ?? 0) : statistics.minimum
        var high = statistics.isEmpty ? (latest ?? 1) : statistics.maximum
        if let latest, latest.isFinite {
            low = min(low, latest)
            high = max(high, latest)
        }
        let padded = ChartMath.paddedRange(low: low, high: high)
        return BarMeterScale(lower: padded.lowerBound, upper: padded.upperBound, isRange: false)
    }
}

/// A horizontal bar showing where the reading sits, like the meter's own Bar Meter
/// display: against the present range when there is one, with markers for the lowest
/// and highest readings so far and for the meter's limits when limit testing is on.
struct BarMeterView: View {
    let controller: MeterController

    private var range: Double? {
        // The Range setting is in the reading's unit only for these functions, and only
        // while scaling is off.
        guard controller.states["scaling"]?.value.bool != true else { return nil }
        switch controller.function {
        case .dcVoltage, .acVoltage, .dcCurrent, .acCurrent, .resistance2W, .resistance4W, .capacitance:
            return controller.states["range"]?.value.number
        default:
            return nil
        }
    }

    private var limits: (lower: Double, upper: Double)? {
        guard controller.states["limits"]?.value.bool == true,
              let lower = controller.states["limitLower"]?.value.number,
              let upper = controller.states["limitUpper"]?.value.number else { return nil }
        return (lower, upper)
    }

    var body: some View {
        let reading = controller.latest?.reading
        let statistics = controller.statistics
        let scale = BarMeterScale.make(
            function: controller.function, range: range, latest: reading?.isValid == true ? reading?.value : nil, statistics: statistics)
        let axis = ChartMath.axisScale(maxMagnitude: max(abs(scale.lower), abs(scale.upper)), unit: controller.unit)
        let ticks = ChartMath.ticks(in: axis.scaled(scale.lower)...axis.scaled(scale.upper), desired: 8)
        let unitText = axis.prefix + controller.unit.symbol

        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let barTop: CGFloat = 26
                let barHeight: CGFloat = 34
                let x: (Double) -> CGFloat = { CGFloat(scale.fraction($0)) * width }

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: width, height: barHeight)
                        .offset(y: barTop)

                    if let reading, reading.status != .invalid {
                        let from = x(scale.origin)
                        let to = reading.isValid ? x(reading.value) : (reading.value < 0 ? 0 : width)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(reading.isValid ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.red))
                            .frame(width: max(2, abs(to - from)), height: barHeight - 8)
                            .offset(x: min(from, to), y: barTop + 4)
                    }

                    // Zero line on a scale that straddles zero.
                    if scale.lower < 0, scale.upper > 0 {
                        Rectangle().fill(Color.primary.opacity(0.45))
                            .frame(width: 1, height: barHeight + 8)
                            .offset(x: x(0), y: barTop - 4)
                    }

                    if !statistics.isEmpty {
                        let low = x(statistics.minimum), high = x(statistics.maximum)
                        if high - low < 36 {
                            // Too close to label separately without the two overlapping.
                            marker("Min · Max", at: (low + high) / 2, width: width, top: 0, color: .secondary)
                        } else {
                            marker("Min", at: low, width: width, top: 0, color: .secondary)
                            marker("Max", at: high, width: width, top: 0, color: .secondary)
                        }
                    }
                    if let limits {
                        limitLine(at: x(limits.lower), top: barTop - 6, height: barHeight + 12)
                        limitLine(at: x(limits.upper), top: barTop - 6, height: barHeight + 12)
                    }

                    ForEach(ticks.values, id: \.self) { tick in
                        let position = x(tick * axis.divisor)
                        Rectangle().fill(Color.secondary.opacity(0.6))
                            .frame(width: 1, height: 6)
                            .offset(x: position, y: barTop + barHeight + 2)
                        Text(ChartMath.tickLabel(tick, decimals: ticks.decimals))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: 80)
                            .offset(x: min(max(position - 40, -20), width - 60), y: barTop + barHeight + 10)
                    }
                }
            }
            .frame(height: 96)

            HStack(spacing: 16) {
                Text(unitText.isEmpty ? "Value" : unitText).foregroundStyle(.secondary)
                Text(scale.isRange
                     ? "Scale: the \(EngineeringNotation.compact(scale.upper, unit: controller.unit)) range"
                     : "Scale: the readings so far")
                    .foregroundStyle(.secondary)
                if reading?.status == .overload {
                    Text("Overload").foregroundStyle(.red)
                }
                if limits != nil {
                    Label("Limits", systemImage: "line.diagonal").labelStyle(.titleOnly).foregroundStyle(.red)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(minHeight: 150, idealHeight: 300, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar meter")
        .accessibilityValue(reading.map { EngineeringNotation.string($0, unit: controller.unit) } ?? "No reading")
    }

    private func marker(_ title: String, at position: CGFloat, width: CGFloat, top: CGFloat, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(color).fixedSize()
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(color)
        }
        .frame(width: 70)
        .offset(x: min(max(position - 35, -27), width - 43), y: top)
    }

    private func limitLine(at position: CGFloat, top: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(Color.red.opacity(0.8))
            .frame(width: 2, height: height)
            .offset(x: position - 1, y: top)
    }
}

import DMMKit
import SwiftUI

/// The latest reading, large, with the unit styled separately.
struct ReadoutView: View {
    let controller: MeterController

    private var digits: Int { controller.model?.digits == 7.5 ? 8 : 7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                primary(size: 84)
                primary(size: 64)
                primary(size: 48)
                primary(size: 36)
            }
            secondaryLine
            if let rate = controller.readingRate {
                let shown = EngineeringNotation.format(rate, unit: .none, significantDigits: 3).number
                Text("\(shown) readings per second")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func primary(size: CGFloat) -> some View {
        let unit = controller.unit
        let isOverload = controller.latest.map { $0.reading.status == .overload } ?? false
        let isInvalid = controller.latest.map { $0.reading.status == .invalid } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.12) {
            if let latest = controller.latest {
                let f = EngineeringNotation.format(latest.reading.value, unit: unit, significantDigits: digits)
                Text(isInvalid ? "---" : f.number)
                    .font(.system(size: size, weight: .light).monospacedDigit())
                    .foregroundStyle(isOverload ? Color.red : Color.primary)
                if !isOverload && !isInvalid {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(f.unitText)
                            .font(.system(size: size * 0.42, weight: .regular))
                            .foregroundStyle(.secondary)
                        if !controller.function.unitQualifier.isEmpty, controller.states["scaling"]?.value.bool != true {
                            Text(controller.function.unitQualifier)
                                .font(.system(size: size * 0.26, weight: .regular))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("–")
                    .font(.system(size: size, weight: .light).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if let secondary = controller.secondary {
            let unit = secondaryUnit
            let f = EngineeringNotation.format(secondary.value, unit: unit, significantDigits: digits)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(secondary.isValid ? f.number : f.number)
                    .font(.system(size: 24, weight: .light).monospacedDigit())
                    .foregroundStyle(secondary.status == .overload ? Color.red : Color.secondary)
                Text(secondary.status == .overload ? "" : f.unitText)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                Text(secondaryName)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var secondaryChoice: String? { controller.states["secondary"]?.value.choice }

    private var secondaryName: String {
        guard let choice = secondaryChoice,
              let setting = controller.settings.first(where: { $0.id == "secondary" }),
              case .quotedChoice(let choices) = setting.control else { return "" }
        return choices.first { $0.scpi == choice }?.label.lowercased() ?? ""
    }

    private var secondaryUnit: MeasurementUnit {
        switch secondaryChoice {
        case "FREQ": .hertz
        case "VOLT", "VOLT:AC": .volt
        case "CURR", "CURR:AC": .ampere
        default: controller.unit
        }
    }
}

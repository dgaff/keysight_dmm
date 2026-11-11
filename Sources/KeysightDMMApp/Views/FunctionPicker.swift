import DMMKit
import SwiftUI

/// Chooses the measurement function, grouped the way the front panel groups its keys.
struct FunctionPicker: View {
    let controller: MeterController

    private static let groups: [[MeasurementFunction]] = [
        [.dcVoltage, .acVoltage, .dcRatio],
        [.dcCurrent, .acCurrent],
        [.resistance2W, .resistance4W],
        [.frequency, .period],
        [.capacitance, .temperature, .continuity, .diode],
    ]

    var body: some View {
        HStack(spacing: 12) {
            Picker("Function", selection: selection) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group) { function in
                        Text(function.displayName)
                            .help("On the meter: \(function.frontPanelKey)")
                            .tag(function)
                    }
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(controller.isApplying || controller.link != .connected || controller.isLogging)
            .help("On the meter: \(controller.function.frontPanelKey)")

            Text("On the meter: \(controller.function.frontPanelKey)")
                .font(.callout)
                .foregroundStyle(.secondary)
            if controller.isApplying {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private var selection: Binding<MeasurementFunction> {
        Binding(
            get: { controller.function },
            set: { newValue in Task { await controller.setFunction(newValue) } }
        )
    }
}

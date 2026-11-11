import DMMKit
import SwiftUI

/// Function picker, readout, statistics and chart together, with the settings inspector alongside.
struct MeasureView: View {
    let controller: MeterController
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FunctionPicker(controller: controller)
            ReadoutView(controller: controller)
            StatisticsStrip(controller: controller)
            MeasureChart(controller: controller)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .inspector(isPresented: $showInspector) {
            SettingsInspector(controller: controller)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
        }
    }
}

import DMMKit
import SwiftUI

/// The meter's settings for the current function, rendered from their descriptors and
/// grouped the way the front panel groups them.
struct SettingsInspector: View {
    let controller: MeterController

    private var groups: [(name: String, settings: [MeterSetting])] {
        var order: [String] = []
        var members: [String: [MeterSetting]] = [:]
        for setting in controller.visibleSettings {
            if members[setting.group] == nil { order.append(setting.group) }
            members[setting.group, default: []].append(setting)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    var body: some View {
        let groups = groups
        Group {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Text(controller.function.displayName).font(.headline)
                    Text(emptyNote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.settings) { setting in
                                if let state = controller.states[setting.id] {
                                    SettingRow(controller: controller, setting: setting, state: state)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(controller.isApplying || controller.link != .connected)
            }
        }
    }

    private var emptyNote: String {
        switch controller.function {
        case .continuity, .diode: "This function has no settings. The meter uses fixed test conditions."
        default: "There are no settings to show."
        }
    }
}

import DMMKit
import SwiftUI

/// The meter's settings for the current function, rendered from their descriptors and
/// grouped the way the front panel groups them.
struct SettingsInspector: View {
    let controller: MeterController
    /// Groups the user opened or closed themselves, as `name=1` (open) or `name=0` (closed) lines.
    @AppStorage("settingGroupChoices") private var choices = ""

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
                        Section(isExpanded: expansion(of: group.name)) {
                            ForEach(group.settings) { setting in
                                if let state = controller.states[setting.id] {
                                    SettingRow(controller: controller, setting: setting, state: state)
                                }
                            }
                        } header: {
                            Text(group.name)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(controller.isApplying || controller.link != .connected || controller.isLogging)
            }
        }
    }

    /// Whether a group is open: the user's choice if they made one, otherwise open, except
    /// that Scaling and Limits stay closed while their switch is off.
    private func isExpanded(_ name: String) -> Bool {
        for line in choices.split(separator: "\n") where line.hasPrefix(name + "=") {
            return line.hasSuffix("=1")
        }
        switch name {
        case "Scaling": return controller.states["scaling"]?.value.bool == true
        case "Limits": return controller.states["limits"]?.value.bool == true
        default: return true
        }
    }

    private func expansion(of name: String) -> Binding<Bool> {
        Binding(
            get: { isExpanded(name) },
            set: { open in
                var lines = choices.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(name + "=") }
                lines.append(name + (open ? "=1" : "=0"))
                choices = lines.joined(separator: "\n")
            })
    }

    private var emptyNote: String {
        switch controller.function {
        case .continuity, .diode: "This function has no settings. The meter uses fixed test conditions."
        default: "There are no settings to show."
        }
    }
}

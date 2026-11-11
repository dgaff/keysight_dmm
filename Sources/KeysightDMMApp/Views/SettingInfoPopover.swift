import DMMKit
import SwiftUI

/// Explains a setting and shows the SCPI command behind it, with the manual's syntax when known.
struct SettingInfoPopover: View {
    let setting: MeterSetting

    var body: some View {
        let entry = SCPICatalogue.shared.lookup(setting.header)
        VStack(alignment: .leading, spacing: 10) {
            Text(setting.label).font(.headline)
            Text(setting.help).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("SCPI:").font(.caption).foregroundStyle(.secondary)
                Text(setting.header).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if let auto = setting.auto {
                    Text(auto.header).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }

            if let entry {
                Divider()
                if let syntax = entry.setSyntax {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Syntax").font(.caption).foregroundStyle(.secondary)
                        Text(syntax).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
                ForEach(Array(entry.parameters.enumerated()), id: \.offset) { _, parameter in
                    if parameter.values != nil || parameter.default != nil {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parameter.name).font(.callout.weight(.medium))
                            if let values = parameter.values {
                                Text("Values: \(values)").font(.callout).foregroundStyle(.secondary)
                            }
                            if let value = parameter.default {
                                Text("Default: \(value)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let page = entry.page {
                    Text("Manual p. \(page)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(14)
    }
}

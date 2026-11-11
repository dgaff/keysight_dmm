import Foundation

extension Multimeter {
    /// Reads the current value, auto state and limits of each setting.
    ///
    /// Queries are batched into compound lines (`:A?;:B?;…`) to keep a full panel
    /// refresh to a few round trips. If a batch comes back short (one of the headers is
    /// not supported by this meter), it is retried one query at a time and unsupported
    /// settings are simply left out of the result.
    public func readSettings(_ settings: [MeterSetting]) async throws -> [String: SettingState] {
        struct Query { let settingID: String; let field: Field; let text: String }
        enum Field { case value, auto, minimum, maximum }

        var queries: [Query] = []
        for setting in settings {
            queries.append(Query(settingID: setting.id, field: .value, text: ":\(setting.header)?"))
            if let auto = setting.auto {
                queries.append(Query(settingID: setting.id, field: .auto, text: ":\(auto.header)?"))
            }
            if setting.isNumeric {
                queries.append(Query(settingID: setting.id, field: .minimum, text: ":\(setting.header)? MIN"))
                queries.append(Query(settingID: setting.id, field: .maximum, text: ":\(setting.header)? MAX"))
            }
        }

        var answers: [Int: String] = [:]
        let batchSize = 8
        for start in stride(from: 0, to: queries.count, by: batchSize) {
            let indices = start..<min(start + batchSize, queries.count)
            let line = queries[indices].map(\.text).joined(separator: ";")
            if let response = try await session.queryIfSupported(line) {
                let fields = response.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if fields.count == indices.count {
                    for (offset, index) in indices.enumerated() { answers[index] = fields[offset] }
                    continue
                }
            }
            for index in indices {
                answers[index] = try await session.queryIfSupported(queries[index].text, timeout: .milliseconds(1500))
            }
        }

        var result: [String: SettingState] = [:]
        for setting in settings {
            var value: SettingValue?
            var state = SettingState(value: .bool(false))
            for (index, query) in queries.enumerated() where query.settingID == setting.id {
                guard let answer = answers[index] else { continue }
                switch query.field {
                case .value: value = setting.parse(response: answer)
                case .auto: state.auto = SCPIValue.parseBool(answer)
                case .minimum: state.minimum = SCPIValue.parseDouble(answer)
                case .maximum: state.maximum = SCPIValue.parseDouble(answer)
                }
            }
            guard let value else { continue }
            state.value = value
            if case .steps(let steps, _) = setting.control {
                state.allowedSteps = Multimeter.steps(steps, within: state.minimum, state.maximum, including: value.number)
            }
            result[setting.id] = state
        }
        return result
    }

    /// Filters a family-wide step list to this meter's limits. The current value is
    /// always kept, so a value the table does not list still shows up in the UI.
    static func steps(_ steps: [Double], within minimum: Double?, _ maximum: Double?, including current: Double?) -> [Double] {
        let tolerance = 1e-6
        var kept = steps.filter { step in
            if let minimum, step < minimum * (1 - tolerance) - 1e-30 { return false }
            if let maximum, step > maximum * (1 + tolerance) + 1e-30 { return false }
            return true
        }
        if let current, current.isFinite, !kept.contains(where: { abs($0 - current) <= abs(current) * tolerance }) {
            kept.append(current)
            kept.sort()
        }
        return kept
    }

    /// Changes a setting. Throws `SCPIError.instrument` if the meter rejects it.
    public func apply(_ setting: MeterSetting, _ value: SettingValue) async throws {
        guard let command = setting.command(for: value) else {
            throw SCPIError.malformedResponse(command: setting.header, response: "value \(value) does not fit this setting")
        }
        try await session.set(command)
    }

    /// Switches a setting's companion `:AUTO` control (autorange, auto null value…).
    public func setAuto(_ setting: MeterSetting, _ mode: AutoMode) async throws {
        guard let auto = setting.auto, mode != .once || auto.supportsOnce else {
            throw SCPIError.malformedResponse(command: setting.header, response: "no \(mode.rawValue) mode for this setting")
        }
        try await session.set("\(auto.header) \(mode.rawValue)")
    }
}

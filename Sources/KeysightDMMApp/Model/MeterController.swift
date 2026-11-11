import DMMKit
import Foundation
import Observation

/// UI-facing state for one connected meter. Everything the views show comes from here;
/// views never talk to `Multimeter` directly.
@MainActor
@Observable
final class MeterController {
    enum Link: Equatable {
        case connected
        /// The connection dropped (cable, power, network). The text says why.
        case lost(String)
        case closed
    }

    struct LoggedError: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    let meter: Multimeter
    let identity: InstrumentIdentity
    let endpointDescription: String
    let isSimulated: Bool

    private(set) var link: Link = .connected

    // Function and settings
    private(set) var function: MeasurementFunction = .dcVoltage
    private(set) var settings: [MeterSetting] = []
    private(set) var states: [String: SettingState] = [:]
    /// True while a function or setting change is being sent and re-read.
    private(set) var isApplying = false
    private(set) var triggerSource = "IMM"

    // Live readings
    private(set) var isLive = false
    private(set) var latest: Sample?
    private(set) var secondary: Reading?
    private(set) var samples: [Sample] = []
    private(set) var statistics = RunningStatistics()
    /// Readings per second over the last few samples.
    private(set) var readingRate: Double?

    // Diagnostics
    private(set) var errors: [LoggedError] = []
    private(set) var traffic: [SCPITrafficEvent] = []

    /// Most samples kept for the chart and app-side export; older ones are dropped.
    static let historyLimit = 200_000
    static let trafficLimit = 2_000

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var nextIndex = 0

    /// Connects, identifies the meter and adopts its current configuration.
    static func connect(transport: any SCPITransport, isSimulated: Bool = false) async throws -> MeterController {
        let (stream, continuation) = AsyncStream.makeStream(of: SCPITrafficEvent.self, bufferingPolicy: .bufferingNewest(5_000))
        let meter = try await Multimeter.connect(transport: transport, trafficHandler: { continuation.yield($0) })
        let controller = MeterController(meter: meter, endpoint: transport.endpointDescription, isSimulated: isSimulated)
        controller.trafficTask = Task { [weak controller] in
            for await event in stream {
                controller?.record(event)
            }
        }
        for error in meter.errorsAtConnect {
            controller.log("Already in the meter's error queue: \(error)")
        }
        await controller.adoptCurrentState()
        return controller
    }

    private init(meter: Multimeter, endpoint: String, isSimulated: Bool) {
        self.meter = meter
        self.identity = meter.identity
        self.endpointDescription = endpoint
        self.isSimulated = isSimulated
    }

    // MARK: Derived

    var model: TruevoltModel? { identity.truevoltModel }

    /// Unit of the primary reading, accounting for `UNIT:TEMP`.
    var unit: MeasurementUnit {
        guard function == .temperature, let choice = states["unit"]?.value.choice else { return function.unit }
        switch choice {
        case "F": return .fahrenheit
        case "K": return .kelvin
        default: return .celsius
        }
    }

    /// Settings whose `visibleWhen` condition currently holds, in profile order.
    var visibleSettings: [MeterSetting] {
        settings.filter { setting in
            guard states[setting.id] != nil else { return false }
            guard let condition = setting.visibleWhen else { return true }
            return states[condition.settingID]?.value == condition.equals
        }
    }

    /// Live readings need the meter to trigger itself.
    var canRunLive: Bool { triggerSource == "IMM" }

    // MARK: Function and settings

    func setFunction(_ newFunction: MeasurementFunction) async {
        guard newFunction != function else { return }
        await perform {
            try await self.meter.setFunction(newFunction)
        }
        await adoptCurrentState()
    }

    func apply(_ setting: MeterSetting, _ value: SettingValue) async {
        await perform { try await self.meter.apply(setting, value) }
        await refreshSettings()
    }

    func setAuto(_ setting: MeterSetting, _ mode: AutoMode) async {
        await perform { try await self.meter.setAuto(setting, mode) }
        await refreshSettings()
    }

    /// Re-reads function, trigger source and all settings from the meter.
    func adoptCurrentState() async {
        isApplying = true
        defer { isApplying = false }
        do {
            let current = try await meter.function()
            if current != function || settings.isEmpty {
                function = current
                settings = FunctionProfile.profile(for: current).settings(for: model)
                clearHistory()
            }
            triggerSource = try await meter.triggerSource()
            states = try await meter.readSettings(settings)
        } catch {
            handle(error)
        }
    }

    func refreshSettings() async {
        do {
            states = try await meter.readSettings(settings)
        } catch {
            handle(error)
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        isApplying = true
        defer { isApplying = false }
        do {
            try await operation()
        } catch {
            handle(error)
        }
    }

    // MARK: Live readings

    func startLive() {
        guard liveTask == nil, link == .connected else { return }
        isLive = true
        liveTask = Task { [weak self] in
            await self?.runLive()
        }
    }

    func stopLive() async {
        liveTask?.cancel()
        await liveTask?.value
        liveTask = nil
        isLive = false
    }

    private func runLive() async {
        var recent: [Date] = []
        while !Task.isCancelled, link == .connected {
            guard canRunLive else {
                // An external or bus trigger would make READ? block; wait for the user to change it.
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            do {
                let wantsSecondary = (states["secondary"]?.value.choice ?? "OFF") != "OFF"
                let primary: Reading
                if wantsSecondary {
                    let both = try await meter.readWithSecondary(timeout: .seconds(30))
                    primary = both.primary
                    secondary = both.secondary
                } else {
                    primary = try await meter.read(timeout: .seconds(30))
                    secondary = nil
                }
                let now = Date()
                append(primary, at: now)
                recent.append(now)
                if recent.count > 10 { recent.removeFirst() }
                if recent.count >= 2, let first = recent.first, now > first {
                    readingRate = Double(recent.count - 1) / now.timeIntervalSince(first)
                }
            } catch {
                handle(error)
                if link != .connected { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        isLive = false
    }

    private func append(_ reading: Reading, at time: Date) {
        let sample = Sample(index: nextIndex, time: time, reading: reading)
        nextIndex += 1
        latest = sample
        samples.append(sample)
        if samples.count > Self.historyLimit {
            samples.removeFirst(Self.historyLimit / 10)
        }
        statistics.add(reading)
    }

    func clearHistory() {
        samples.removeAll()
        statistics = RunningStatistics()
        latest = nil
        secondary = nil
        readingRate = nil
        nextIndex = 0
    }

    // MARK: Shutdown

    /// Stops polling, hands the front panel back and closes the socket in an orderly
    /// way. Bounded: a stuck measurement cannot hold up quitting for more than a few seconds.
    func shutdown() async {
        guard link != .closed else { return }
        let wasConnected = link == .connected
        link = .closed
        liveTask?.cancel()
        if wasConnected {
            let live = liveTask
            let meter = meter
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await live?.value  // let an in-flight READ? finish so the stream stays clean
                    await meter.disconnect(returnToLocal: true)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(4))
                }
                await group.next()
                group.cancelAll()
            }
        }
        await meter.session.transport.close()
        liveTask = nil
        isLive = false
        trafficTask?.cancel()
    }

    // MARK: Diagnostics

    func clearErrors() { errors.removeAll() }

    private func handle(_ error: any Error) {
        if let scpi = error as? SCPIError {
            switch scpi {
            case .connectionLost(let why), .connectionFailed(let why):
                if link == .connected { link = .lost(why) }
            case .notConnected:
                if link == .connected { link = .lost("The connection was closed.") }
            default:
                break
            }
        }
        if link != .closed { log(error.localizedDescription) }
    }

    private func log(_ text: String) {
        errors.append(LoggedError(date: Date(), text: text))
        if errors.count > 200 { errors.removeFirst(errors.count - 200) }
    }

    private func record(_ event: SCPITrafficEvent) {
        traffic.append(event)
        if traffic.count > Self.trafficLimit { traffic.removeFirst(Self.trafficLimit / 4) }
    }
}

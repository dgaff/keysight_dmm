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

    /// State of a meter-paced logging run, for progress display.
    struct LogState {
        var plan: AcquisitionPlan
        var info: AcquisitionInfo?
        var recording: Recording
        /// Set when the run is over.
        var end: AcquisitionEnd?
        /// Why the run failed, if it did.
        var failure: String?

        var isRunning: Bool { end == nil && failure == nil }
        /// 0…1 when the number of samples is known in advance.
        var progress: Double? {
            guard let expected = info?.expectedCount, expected > 0 else { return nil }
            return min(1, Double(recording.count) / Double(expected))
        }
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

    // Meter-paced logging
    /// The run in progress or just finished; nil before the first run.
    private(set) var log: LogState?
    /// True from Start until the run has finished and the meter's settings are restored.
    private(set) var isLogging = false

    // Recordings made in this session (meter-paced logs and app-timed captures), newest first.
    private(set) var recordings: [Recording] = []
    /// App-timed capture of live readings in progress.
    private(set) var liveCapture: Recording?

    // Diagnostics
    private(set) var errors: [LoggedError] = []
    private(set) var traffic: [SCPITrafficEvent] = []

    /// Most samples kept for the chart and app-side export; older ones are dropped.
    static let historyLimit = 200_000
    static let trafficLimit = 2_000

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var logRun: AcquisitionRun?

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
        guard newFunction != function, !isLogging else { return }
        if liveCapture != nil { stopLiveCapture() }  // a recording holds one function's unit
        await perform {
            try await self.meter.setFunction(newFunction)
        }
        await adoptCurrentState()
    }

    func apply(_ setting: MeterSetting, _ value: SettingValue) async {
        guard !isLogging else { return }
        await perform { try await self.meter.apply(setting, value) }
        await refreshSettings()
    }

    func setAuto(_ setting: MeterSetting, _ mode: AutoMode) async {
        guard !isLogging else { return }
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
        guard liveTask == nil, link == .connected, !isLogging else { return }
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
        liveCapture?.append(reading, at: time)
    }

    func clearHistory() {
        samples.removeAll()
        statistics = RunningStatistics()
        latest = nil
        secondary = nil
        readingRate = nil
        nextIndex = 0
    }

    // MARK: Meter-paced logging

    /// Snapshot of the visible settings as text, stored with each recording.
    var settingNotes: [Recording.SettingNote] {
        visibleSettings.compactMap { setting in
            guard let state = states[setting.id] else { return nil }
            return Recording.SettingNote(label: setting.label, value: Self.text(for: state, of: setting))
        }
    }

    static func text(for state: SettingState, of setting: MeterSetting) -> String {
        var text: String
        switch (state.value, setting.control) {
        case (.number(let value), _):
            text = EngineeringNotation.compact(value, unit: setting.unit ?? .none)
        case (.bool(let on), _):
            text = on ? setting.onLabel : setting.offLabel
        case (.choice(let scpi), .choice(let choices)), (.choice(let scpi), .quotedChoice(let choices)):
            text = choices.first { $0.scpi == scpi }?.label ?? scpi
        case (.choice(let scpi), _):
            text = scpi
        }
        if state.auto == true, let auto = setting.auto { text += " (\(auto.label))" }
        return text
    }

    /// Starts a run paced by the meter's sample timer. Live readings pause for the
    /// duration and resume afterwards if they were running.
    func startLog(_ plan: AcquisitionPlan, name: String) async {
        guard !isLogging, link == .connected else { return }
        isLogging = true
        let resumeLive = isLive
        await stopLive()
        if liveCapture != nil { stopLiveCapture() }

        let recording = Recording(
            name: name, instrument: identity, function: function, unit: unit,
            timing: .meterPaced(interval: 0), started: Date(), settings: settingNotes)
        log = LogState(plan: plan, recording: recording)
        let run = meter.acquire(plan)
        logRun = run
        logTask = Task { [weak self] in
            do {
                for try await event in run.events {
                    self?.handle(event)
                }
            } catch {
                self?.log?.failure = error.localizedDescription
                self?.handle(error)
            }
            self?.finishLog(resumeLive: resumeLive)
        }
    }

    /// Ends the run early. Readings taken so far are kept.
    func stopLog() {
        logRun?.stop()
    }

    private func handle(_ event: AcquisitionEvent) {
        switch event {
        case .started(let info):
            log?.info = info
            log?.recording.timing = .meterPaced(interval: info.interval)
            log?.recording.started = info.started
        case .readings(let batch):
            log?.recording.append(batch)
            if let last = batch.last {
                latest = Sample(index: nextIndex, time: Date(), reading: last)
                nextIndex += 1
            }
        case .finished(let end, _):
            log?.end = end
        }
    }

    private func finishLog(resumeLive: Bool) {
        if let finished = log, finished.recording.count > 0 {
            recordings.insert(finished.recording, at: 0)
        }
        logRun = nil
        logTask = nil
        isLogging = false
        if resumeLive, link == .connected { startLive() }
    }

    // MARK: Recordings

    /// Starts keeping live readings as an app-timed recording.
    func startLiveCapture(name: String) {
        guard liveCapture == nil, !isLogging else { return }
        liveCapture = Recording(
            name: name, instrument: identity, function: function, unit: unit,
            timing: .appTimed, started: Date(), settings: settingNotes)
        if !isLive { startLive() }
    }

    func stopLiveCapture() {
        guard let capture = liveCapture else { return }
        liveCapture = nil
        if capture.count > 0 { recordings.insert(capture, at: 0) }
    }

    func deleteRecording(_ id: Recording.ID) {
        recordings.removeAll { $0.id == id }
    }

    func renameRecording(_ id: Recording.ID, to name: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].name = name
    }

    /// Default name for the next recording, e.g. "DC Voltage log 3".
    func suggestedName(_ kind: String) -> String {
        "\(function.displayName) \(kind) \(recordings.count + 1)"
    }

    // MARK: Meter files and screen

    func listFiles(in folder: String) async -> MeterFolderListing? {
        await attempt { try await self.meter.listFiles(in: folder) }
    }

    func download(_ file: MeterFile) async -> Data? {
        await attempt { try await self.meter.download(file.path) }
    }

    func deleteFile(_ file: MeterFile) async -> Bool {
        await attempt { try await self.meter.deleteFile(file.path); return true } ?? false
    }

    func captureScreen() async -> Data? {
        await attempt { try await self.meter.captureScreen() }
    }

    /// Runs an instrument call, logging any failure and returning nil for it.
    private func attempt<T: Sendable>(_ operation: @escaping () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: Shutdown

    /// Stops polling, hands the front panel back and closes the socket in an orderly
    /// way. Bounded: a stuck measurement cannot hold up quitting for more than a few seconds.
    func shutdown() async {
        guard link != .closed else { return }
        let wasConnected = link == .connected
        stopLiveCapture()
        logRun?.stop()
        link = .closed
        liveTask?.cancel()
        if wasConnected {
            let live = liveTask
            let logging = logTask
            let meter = meter
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await logging?.value  // aborts the run, collects its readings, restores settings
                    await live?.value  // let an in-flight READ? finish so the stream stays clean
                    await meter.disconnect(returnToLocal: true)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(6))
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

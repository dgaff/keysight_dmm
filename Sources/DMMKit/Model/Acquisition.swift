import Foundation

/// A meter-paced run: the instrument's own sample timer takes the readings into its
/// reading memory, and the app drains them while the run is in progress.
///
/// This is the remote equivalent of the front panel's Data Log mode (which has no
/// documented SCPI). Timing comes from the meter's timer, not from network round
/// trips, so sample spacing is exact; draining with `R?` as the run goes means memory
/// never overflows on long runs and nothing is lost if the meter later returns to local.
public struct AcquisitionPlan: Sendable, Equatable {
    public enum Pacing: Sendable, Equatable {
        /// The shortest interval the current measurement setup allows (`SAMP:TIM MIN`).
        case fastest
        /// Seconds between the starts of consecutive samples.
        case interval(Double)
    }

    public enum Stop: Sendable, Equatable {
        case samples(Int)
        /// Seconds from the first sample to the last.
        case duration(Double)
        /// Until cancelled.
        case manual
    }

    public enum Trigger: Sendable, Equatable {
        case immediate
        /// Start on an edge at the rear-panel Ext Trig input.
        case external(rising: Bool)
        /// Start when the input crosses `level` (in the function's unit) in the given
        /// direction. 34465A/70A only; needs a fixed range.
        case level(Double, rising: Bool)
    }

    public var pacing: Pacing
    public var stop: Stop
    public var trigger: Trigger
    /// Samples to keep from before the trigger (digitizing). Counted within the
    /// total, so it must be less than the sample count. Not for immediate triggers.
    ///
    /// If the trigger arrives before this many samples have been taken, the meter keeps
    /// only what it has, and the capture is correspondingly shorter (observed on a
    /// 34470A: 500 requested with 100 pre-trigger returned 407). Use `triggerIndex` to
    /// find where the trigger falls in what actually came back.
    public var pretriggerSamples: Int

    /// Index of the first sample taken at or after the trigger in a finished capture of
    /// `total` samples, or nil when the plan has no pre-trigger samples.
    public func triggerIndex(total: Int, expected: Int?) -> Int? {
        guard pretriggerSamples > 0, let expected else { return nil }
        return max(0, total - (expected - pretriggerSamples))
    }

    public init(pacing: Pacing = .fastest, stop: Stop = .manual, trigger: Trigger = .immediate, pretriggerSamples: Int = 0) {
        self.pacing = pacing
        self.stop = stop
        self.trigger = trigger
        self.pretriggerSamples = pretriggerSamples
    }
}

public struct AcquisitionInfo: Sendable, Equatable {
    /// Actual seconds between samples, as the meter reports it after setup.
    public let interval: Double
    /// Shortest interval the meter would accept with the current measurement setup.
    public let minimumInterval: Double
    /// Number of samples the run will take; nil for a manual stop.
    public let expectedCount: Int?
    /// When `INIT` was sent. With an immediate trigger the first sample follows one
    /// trigger delay later; with an external trigger it follows the trigger edge.
    public let started: Date
    public let function: MeasurementFunction
    /// Autorange was on at the start. The manual recommends a fixed range for timed
    /// sampling: a range change delays that sample and shifts all later ones.
    public let autorangeOn: Bool
}

public enum AcquisitionEnd: Sendable, Equatable {
    /// All requested samples were taken.
    case completed
    /// Cancelled by the app.
    case stopped
    /// The meter stopped measuring on its own (for example, someone pressed a
    /// front-panel key) before the requested count was reached.
    case endedByInstrument
}

public enum AcquisitionEvent: Sendable {
    case started(AcquisitionInfo)
    /// New readings in acquisition order, decoded (overload → ±infinity).
    case readings([Reading])
    case finished(AcquisitionEnd, total: Int)
}

public enum AcquisitionError: Error, Sendable, Equatable, LocalizedError {
    case intervalTooShort(requested: Double, minimum: Double)
    case invalidPlan(String)

    public var errorDescription: String? {
        switch self {
        case .intervalTooShort(let requested, let minimum):
            "A sample interval of \(EngineeringNotation.compact(requested, unit: .second)) is too short for the current measurement settings. "
                + "The shortest possible is \(EngineeringNotation.compact(minimum, unit: .second)); reduce NPLC or turn off auto zero to go faster."
        case .invalidPlan(let why): why
        }
    }
}

/// A run in progress. Iterate `events` to receive readings; call `stop()` to end it
/// early and keep iterating: the readings already taken and `.finished(.stopped, …)`
/// still arrive before the stream ends.
public struct AcquisitionRun: Sendable {
    public let events: AsyncThrowingStream<AcquisitionEvent, any Error>
    private let task: Task<Void, Never>

    init(events: AsyncThrowingStream<AcquisitionEvent, any Error>, task: Task<Void, Never>) {
        self.events = events
        self.task = task
    }

    /// Aborts the measurement on the meter, collects what it had taken, and restores
    /// the settings the run changed. Returns immediately; the stream ends when done.
    public func stop() { task.cancel() }
}

extension Multimeter {
    /// Starts a meter-paced run.
    ///
    /// Whether the run completes, is stopped, or fails, the sampling, trigger and
    /// data-format settings it changed are put back before the stream ends. If the
    /// consumer simply abandons the stream, the run is stopped the same way.
    public nonisolated func acquire(_ plan: AcquisitionPlan) -> AcquisitionRun {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AcquisitionEvent.self)
        let task = Task {
            do {
                try await self.runAcquisition(plan, continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return AcquisitionRun(events: stream, task: task)
    }

    private func runAcquisition(
        _ plan: AcquisitionPlan,
        _ continuation: AsyncThrowingStream<AcquisitionEvent, any Error>.Continuation
    ) async throws {
        try await session.write("ABOR")

        // Remember what we are about to change so the meter is left as we found it.
        let savedHeaders = ["SAMP:COUN:PRET", "SAMP:SOUR", "SAMP:TIM", "SAMP:COUN", "TRIG:COUN", "TRIG:SLOP", "TRIG:LEV", "TRIG:SOUR", "FORM:DATA", "FORM:BORD"]
        let savedLine = try await session.query(savedHeaders.map { ":\($0)?" }.joined(separator: ";"))
        let savedValues = savedLine.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard savedValues.count == savedHeaders.count else {
            throw SCPIError.malformedResponse(command: "acquisition setup", response: savedLine)
        }

        do {
            let info = try await configure(plan)
            try await session.set("INIT")
            continuation.yield(.started(info))
            // With pre-trigger samples, leave the readings in the meter until the run is
            // over rather than removing them while it may still be holding them as
            // pre-trigger data. Such a run is complete once all post-trigger samples are
            // in, even if the trigger came before the pre-trigger buffer had filled.
            let (end, total) = await drain(
                expected: info.expectedCount, interval: info.interval,
                collectWhileRunning: plan.pretriggerSamples == 0,
                completeAt: info.expectedCount.map { $0 - plan.pretriggerSamples },
                continuation)
            await restore(savedHeaders, savedValues)
            continuation.yield(.finished(try end.get(), total: total))
        } catch {
            await restore(savedHeaders, savedValues)
            throw error
        }
    }

    private func configure(_ plan: AcquisitionPlan) async throws -> AcquisitionInfo {
        let function = try await function()

        try await session.set("SAMP:SOUR TIM")
        guard let minimum = SCPIValue.parseDouble(try await session.query("SAMP:TIM? MIN")) else {
            throw SCPIError.malformedResponse(command: "SAMP:TIM? MIN", response: "")
        }
        switch plan.pacing {
        case .fastest:
            try await session.set("SAMP:TIM MIN")
        case .interval(let seconds):
            guard seconds.isFinite, seconds > 0 else { throw AcquisitionError.invalidPlan("The sample interval must be greater than zero.") }
            // Allow for the meter's ~1 µs timer resolution when comparing.
            guard seconds >= minimum - 1e-6 else {
                throw AcquisitionError.intervalTooShort(requested: seconds, minimum: minimum)
            }
            try await session.set("SAMP:TIM \(SCPIValue.number(max(seconds, minimum)))")
        }
        guard let interval = SCPIValue.parseDouble(try await session.query("SAMP:TIM?")) else {
            throw SCPIError.malformedResponse(command: "SAMP:TIM?", response: "")
        }

        let expected: Int?
        switch plan.stop {
        case .samples(let count):
            guard count >= 1 else { throw AcquisitionError.invalidPlan("The number of samples must be at least 1.") }
            expected = count
            try await session.set("SAMP:COUN \(count)")
        case .duration(let seconds):
            guard seconds.isFinite, seconds >= 0 else { throw AcquisitionError.invalidPlan("The duration must not be negative.") }
            let count = Int((seconds / interval).rounded(.down)) + 1
            expected = count
            try await session.set("SAMP:COUN \(count)")
        case .manual:
            expected = nil
            try await session.set("SAMP:COUN MAX")
        }
        try await session.set("TRIG:COUN 1")
        switch plan.trigger {
        case .immediate:
            try await session.set("TRIG:SOUR IMM")
        case .external(let rising):
            try await session.set("TRIG:SOUR EXT")
            try await session.set("TRIG:SLOP \(rising ? "POS" : "NEG")")
        case .level(let level, let rising):
            guard level.isFinite else { throw AcquisitionError.invalidPlan("The trigger level must be a number.") }
            try await session.set("TRIG:SOUR INT")
            try await session.set("TRIG:LEV \(SCPIValue.number(level))")
            try await session.set("TRIG:SLOP \(rising ? "POS" : "NEG")")
        }
        if plan.pretriggerSamples > 0 {
            // The whole capture has to fit in reading memory, because it is only read at the end.
            let memory = (SCPIValue.parseInt(try await session.query("SAMP:COUN:PRET? MAX")) ?? 49_999) + 1
            if let expected, expected > memory {
                throw AcquisitionError.invalidPlan("A capture with pre-trigger samples is limited to the meter's reading memory, \(memory) samples.")
            }
            guard plan.trigger != .immediate else {
                throw AcquisitionError.invalidPlan("Pre-trigger samples need an external or level trigger.")
            }
            guard let expected, plan.pretriggerSamples < expected else {
                throw AcquisitionError.invalidPlan("Pre-trigger samples must be fewer than the total number of samples.")
            }
            try await session.set("SAMP:COUN:PRET \(plan.pretriggerSamples)")
        } else {
            try await session.set("SAMP:COUN:PRET 0")
        }
        // Binary transfer: 8 bytes per reading, full double precision, no text parsing.
        try await session.set("FORM:DATA REAL,64")
        try await session.set("FORM:BORD NORM")

        var autorange = false
        if let auto = FunctionProfile.profile(for: function).setting("range")?.auto,
           let answer = try await session.queryIfSupported("\(auto.header)?", timeout: .seconds(2)) {
            autorange = SCPIValue.parseBool(answer) ?? false
        }
        return AcquisitionInfo(
            interval: interval, minimumInterval: minimum, expectedCount: expected,
            started: Date(), function: function, autorangeOn: autorange)
    }

    /// The settings the manual's digitizing procedure uses for the highest sample rate
    /// on the current function: fixed range, shortest integration, auto zero off, no
    /// trigger delay. Returns the commands that were accepted, for display. Settings the
    /// current function does not have are skipped.
    @discardableResult
    public func applyFastestSamplingPreset() async throws -> [String] {
        let function = try await function()
        let prefix = function.scpi
        var applied: [String] = []
        for command in ["\(prefix):RANG:AUTO OFF", "\(prefix):ZERO:AUTO OFF", "\(prefix):NPLC MIN", "TRIG:DEL 0"] {
            do {
                try await session.set(command)
                applied.append(command)
            } catch SCPIError.instrument {
                continue  // not applicable to this function (e.g. no NPLC on AC)
            }
        }
        return applied
    }

    /// Collects readings until the run completes, the task is cancelled, or the meter
    /// stops by itself. Always ends with the meter idle and its memory emptied.
    private func drain(
        expected: Int?, interval: Double, collectWhileRunning: Bool, completeAt: Int?,
        _ continuation: AsyncThrowingStream<AcquisitionEvent, any Error>.Continuation
    ) async -> (Result<AcquisitionEnd, any Error>, Int) {
        var total = 0
        // Poll a few times a second; no faster than the data arrives, no slower than 1 s.
        let pause = Duration.seconds(min(max(interval / 2, 0.2), 1.0))

        do {
            while true {
                if Task.isCancelled { break }
                do { try await Task.sleep(for: pause) } catch { break }
                let received = collectWhileRunning ? try await collect(continuation) : 0
                total += received
                if let expected, total >= expected { return (.success(.completed), total) }
                if received == 0 {
                    // Nothing new: still measuring / waiting for a trigger, or did the meter stop?
                    let condition = SCPIValue.parseInt(try await session.query("STAT:OPER:COND?")) ?? 0
                    let busy = condition & (StatusBit.measuring | StatusBit.waitingForTrigger) != 0
                    if !busy {
                        total += try await collect(continuation)
                        if let completeAt, total >= completeAt { return (.success(.completed), total) }
                        return (.success(.endedByInstrument), total)
                    }
                }
            }
            // Cancelled: stop the meter, then pick up whatever it had already taken.
            try await session.write("ABOR")
            total += try await collect(continuation)
            return (.success(.stopped), total)
        } catch {
            return (.failure(error), total)
        }
    }

    /// Reads and removes everything in reading memory, forwards it, and returns the count.
    private func collect(_ continuation: AsyncThrowingStream<AcquisitionEvent, any Error>.Continuation) async throws -> Int {
        let block = try await session.queryBlock("R?", timeout: .seconds(20))
        guard let values = SCPIValue.parseReal64(block) else {
            throw SCPIError.malformedResponse(command: "R?", response: "\(block.count) bytes")
        }
        if !values.isEmpty {
            continuation.yield(.readings(values.map(Reading.init(raw:))))
        }
        return values.count
    }

    /// Operation Status condition register bits (`STAT:OPER:COND?`).
    enum StatusBit {
        static let measuring = 1 << 4
        static let waitingForTrigger = 1 << 5
    }

    private func restore(_ headers: [String], _ values: [String]) async {
        _ = try? await session.write("ABOR")
        for (header, value) in zip(headers, values) {
            var argument = value
            // TRIG:COUN reports infinity as 9.9E37, which is not accepted back as a number.
            if header == "TRIG:COUN", let number = SCPIValue.parseDouble(value), number >= SCPIValue.overloadMagnitude {
                argument = "INF"
            }
            _ = try? await session.write("\(header) \(argument)")
        }
        // Clear anything the restore itself may have queued so it does not surface later.
        _ = try? await session.drainErrors()
    }
}

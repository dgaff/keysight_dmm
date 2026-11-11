import DMMKit
import Foundation

// dmmprobe — bench/debug tool for DMMKit.
//
//   dmmprobe discover [seconds]            list SCPI instruments found over Bonjour
//   dmmprobe idn <host>                    connect, print identity and any queued errors
//   dmmprobe read <host> [count]           take readings with the meter's current setup
//   dmmprobe send <host> <command>...      send commands; queries print their response,
//                                          then the error queue is printed
//   options: --stay-remote   do not send SYST:LOC before disconnecting
//            --trace         print all SCPI traffic
//            --timeout <s>   per-query timeout (default 5)
//
// <host> is an IP address, a DNS/mDNS name (K-34470A-17466.local) or "sim".

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

@MainActor func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let stayRemote = takeFlag("--stay-remote")
let trace = takeFlag("--trace")
let timeout = Duration.seconds(takeOption("--timeout").flatMap(Double.init) ?? 5)

@Sendable func printTraffic(_ event: SCPITrafficEvent) {
    let mark: String
    switch event.direction {
    case .sent: mark = ">>"
    case .received: mark = "<<"
    case .note: mark = "--"
    }
    FileHandle.standardError.write(Data("\(mark) \(event.text)\n".utf8))
}

@MainActor func connect(_ host: String) async -> Multimeter {
    let transport: any SCPITransport = host == "sim" ? SimulatedMeter() : TCPTransport(host: host)
    do {
        let meter = try await Multimeter.connect(transport: transport, trafficHandler: trace ? printTraffic : nil)
        await meter.session.setDefaultTimeout(timeout)
        return meter
    } catch {
        fail("""
            \(error.localizedDescription)
            If the meter is on and reachable, check that the firewall (Little Snitch) allows \
            this binary to reach \(host) on TCP 5025.
            """)
    }
}

guard let verb = arguments.first else {
    fail("usage: dmmprobe discover | idn <host> | read <host> [count] | send <host> <command>...")
}
arguments.removeFirst()

switch verb {
case "discover":
    let seconds = arguments.first.flatMap(Double.init) ?? 3
    let browser = InstrumentBrowser()
    let listing = Task {
        var latest: [DiscoveredInstrument] = []
        for await event in browser.events() {
            switch event {
            case .instruments(let found): latest = found
            case .unavailable(let why): print("Browsing unavailable: \(why)")
            }
        }
        return latest
    }
    try? await Task.sleep(for: .seconds(seconds))
    browser.stop()
    let found = await listing.value
    if found.isEmpty { print("No instruments found.") }
    for instrument in found {
        let tag = instrument.isSupportedMultimeter ? "DMM" : "   "
        print("\(tag)  \(instrument.name)  [model \(instrument.model ?? "?"), s/n \(instrument.serialNumber ?? "?"), fw \(instrument.firmware ?? "?")]")
    }

case "idn":
    guard let host = arguments.first else { fail("usage: dmmprobe idn <host>") }
    let meter = await connect(host)
    let id = meter.identity
    print("Manufacturer: \(id.manufacturer)\nModel:        \(id.model)\nSerial:       \(id.serialNumber)\nFirmware:     \(id.firmware)")
    print("Supported:    \(id.truevoltModel != nil ? "yes" : "no (not a Truevolt DMM)")")
    for error in meter.errorsAtConnect { print("Queued error: \(error)") }
    await meter.disconnect(returnToLocal: !stayRemote)

case "read":
    guard let host = arguments.first else { fail("usage: dmmprobe read <host> [count]") }
    let count = arguments.dropFirst().first.flatMap(Int.init) ?? 1
    let meter = await connect(host)
    do {
        let function = try await meter.function()
        for _ in 0..<count {
            let reading = try await meter.read()
            let text = EngineeringNotation.string(reading, unit: function.unit, significantDigits: 8)
            print("\(function.displayName): \(text)\(function.unitQualifier)   (raw \(reading.value))")
        }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    await meter.disconnect(returnToLocal: !stayRemote)

case "send":
    guard arguments.count >= 2 else { fail("usage: dmmprobe send <host> <command>...") }
    let meter = await connect(arguments[0])
    for command in arguments.dropFirst() {
        do {
            if command.contains("?") {
                let response = try await meter.session.query(command)
                print("\(command)  ->  \(response)")
            } else {
                try await meter.session.write(command)
                print("\(command)  (sent)")
            }
        } catch {
            print("\(command)  ->  error: \(error.localizedDescription)")
        }
        if let errors = try? await meter.session.drainErrors() {
            for error in errors { print("    instrument error: \(error)") }
        }
    }
    await meter.disconnect(returnToLocal: !stayRemote)

case "settings":
    // dmmprobe settings <host> [function ...]   read every profile setting; restores the original function
    guard let host = arguments.first else { fail("usage: dmmprobe settings <host> [function ...]") }
    let wanted = arguments.dropFirst().compactMap { MeasurementFunction(rawValue: $0) }
    let functions = wanted.isEmpty ? MeasurementFunction.allCases : wanted
    let meter = await connect(host)
    do {
        let original = try await meter.function()
        for function in functions {
            let profile = FunctionProfile.profile(for: function)
            let settings = profile.settings(for: meter.identity.truevoltModel)
            if settings.isEmpty { continue }
            if function != original || functions.count > 1 { try await meter.setFunction(function) }
            let states = try await meter.readSettings(settings)
            print("== \(function.displayName) ==")
            for setting in settings {
                guard let state = states[setting.id] else {
                    print("  \(setting.label) [\(setting.header)]: NOT ANSWERED")
                    continue
                }
                var text: String
                switch state.value {
                case .number(let v): text = EngineeringNotation.compact(v, unit: setting.unit ?? .none)
                case .bool(let on): text = on ? setting.onLabel : setting.offLabel
                case .choice(let c): text = c
                }
                if let auto = state.auto { text += auto ? "  (auto on)" : "  (auto off)" }
                if let lo = state.minimum, let hi = state.maximum {
                    let unit = setting.unit ?? .none
                    text += "  limits \(EngineeringNotation.compact(lo, unit: unit)) … \(EngineeringNotation.compact(hi, unit: unit))"
                }
                if let steps = state.allowedSteps {
                    text += "  steps " + steps.map { EngineeringNotation.compact($0, unit: setting.unit ?? .none) }.joined(separator: ", ")
                }
                print("  \(setting.label) [\(setting.header)]: \(text)")
            }
        }
        if try await meter.function() != original { try await meter.setFunction(original) }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    await meter.disconnect(returnToLocal: !stayRemote)

case "log":
    // dmmprobe log <host> <interval-seconds|fast> <count>   meter-paced acquisition
    guard arguments.count >= 3, let count = Int(arguments[2]) else { fail("usage: dmmprobe log <host> <interval|fast> <count>") }
    let pacing: AcquisitionPlan.Pacing = arguments[1] == "fast" ? .fastest : .interval(Double(arguments[1]) ?? 1)
    let meter = await connect(arguments[0])
    if takeFlag("--fastest-preset") {
        let applied = (try? await meter.applyFastestSamplingPreset()) ?? []
        print("preset: \(applied.joined(separator: "; "))")
    }
    do {
        var stats = RunningStatistics()
        var unit = MeasurementUnit.none
        let began = Date()
        for try await event in meter.acquire(AcquisitionPlan(pacing: pacing, stop: .samples(count))).events {
            switch event {
            case .started(let info):
                unit = info.function.unit
                print("started: \(info.function.displayName), interval \(EngineeringNotation.compact(info.interval, unit: .second)) (minimum \(EngineeringNotation.compact(info.minimumInterval, unit: .second))), autorange \(info.autorangeOn ? "ON" : "off")")
            case .readings(let batch):
                batch.forEach { stats.add($0) }
                print(String(format: "  %6.2f s  +%d readings (total %d)", Date().timeIntervalSince(began), batch.count, stats.count + stats.excluded))
            case .finished(let end, let total):
                print("finished: \(end), \(total) readings in \(String(format: "%.2f", Date().timeIntervalSince(began))) s")
            }
        }
        if !stats.isEmpty {
            print("mean \(EngineeringNotation.string(stats.mean, unit: unit, significantDigits: 8)), min \(EngineeringNotation.string(stats.minimum, unit: unit)), max \(EngineeringNotation.string(stats.maximum, unit: unit)), sd \(EngineeringNotation.string(stats.standardDeviation ?? 0, unit: unit, significantDigits: 4))")
        }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    if let errors = try? await meter.session.drainErrors() { for e in errors { print("    instrument error: \(e)") } }
    await meter.disconnect(returnToLocal: !stayRemote)

case "files":
    // dmmprobe files <host> [folder]
    guard let host = arguments.first else { fail("usage: dmmprobe files <host> [folder]") }
    let meter = await connect(host)
    do {
        let listing = try await meter.listFiles(in: arguments.count > 1 ? arguments[1] : Multimeter.internalRoot)
        print("\(listing.folder)  used \(listing.bytesUsed) bytes, free \(listing.bytesFree) bytes")
        for file in listing.files { print("  \(file.kind)\t\(file.size)\t\(file.name)") }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    await meter.disconnect(returnToLocal: !stayRemote)

case "screenshot":
    // dmmprobe screenshot <host> <output.png>
    guard arguments.count >= 2 else { fail("usage: dmmprobe screenshot <host> <output.png>") }
    let meter = await connect(arguments[0])
    do {
        let png = try await meter.captureScreen()
        try png.write(to: URL(fileURLWithPath: arguments[1]))
        print("wrote \(png.count) bytes to \(arguments[1])")
    } catch {
        print("error: \(error.localizedDescription)")
    }
    await meter.disconnect(returnToLocal: !stayRemote)

case "block":
    // dmmprobe block <host> <query> <output-file>   save a definite-length block response
    guard arguments.count >= 3 else { fail("usage: dmmprobe block <host> <query> <output-file>") }
    let meter = await connect(arguments[0])
    do {
        let data = try await meter.session.queryBlock(arguments[1], timeout: .seconds(30))
        try data.write(to: URL(fileURLWithPath: arguments[2]))
        print("wrote \(data.count) bytes to \(arguments[2])")
    } catch {
        print("error: \(error.localizedDescription)")
    }
    if let errors = try? await meter.session.drainErrors() { for e in errors { print("    instrument error: \(e)") } }
    await meter.disconnect(returnToLocal: !stayRemote)

case "undocumented":
    // dmmprobe undocumented <help-file>   list SYST:HELP? entries missing from the catalogue
    guard let path = arguments.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("usage: dmmprobe undocumented <file saved from SYST:HELP?>")
    }
    for line in text.split(whereSeparator: \.isNewline) {
        let entry = line.split(separator: "/", maxSplits: 1)
        guard let header = entry.first, !header.isEmpty else { continue }
        let concrete = header.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        if SCPICatalogue.shared.lookup(concrete) == nil { print(line) }
    }

case "info":
    guard let host = arguments.first else { fail("usage: dmmprobe info <host>") }
    let meter = await connect(host)
    if let info = try? await meter.info() { dump(info) }
    await meter.disconnect(returnToLocal: !stayRemote)

default:
    fail("unknown command \"\(verb)\"")
}

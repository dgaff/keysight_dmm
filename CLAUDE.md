# Keysight DMM for macOS

Native macOS app (Swift, SwiftUI, light theme) to control a Keysight 34470A Truevolt
bench multimeter over the LAN. Requirements: `keysight_dmm_prd.md`.

**Start here when resuming:** read `docs/STATUS.md` (what is done, what is next) and
`docs/DECISIONS.md` (why things are the way they are). Update both as work lands.

## Layout

- `Sources/DMMKit/` — instrument layer, no UI imports
  - `Transport/` TCP socket (`TCPTransport`), receive buffer (`ByteInbox`)
  - `SCPI/` session/locking/error queue (`SCPISession`), value codec (`SCPIValue`, `Reading`)
  - `Units/` SI-prefix formatting and typed-input parsing (`EngineeringNotation`)
  - `Model/` `Multimeter`, `MeasurementFunction`, `InstrumentIdentity`
  - `Discovery/` Bonjour browser
  - `Simulator/` `SimulatedMeter`, an in-process fake 34470A for tests, previews, demo mode
  - `Resources/scpi_commands.json` — catalogue of documented SCPI commands
- `Sources/dmmprobe/` — CLI for bench checks (`dmmprobe discover|idn|read|send`)
- `Tests/DMMKitTests/` — Swift Testing; no hardware needed
- `docs/manual/` — text extracted from `KeysightDMM.pdf` (gitignored; run
  `scripts/extract_manual.sh`). Manual page numbers equal PDF page numbers. Grep these
  instead of opening the 1,193-page PDF.
- `sample_screens/` — screenshots of Keysight's Windows app (BenchVue), UI reference only

## Commands

```sh
swift build
swift test
.build/debug/dmmprobe discover
.build/debug/dmmprobe send 192.168.1.109 'FUNC?' 'VOLT:RANG?'   # add --trace to see traffic
.build/debug/dmmprobe read sim 3                                 # simulator, no network
```

## Rules for this project

- **Network failures: stop and tell the user.** Their Mac runs Little Snitch; a blocked
  connection from a newly built binary is almost certainly a firewall rule they need to
  approve, not a bug. Do not work around it.
- **Units.** Values are `Double` in SI base units everywhere. Send bare numbers with
  `SCPIValue.number`; never send unit suffixes. Prefixes appear only at display/export
  via `EngineeringNotation`. Get limits from `MIN`/`MAX`/`DEF` queries, not hardcoded tables.
- **Setting changes go through `SCPISession.set`**, which checks the error queue.
- **Do not reset or reconfigure the meter on connect.** Adopt its current state.
- **Remote → local clears reading memory** on the meter. Retrieve or save data before
  `SYST:LOC` / disconnect.
- **Never send `CAL:` commands** (other than queries) or anything that writes
  calibration or security state.
- **Bench tests:** ask the user to wire up the stimulus first. Limits agreed: ≤ 10 V,
  ≤ 100 mA from the power supply / waveform generator.
- Sub-agents: delegate well-specified pieces to cheaper models (Sonnet/Haiku); keep the
  SCPI/units layer and integration review in the main session.

## Bench

| Instrument | Address | Notes |
|---|---|---|
| 34470A DMM, s/n MY64017466 | 192.168.1.109, `K-34470A-17466.local`, TCP 5025 | fw A.03.03; 50,000-reading memory (no MEM licence); digitizer available |
| 33511B waveform generator, s/n MY62004567 | via Bonjour | stimulus for tests |
| E36234A DC power supply, s/n MY61006154 | via Bonjour | stimulus for tests |

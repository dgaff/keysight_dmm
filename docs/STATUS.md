# Status

Last updated: 2026-11-11

## Phases

| # | Phase | State |
|---|---|---|
| 0 | Foundation: package, tracking docs, SCPI command catalogue | done (catalogue: see below) |
| 1 | DMMKit core: transport, session, units, discovery, simulator, CLI | done; verified read-only against the real meter |
| 2 | App shell and live measurement (all functions, settings panels, math, charts, graceful quit) | next |
| 3 | On-meter logging (timed sampling to reading memory, download, meter files, limits, CSV) | |
| 4 | Digitizer (fast acquisition, level/external/pre-trigger, waveform view) | |
| 5 | App-side recording, session library, export, screen capture, state store/recall, utilities | |
| 6 | Experimental: undocumented SCPI hunt, SCPI console | |
| 7 | Bench validation with waveform generator and power supply | |

## Done so far

- Package builds; 22 unit tests pass (`swift test`), none need hardware.
- `dmmprobe discover` finds all three bench instruments over Bonjour.
- `dmmprobe idn|read|send` work against the 34470A at 192.168.1.109: identity,
  DC voltage readings, setting queries, error-queue reporting, timeout recovery,
  return to local on exit.

## Next up (phase 2)

1. Per-function settings model in DMMKit: for each `MeasurementFunction`, the settings
   the front panel exposes (range, NPLC/aperture, auto zero, input impedance, AC
   filter, etc.), with allowed values read from the meter (`MIN`/`MAX`) where possible.
2. Decide the live-reading strategy (repeated `READ?` vs `INIT` + `R?`/`DATA:LAST?`)
   and measure the achievable update rate.
3. App target + `.app` bundling script; connection picker using `InstrumentBrowser`,
   with a demo mode backed by `SimulatedMeter`.
4. Graceful quit path.

## Open questions / things to verify on the bench

- Does going local really clear reading memory in every case, or only after a
  data-log/digitize run? (Manual p. 176.) Determines how careful the quit path must be.
- Maximum practical polling rate over the socket.

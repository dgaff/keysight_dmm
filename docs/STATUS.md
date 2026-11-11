# Status

Last updated: 2026-11-11

## Phases

| # | Phase | State |
|---|---|---|
| 0 | Foundation: package, tracking docs, SCPI command catalogue | done |
| 1 | DMMKit core: transport, session, units, discovery, simulator, CLI | done; verified on the real meter |
| 2 | App shell and live measurement | working on the real meter. On-meter scaling (dB, dBm, %, gain/offset) and limits are in the settings inspector. Not built: bar meter |
| 3 | On-meter logging | engine bench-validated. Data Log page, Recordings page, export sheet built |
| 4 | Digitizer | engine bench-validated (25 kS/s; level trigger + pre-trigger). Digitize page built |
| 5 | Recording, export, screen capture, files, utilities | built. Recordings are saved in `~/Library/Application Support/KeysightDMM/Recordings`. Meter page: info, clock, self-test, autocal, state slots, preset, beep, display text |
| 6 | Experimental: undocumented SCPI, SCPI console | console sends commands (calibration/security blocked), with catalogue autocomplete and an Experimental list. `SYST:FPAN:KEYP` not yet explored: needs Doug at the meter |
| 7 | Bench validation | `dmmprobe bench` passes 38 checks with the waveform generator (see DECISIONS.md). Not covered: current, resistance, capacitance, temperature, external trigger |

## Not yet exercised by a person

The UI was built by sub-agents and checked from window screenshots (each page has been
opened against the real meter). Doug has used Measure, the histogram, screen capture and
live recording. Still unclicked on the real meter: most settings-inspector controls
including Scaling/Limits, starting a log or a digitize capture from the app, limits
overlay and notification, readings table with large runs, export save panel / clipboard
/ chart PNG-PDF, file download/delete/load state, the Meter page's buttons (self-test,
autocal, set clock, state slots, preset, display text), console command entry, the
connection-lost banner.

Known oddity: the meter's clock is about 5.5 hours ahead of the Mac (Meter page shows
both; "Set meter clock" fixes it).

## How things are verified

- `swift test`: 53 tests, no hardware.
- `dmmprobe` against 192.168.1.109: `idn`, `read`, `settings` (all 13 functions),
  `log fast 12`, `files`, `screenshot`, `block`, `info`,
  `bench <meter> K-33511B-04567.local` (generator wired to HI/LO).
- App: `./scripts/make_app.sh debug`, then
  `open build/KeysightDMM.app --args --connect 192.168.1.109` (or `--demo`);
  add `--page=datalog|recordings|files|screen|console` to open on a page.
  Window screenshots: `screencapture -x -l <window id>`.

## Next up

1. Doug's click-through feedback.
2. `SYST:FPAN:KEYP` experiments with Doug watching the display (could drive the real
   front-panel Data Log mode).
3. Bench tests for current, resistance, capacitance (power supply / parts wired in).
4. Bar meter view; app icon.

## Open questions / things to verify on the bench

- Does going local really clear reading memory in every case, or only after a
  data-log/digitize run? (Manual p. 176.) Determines how careful the quit path must be.
- Maximum practical polling rate over the socket.

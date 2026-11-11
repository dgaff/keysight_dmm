# Status

Last updated: 2026-11-11

## Phases

| # | Phase | State |
|---|---|---|
| 0 | Foundation: package, tracking docs, SCPI command catalogue | done |
| 1 | DMMKit core: transport, session, units, discovery, simulator, CLI | done; verified on the real meter |
| 2 | App shell and live measurement | working on the real meter (connect, live readings, settings inspector, clean quit). Not yet done: math (limits/scaling/dB on the meter), bar meter |
| 3 | On-meter logging | engine verified on the meter (`Multimeter.acquire`, `dmmprobe log`). Data Log page, Recordings page and export sheet built; a run has only been clicked through in demo mode |
| 4 | Digitizer | engine done (fast preset verified at 25 kS/s; level trigger and pre-trigger untested on hardware). No Digitize page yet |
| 5 | App-side recording, export, screen capture, files | built. Files page verified listing the real meter. Recordings are not saved to disk between launches. No state store/recall UI or utilities yet |
| 6 | Experimental: undocumented SCPI, SCPI console | hunt started: see `docs/experimental/NOTES.md`. Console is read-only so far |
| 7 | Bench validation with waveform generator and power supply | not started; needs Doug to wire the bench |

## Not yet exercised by a person

The UI was built by sub-agents and checked from window screenshots. Nobody has clicked
through it on the real meter. Specifically untested: every control in the settings
inspector, function switching from the app, histogram, info popovers, number-field
validation, Record button, starting/stopping a log from the Data Log page on the real
meter, limits overlay and notification, readings table with large runs, export save
panel / clipboard / chart PNG-PDF, file download and delete, an actual screen capture
in the Screen Capture page, the connection-lost banner.

## How things are verified

- `swift test`: 50 tests, no hardware.
- `dmmprobe` against 192.168.1.109: `idn`, `read`, `settings` (all 13 functions),
  `log fast 12`, `files`, `screenshot`, `block`.
- App: `./scripts/make_app.sh debug`, then
  `open build/KeysightDMM.app --args --connect 192.168.1.109` (or `--demo`);
  add `--page=datalog|recordings|files|screen|console` to open on a page.
  Window screenshots: `screencapture -x -l <window id>`.

## Next up

1. Review and bench-test the Data Log / Recordings / Files / Screen Capture pages.
2. Math settings (limits, scaling, dB/dBm, on-meter statistics) as shared setting groups.
3. Digitizer (phase 4): fast acquisition preset, level trigger, pre-trigger.
4. Persist recordings to disk; state store/recall UI; utilities (autocal, self-test, clock).
5. SCPI console command entry; experimental commands behind a switch.
6. Bench validation with stimulus (ask Doug to wire up first).

## Open questions / things to verify on the bench

- Does going local really clear reading memory in every case, or only after a
  data-log/digitize run? (Manual p. 176.) Determines how careful the quit path must be.
- Maximum practical polling rate over the socket.

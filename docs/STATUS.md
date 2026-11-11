# Status

Last updated: 2026-11-11

## Phases

| # | Phase | State |
|---|---|---|
| 0 | Foundation: package, tracking docs, SCPI command catalogue | done |
| 1 | DMMKit core: transport, session, units, discovery, simulator, CLI | done; verified on the real meter |
| 2 | App shell and live measurement | working on the real meter (connect, live readings, settings inspector, clean quit). Not yet done: math (limits/scaling/dB), bar meter, interactive testing of every control |
| 3 | On-meter logging | engine done and verified on the meter (`Multimeter.acquire`, `dmmprobe log`); recordings + CSV/JSON export done in DMMKit; Data Log / Recordings / Files pages in progress (sub-agent) |
| 4 | Digitizer | not started |
| 5 | App-side recording, export, screen capture, state store/recall, utilities | controller support done (live capture, files, screen capture); views in progress; recordings are not yet saved to disk between launches |
| 6 | Experimental: undocumented SCPI, SCPI console | hunt started: see `docs/experimental/NOTES.md`. Console is read-only so far |
| 7 | Bench validation with waveform generator and power supply | not started; needs Doug to wire the bench |

## How things are verified

- `swift test`: 48 tests, no hardware.
- `dmmprobe` against 192.168.1.109: `idn`, `read`, `settings` (all 13 functions),
  `log fast 12`, `files`, `screenshot`, `block`.
- App: `./scripts/make_app.sh debug`, then
  `open build/KeysightDMM.app --args --connect 192.168.1.109` (or `--demo`).
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

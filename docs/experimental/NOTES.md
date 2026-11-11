# Undocumented SCPI: findings

Source: `SYSTem:HELP?` on the 34470A (fw A.03.03), saved in
`syst_help_34470A_A.03.03.txt` (358 headers). `dmmprobe undocumented <file>` lists the
ones the manual-derived catalogue does not match: `not_in_manual.txt` (87 lines).

Regenerate: `dmmprobe block <host> 'SYST:HELP?' out.txt`, then `dmmprobe undocumented out.txt`.

## Sorting the 87

Most are alternate spellings of documented commands, not new capability:

- Optional nodes the manual omits: `CONFigure[:SCALar]…`, `MEASure[:SCALar]…`,
  `DISPlay[:WINDow]…`, `TRIGger[:SEQuence]…`, `…:RANGe[:UPPer]`, `LXI:MDNS[:STATe]`.
- Long-form aliases: `…:NPLCycles`.
- 34401A-compatibility commands: `CALCulate:FUNCtion`, `CALCulate[:STATe]`,
  `CALCulate:NULL:OFFSet`, `CALCulate:DB:REFerence`, `CALCulate:DBM:REFerence`,
  `DATA:FEED`, `INPut:IMPedance:AUTO`, `[SENSe:]ZERO:AUTO`, `[SENSe:]DETector:BANDwidth`,
  `[SENSe:]BANDwidth:DETector`, `…:AC:RESolution`, `STATus:…:{N|P}TRansition`,
  `SYSTem:COMMunicate:LAN:{DNS|WINS|HNAMe}` without numeric suffix.

Genuinely undocumented and potentially useful:

| Command | Read-only probe result | Notes |
|---|---|---|
| `SYSTem:FPANel:KEYPress` (no query) | not tried | Simulates a front-panel key. Could drive the real Data Log mode (front-panel only per the manual). Parameter names unknown. **Do not experiment without Doug watching the meter.** |
| `DISPlay[:WINDow]:UPDate` (no query) | not tried | Possibly forces a display refresh. |
| `DISPlay[:WINDow]:MESSage:CLEar` (no query) | not tried | |
| `SYSTem:AC:MODE`, `[SENSe:]VOLTage:AC:MODE`, `[SENSe:]CURRent:AC:MODE` | all `RMS`; `? MAX`/`? DEF` → -108 | A discrete setting; other legal values unknown. |
| `DATA:COPY`, `DATA:DELete` (no query), `DATA[:DATA]?`, `DATA:FEED` | `DATA:FEED?` → `"CALC"` | Reading-memory management; 34410A-style. |
| `[SENSe:]TEMPerature:TRANsducer:{RTD|FRTD}:TYPE` | `+85` (MAX also 85) | RTD alpha type; single value. |
| `CALibration:LFRequency?` | `+60` | Line frequency used at calibration. |
| `SYSTem:GLOBal:ERRor[:NEXT]?`, `…:COUNt?` | count `+0` | A second, cross-interface error queue. |
| `SYSTem:SECurity:PROGress?`, `SYSTem:SECurity:ERRor?` | `None, 0` / `No Error, 0` | Sanitize progress. Leave alone. |

Also observed: `CALC:FUNC?` → `NULL`, `CALC:STAT?` → `1` (legacy view of the math state).

## Next steps (with Doug at the bench)

1. Try `SYST:FPAN:KEYP` with plausible key names while watching the display.
2. Find the legal values of `…:AC:MODE` (try sending an invalid one and read the error).
3. Decide which of these to expose under an "Experimental" switch in the app.

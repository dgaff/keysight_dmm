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

## `SYSTem:FPANel:KEYPress` (explored 2026-11-11 with Doug at the meter)

**It presses real front-panel keys, and it works while the meter is in remote.**

- Parameter: one quoted, case-sensitive key name. Unquoted → -148, number → -128,
  unknown name → -222 "Data out of range". No query form.
- Key names found (each confirmed by the meter accepting it; effects confirmed on the
  display for those marked ✓):

  | Keys | Names |
  |---|---|
  | Functions | `DCV` ✓, `ACV` ✓, `Ohms2W` ✓, `Freq`, `Cont`, `Temp` |
  | Second functions (DCI, ACI, Ω4W, Cap, Diode, Utility, Math, Probe Hold…) | `Shift` then the key they share; no names of their own were found |
  | Menus and actions | `Acquire` ✓, `Display`, `Null` ✓, `Range` ✓, `Single` ✓ (sets a bus trigger), `RunStop`, `Help`, `Back`, `Select` |
  | Soft keys, left to right | `Softkey0` … `Softkey5` ✓ (zero-based) |
  | Navigation | `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight` |
  | Numeric entry | `0`–`9`, `.`, `+/-` |

  Not found: a `Local` key name.
- **Data Log mode can be selected but does not survive remote access.**
  `Acquire`, `Softkey0`, `Softkey1` selects Data Log (the menu shows Continuous /
  Data Log / Digitize). The very next SCPI command of any kind puts the display back
  to Continuous, as the manual warns. What stays behind is `SAMP:SOUR TIM`,
  `SAMP:TIM 1`, `SAMP:COUN 400`: front-panel Data Log mode is a wrapper over the same
  sample-timer settings the app's Data Log already uses. So there is nothing to gain
  for an attended log. The one thing the front panel can do that SCPI cannot is log
  **to a file on the meter with no computer attached**; driving that blind through key
  presses and numeric entry would be fragile.
- Lesson: an accepted name has already pressed the key. Guess one name at a time and
  look at the display; save the state first (`MMEM:STOR:STAT`) and load it afterwards.
- Useful application: with `HCOP:SDUM:DATA?` for the picture and this for the keys,
  the app could offer a working remote front panel.

## Next steps (with Doug at the bench)

2. Find the legal values of `…:AC:MODE` (try sending an invalid one and read the error).
3. Decide which of these to expose under an "Experimental" switch in the app.

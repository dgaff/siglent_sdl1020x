# SDL1020X hardware notes (measured)

Device: SDL1020X, s/n SDL13GCXA00453, firmware 1.1.1.23R4, at 192.168.1.10.
These are behaviours observed on the real instrument that differ from, or are missing in, the
Programming Guide (E02B). Everything here is enforced in code (SCPIKit/SDLKit) and in
`SDLSimulator`.

## Transport
| Behaviour | Handling |
|---|---|
| Raw SCPI on TCP 5025, replies end with `\n` | `SCPIConnection` |
| **One client at a time.** A second TCP connection is accepted, then closed at once with no data. The first session is unaffected. | Discovery reports such hosts as *busy*. The app must hold one session and never open a second (no `sdlctl` while the app is connected). |
| Queries ~5–15 ms. **Set commands take 30–250 ms to process** (levels/slew ~200 ms). | Every write is confirmed with `*OPC?` (back-pressure). |
| Unconfirmed write bursts overflow the input buffer: commands get **truncated/garbled** (seen: `Undefined header,000000`, `IME:TEST:VOLT:LOW`). | Never send unconfirmed bursts. |
| Unknown/malformed query → **no reply at all** (error -113 queued). | Per-query timeout; resync via quiet-wait + `*IDN?` sentinel. |
| Chained queries `A?;B?` → replies concatenated **without separator**. | Never chain queries. |
| Occasional multi-second stalls (rare; ~1 per few hundred queries during the first session, none in 660 later). | One automatic retry for read-only queries. |
| Does **not** advertise mDNS; VXI-11 portmapper only on **TCP** 111 (ignores UDP broadcast). | Discovery = TCP/5025 subnet sweep (+ mDNS for other instruments). |
| Error queue (`SYST:ERR?`) persists across sessions; returns `+0, No error` when empty. | Drain at session start. |

## Command spellings
- `SYST:IMON…`/`SYST:VMON…`: only the full long form `SYSTem:IMONItor:STATe[?]` works (short forms and omitting `:STATe` → no reply).
- `:BATT:DISCHA:CAP?` (from `DISCHArg`), not `DISCH`.
- `:WAVE:TIME?` replies with a unit (`8s`); `:WAVE:PAUSE?`/`DISP?` reply `ON`/`OFF`, not `1`/`0`.
- DCR values reply with 3 decimals (`0.020`).

## State rules
- **List step edits (`:LIST:LEV/WID/SLEW n,…`) and Program step edits (`:PROG:* n,…`) are silently ignored unless the instrument is in List / Program mode** (`:LIST:STAT:ON` / `:PROG:STAT:ON`). The values persist after leaving the mode.
- Setting `:FUNC <mode>` leaves Battery/List/Program/OCPT/OPPT (returns to Basic).
- `:FUNC?` keeps reporting the static mode (e.g. `CURRENT`) while in Battery; use `:BATT:FUNC?` etc. to know the active function.
- `:FUNC:TRAN?` returns the mode name (`CURRENT`), not `1` as the guide's example shows.
- Out-of-range writes raise no error. Most are **clamped** to the limit (slew 0.75 → 0.5 on the 5 A range, CV width 0.25 → 1 s, CC 9 A → 5 A on the 5 A range), but a CR level below 30 mΩ is **ignored** (old value kept). Clamp in the app and read back after every set.

## Limits (via MIN/MAX readback)
| Setting | Min | Max |
|---|---|---|
| CC slew (static and transient) | 0.001 A/µs | 0.5 (5 A range), 2.5 (30 A range) |
| Transient A/B width | CC 20 µs, **CV 1 s**, CP 40 µs, CR 1 ms | 999 s |
| CC level | 0 | range (5 / 30 A) |
| CV level | 0 | 150 V |
| CP level | 0 | 200 W |
| CR level | 0.03 Ω | 10 kΩ |
| Von | 0 | 150 V |
| List steps / count | 1 / 1 | 100 / 255 |
| Program steps | 1 | 50 |
| DCR TIME1/TIME2 | 0.020 s (factory value reads 0.000 but cannot be written back) | — |
`:BATT:LEV` and `:BATT:DCR:*` ignore `MIN`/`MAX` tokens.

## Factory defaults seen
- List steps: level 2, width 1 s, slew 0.5.
- Program steps: CC, 30 A, 150 V, LOW, short off, pause off, Ton/Toff/Tdly 1 s, min 1, max 10, level 1, LED Io 1, Rco 0.2.

## Test rig
- Keysight E36234A at 192.168.1.85, **output 2 only** → SDL input (polarity verified: SDL read 4.998 V at 5.000 V).

## Dynamic (transient) operation — measured with the E36234A as source (10 V, 0.8 A limit)
- `:FUNC:TRAN <mode>` enters dynamic operation; `:FUNC <mode>` returns to static. **Both switch the input OFF.**
- **No query distinguishes static from dynamic**: `:FUNC?` and `:FUNC:TRAN?` both return the mode name in either state. The app tracks DYN itself (assumes static after connect).
- Continuous mode works as expected (A 0.2 A / B 0.6 A, 0.5 s widths → load alternates).
- Changing `:CURR:TRAN:MODE` while running does not change behaviour until dynamic mode is re-entered.
- Static CC 0.300 A setpoint read back 0.299–0.300 A on the SDL and 0.29995 A on the PSU.

## T2 results (E36234A output 2 as source, all currents < 1 A) — 2026-11-06
| Test | Result |
|---|---|
| CC 0.5 A @ 10 V | SDL 0.4997 A / 9.958 V; PSU 0.4998 A / 9.998 V (≈ 40 mV lead drop) |
| CR 20 Ω @ 10 V | 20.09 Ω (0.496 A) |
| CP 4 W @ 10 V | 3.98 W |
| CV 8 V vs PSU 10 V / 0.6 A | 8.005 V, 0.601 A (supply in current limit) |
| Dynamic CC A 0.2 / B 0.6 A, 0.4 s | both levels observed by the app's poller |
| Short vs PSU 5 V / 0.5 A | 0.501 A, 0.011 V |
| Emergency off / mode change | current < 2 mA within 300 ms |
| **Von 8 V, latch OFF** | 10 V → 0.300 A; **7 V → 0.0002 A**; 9 V → 0.300 A (resumes) |
| Von 8 V, latch ON | keeps sinking 0.300 A at 7 V |

**Safety consequence:** Von with latch **OFF** is a working hardware under-voltage stop that does not depend on the
Mac or the network. Latch ON defeats it. The user's instrument default has latch **ON**, so battery profiles
must set latch OFF explicitly and verify by read-back before switching the input on.

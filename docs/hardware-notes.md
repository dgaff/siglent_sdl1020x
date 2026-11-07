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

## Battery function (measured with the E36234A emulating a cell)
- `:INP ON` while in Battery starts the test; **`DISCHA:CAP`/`DISCHA:TIM` reset at every start** and stay readable after the test ends (until the next start).
- Counters are **integers: 1 mAh and 1 s resolution** (0.83 mAh still reads 0). LoadLab integrates V·I itself (trapezoidal, sub-mAh) and keeps the instrument count as a cross-check / fallback.
- V_Stop ends the test (input OFF) within ~1.5 s of the voltage falling below it; C_Stop ended a 0.5 A run at 15 s (2.08 mAh actual, counter 2).
- The instrument does not report *why* it stopped. LoadLab infers it: voltage cut-off if the last loaded reading was within 10 % of V_Stop or the relaxed voltage is at/below V_Stop; otherwise capacity/time limits by counter; else "input switched off".
- **V_Stop is only checked while the load is sinking** (2026-11-07, Anker USB power bank, CC 1 A, V_Stop 4.0 V, backup Von 3.9 V latch OFF). The bank shut its output off, 4.98 V → 0.001 V between two samples. Von held the load at 0 A, and the Battery test **paused instead of ending**: `DISCHA:TIM` froze at 10473 s, the input stayed ON, and the run recorded for another 32 min until stopped by hand. LoadLab now ends a battery run itself (input OFF, reason "cut-off voltage", a `safety` event) after 2 readings in a row at/below V_Stop with no current; profiles get the same check.
- Phase 3 T2 run (CC 0.5 A, V_Stop 3.5 V, supply ramped 4.0 → 3.3 V): completed by voltage cut-off at 3.516 V loaded; app 1.25 mAh vs counter 1 mAh; backup Von 3.4 V / latch OFF armed during the run and the user's Von/latch restored afterwards.

## Profiles (Phase 5) — measured with the E36234A as source, 2026-11-06
- **Von failsafe with LoadLab fully disconnected** (TCP closed, CC 0.5 A, Von 3.5 V latch OFF), currents read by the PSU:
  4.0 V → 0.4998 A; **3.3 V → 0.04–0.08 mA**; 3.8 V → 0.4998 A (resumes); 3.3 V → 0.08 mA.
  The instrument enforces it on its own. Because latch is OFF, the load **resumes** if the voltage recovers above Von
  (a resting cell can bounce back), so it is a backstop: LoadLab still switches the input off at the cut-off.
- **Full profile on the supply** (hold 0.3 A, rest, DCR 0.1 → 0.6 A, two pulses 0.5/0.1 A, hold 0.5 A while the supply
  ramped 4.0 → 3.3 V): ended by the app's cut-off at 3.5 V; settings snapshot diff empty afterwards (Basic mode, levels,
  ranges, Von, latch all restored). DCR read **71 mΩ** (supply output impedance + leads; no remote sense).
- **Dropped connection mid-profile** (0.4 A hold, socket closed by the app): reconnected and switched the input off
  **2.5 s** later; run recorded as "connection lost".
- **Timing lesson:** a status poll (`:INP?` then 6 more queries, ~100 ms) can straddle the runner's `:INP ON`.
  Judging that stale "off" against the new "should be on" ended every hardware run at once. Status readings are now
  ignored if the runner changed the input while they were taken (`inputGeneration`). The simulator is too fast to
  hit this reliably; the hardware test `profileRunOnSupply` failed every time without the fix.

## List / Program / OCPT / OPPT runs (Phase 6) — measured with the E36234A as source, 2026-11-06
- **Remote triggers need `TRIG:SOUR BUS`.** With the MANUAL source (this unit's setting) `*TRG` is silently ignored.
  LoadLab switches the source to BUS for a List/Program run and restores it afterwards; the toolbar Trigger button is
  disabled unless the source is BUS.
- **List:** input ON *arms* the list (`:TEST:STEP?` = 0, no current). The trigger starts it; steps follow their widths
  (1 s widths observed at 0.1/0.3/0.5 A) and the list repeats `COUNt` times. At the end the instrument **switches the
  input off** and `:TEST:STEP?` reads steps + 1 (4 for 3 steps). Re-arm by switching the input on again.
- **Program:** same arming and trigger. Each step loads for Ton, then Toff with no load; after the last step's Ton the
  input switches off. **`:PROG:TEST? n` returns the measured value** (a plain number, kept until the next run), not
  pass/fail: voltage for CC/CP/CR steps, **current for CV steps** (CV 4 V against a supply limited to 0.5 A → 0.514 A).
  LoadLab judges it against the step's min/max.
- **`:TEST:STOP?` always reads 0** (during, after and between runs): it can't be used to detect the end. LoadLab uses the
  input switching off.
- **OCPT/OPPT start at input ON** (no trigger). The level rises by Step every Step delay; when the source voltage falls
  below the trip voltage the instrument switches the input off. **The ramp stops before applying the End level**
  (Start 0.1, Step 0.1, End 0.3: only 0.1 and 0.2 A were applied). **The trip point is not readable over SCPI**
  (`:OCP:RES?`, `:OCP:TEST?`, `:OCP:RESULT?`, `:OCP:CURR?`, `:OCP:TRIP?` are all undefined), so LoadLab samples V/I
  every ~50 ms and reports the highest load held above the trip voltage: OCPT tripped at ≈ 0.50 A and OPPT at ≈ 2.5 W
  against the supply's 0.5 A limit at 5 V.
- **Clamped pairs:** Program and OCPT/OPPT **min ≤ max** and OCPT/OPPT **start ≤ end** are enforced by clamping the value
  being written (e.g. MIN 1 while MAX is 0.55 stores 0.55). Writes must be ordered (raise max before min); snapshot
  restore now repeats until a re-read matches.
- **Ext:** `EXT:MODE EXTI/EXTV` selects external control (`EXT:MODE?` ≠ INT is how LoadLab detects the Ext function);
  `MEAS:EXT?` reads the control voltage (0.0000 V with nothing connected). Sinking under external control was not tested
  (no control voltage on this bench).

## Transport: error-queue replies end with two newlines
- `SYST:ERR?` replies for real errors are terminated `\n\n` (e.g. `-113,Undefined header,:OCP:RES?\n\n`); `+0, No error`
  has one `\n`. The extra blank line used to be taken as the next reply, misaligning every later query on that
  connection (seen as "Unexpected reply to :INP?: -113,…" right after connecting). The reader now skips blank lines;
  the simulator mimics the quirk.

## Transport: reconnect could orphan the new socket (fixed 2026-11-06)
- Seen once in a full hardware run: after a deliberate mid-profile disconnect, LoadLab never reconnected and the input
  stayed on at 0.4 A (the Von backstop was armed; the test's supply was then switched off by teardown).
- Cause: the old socket's final receive/close callback is delivered asynchronously. When it landed after the reconnect
  had opened a new socket, it marked the *new* one closed without cancelling it. That orphaned socket kept the SDL's
  single client slot, so every further attempt was accepted-then-closed ("busy"), indefinitely.
- Fix: close and receive events only act on the socket they came from; `connect()` cancels any leftover socket first.
  Simulator test `repeatedDropsLeaveExactlyOneClient` fails 3/3 on the old code and passes on the fix.
- Hardware tests' teardown now falls back to a fresh connection to switch the input off if the session can't.

## OCPT against a current-limited supply: no clean collapse sometimes
- In 1 of ~8 runs the E36234A in its 0.5 A limit and the SDL's CC loop settled into an oscillation (4.1–4.4 V,
  0.40–0.48 A) instead of the voltage collapsing, so the 3 V trip threshold was never crossed and the instrument neither
  tripped nor ended the ramp. LoadLab now stops an OCPT/OPPT run 3 s past the ramp's longest possible duration and says
  why. The hardware tests trip at 4.5 V (first clear sag); a real DUT's protection normally cuts its output fully.

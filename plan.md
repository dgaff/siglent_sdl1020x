# SDL1020X Mac App — Implementation Plan

Working name: **LoadLab** (rename freely).
Decisions locked in: native **SwiftUI** app · **Mac-native redesign** (sidebar + persistent readouts + live chart) · all four battery enhancements · **personal ad-hoc-signed build** (no App Sandbox).

---

## 1. What I verified on your device (read-only, 2026-11-06)

| Finding | Consequence for the design |
|---|---|
| `*IDN?` → `Siglent Technologies,SDL1020X,SDL13GCXA00453,1.1.1.23R4` on **raw TCP 5025**, `\n`-terminated replies | No VISA/NI driver needed. Pure `Network.framework` socket. |
| ~**20 ms per query** round-trip; ~50 queries/s sustained | V+I polling at ~20 Hz max; full V/I/P/R ≈ 10 Hz. Compute P and R from V·I app-side when sampling fast. |
| **Malformed/unknown command → no reply at all** (e.g. `:BATT:DISCH:CAP?`; correct short form is `:BATT:DISCHA:CAP?`) | Every query needs a timeout; on timeout drain socket + `SYST:ERR?` to resync. Command table must be unit-tested against the exact short forms. |
| Chained queries (`MEAS:CURR?;:MEAS:VOLT?`) return values **concatenated with no separator** (`0.0000000.000000`) | Never chain queries — one query per round-trip. Chaining *set* commands is OK. |
| SDL **does not advertise mDNS** (your Keysight E36234A does) | Discovery = VXI-11 portmapper broadcast + TCP/5025 subnet sweep + manual IP. |
| VXI-11 portmapper answers on **TCP 111 only** (core channel on 9009). UDP broadcast works on the LAN (4 other hosts answer), but the **SDL ignores UDP/111**, even unicast | **Primary SDL discovery = parallel TCP/5025 sweep of the local /24 + `*IDN?` filter.** UDP VXI-11 broadcast and mDNS (`_scpi-raw._tcp`) stay as supplemental sources for other instruments. |
| `:WAVE:TIME?` returns `8s` (unit suffix) while others return bare floats | Response parser must tolerate unit suffixes. |
| `MEAS:WAVE? VOLT` returns the device's 200-point display buffer | Usable for high-res "burst" captures (e.g. transient response during pulse tests) beyond the 20 Hz polling limit. |
| Battery counters `:BATT:DISCHA:CAP?` (mAh) and `:BATT:DISCHA:TIM?` (s) are readable | Device-side capacity is the authoritative cross-check against app-integrated mAh. |

---

## 2. Architecture

```
┌──────────────────────── SwiftUI Views ────────────────────────┐
│ Sidebar · ReadoutBar · Function panes · LiveChart · RunLibrary │
└───────────────▲────────────────────────────────▲──────────────┘
                │ @Observable view models        │
┌───────────────┴──────────┐      ┌──────────────┴──────────────┐
│ DeviceSession (@MainActor)│      │ RunStore (system SQLite)    │
│  state mirror, poll loop  │─────▶│ runs, samples, events, meta │
│  Recorder, ProfileEngine  │      └─────────────────────────────┘
└───────────────▲──────────┘
                │ typed async API
┌───────────────┴──────────┐      ┌─────────────────────────────┐
│ SDL1000X (command layer)  │      │ Discovery                    │
│  enums, ranges, parsing   │      │  VXI-11 UDP bcast + TCP sweep│
└───────────────▲──────────┘      │  + manual IP + recents       │
                │                  └─────────────────────────────┘
┌───────────────┴──────────┐
│ SCPITransport (actor)     │  NWConnection, single in-flight query,
│  timeouts, resync, reconnect, command log                         │
└──────────────────────────┘
```

**Packages / targets** (a single Swift Package, built and tested from the command line; the app is wrapped into a `.app` bundle by a script; macOS 15+):

- `SCPIKit`: transport actor and VXI-11/sweep discovery. No UI dependencies.
- `SDLKit`: typed SDL1000X command set. It models functions (Basic CC/CV/CP/CR/LED plus Dynamic Cont/Puls/Togl, Battery, List, Program, OCPT/OPPT, Ext) and configuration (ranges, slew, protections, Sense, Von/latch, averaging, trigger source).
- `BatteryKit`: recorder, integrators (mAh, Wh), analysis (capacity, mid-point V, IR vs SoC, dV/dQ), and the profile engine.
- `LoadLabApp`: SwiftUI app, Swift Charts, persistence (system SQLite3; **no third-party dependencies**).
- `sdlctl`: a command-line tool built on the same packages. I use it to test against the real device without the UI, and you get a scripting tool.
- `SDLSimulator`: a fake SDL TCP server reproducing the quirks above (silent on bad commands, concatenated chained replies, battery counters, input-voltage model). It drives all unit and UI tests offline.

**Concurrency rules**
- One `SCPITransport` per device, with exactly one query in flight. The poller, UI edits, and profile engine all go through a priority queue: user commands and safety commands jump ahead of polling.
- The poll loop is adaptive. When idle it reads V/I/P/R at 4 Hz. When recording it reads V+I at the configured rate (1–20 Hz). It reads mode-specific status at 1 Hz: battery counters, `:TEST:STEP?`/`:TEST:STOP?` for List/Program, and input/short state.
- The UI mirrors device state optimistically, then confirms with a read-back query after each set.
- On a dropped connection, the app reconnects with backoff. Any running device-side test keeps going on the instrument. The recorder marks a gap and reattaches to the same run using the device serial and the battery counters.

---

## 3. UX

**Main window (NavigationSplitView)**
- **Sidebar**:
  - Devices: discovered and recent, with a status dot and a "+ Add by IP" option.
  - Functions: Basic, Battery, List, Program, OCPT/OPPT, Ext.
  - Library: Runs, Profiles.
- **Readout bar** (always visible): V, A, W, Ω in large monospaced digits. It has the INPUT ON/OFF switch (red when on), Short, Trigger, and a status strip. The strip mirrors EasySDL's bottom bar: Trig source, Average, Sense, SoF, Von latch, Ext switch, I/P protect, and any fault.
- **Function pane**: native forms. Each pane maps to one EasySDL screen:
  - *Basic*: mode CC/CV/CP/CR/LED, a DYN toggle with Cont/Puls/Togl and A/B levels and widths, I/V/R ranges, setpoint, and slew.
  - *Battery*: mode CC/CP/CR, ranges, level, V/C/T stop toggles, accumulated capacity, and a DCR sub-tab. Recording controls are built in (see §4).
  - *List*: mode, ranges, count (0 = ∞), and an editable step table (level, width, slew). It supports CSV import/export and a preview graph.
  - *Program*: an editable step table (mode, ranges, pause, short, Ton/Toff/Tdly, min/max, level, LED Io/Rco). It supports import/export and a results column with pass/fail from `:PROG:TEST?`.
  - *OCPT/OPPT*: parameters, a run button, and a result showing the trip point plus a ramp chart.
  - *Ext*: CC/CV with ranges, plus V_ext and I_set readouts.
- **Live chart** (bottom split, collapsible): replaces EasySDL's Trend popup. Series toggles for V/I/P/R/mAh, a time window selector, pause/zoom, and LTTB downsampling so 24-hour runs stay smooth.
- **Settings sheet** (Utility menu): Sense, Von and latch, I/P protection levels and delays, averaging (2^6–2^14), trigger source, IMON/VMON, SoF, SLMT time test, and read-only LAN info.
- **Menu bar commands**: ⌘⇧I toggles input; ⌘. is an **emergency input OFF** that works from any screen.
- **Raw SCPI console** (debug window): send a command and see the reply, plus a scrolling command log. Useful for both of us.

---

## 4. Battery characterization (the enhancements)

**4a. Logging and live charts**
- A Recorder attaches to any function, but is first-class in Battery and in profiles.
- Each sample stores: monotonic t, wall-clock, V, I, P, R, app-integrated mAh and Wh (trapezoidal), device mAh/s (1 Hz), step/phase index, and flags.
- Charts: V vs t, V vs mAh (the classic discharge curve), I/P vs t, and a capacity gauge with ETA.
- Export to CSV (one row per sample, plus a JSON sidecar with run metadata and settings snapshot).

**4b. Run library and overlay**
- Run metadata: cell/pack name, chemistry, nominal capacity and voltage, series count, temperature, fixture/wire notes, tags, and free notes. The device serial and the full config snapshot are captured automatically.
- The Runs browser can search and filter, multi-select runs to overlay, and normalize the x-axis (mAh, % of nominal, Wh, time). It also has an aging view, which shows the same cell over time.

**4c. App-scripted profiles**
- A `ProfileEngine` runs a declarative step list (saved as JSON in the Profiles library). Step types:
  - CC/CP/CR hold
  - Rest (input off)
  - Pulse train
  - DCR measurement (two-current method)
  - Loop-until (V < x, mAh > y, t > z)
  - Mark
- Built-in templates:
  - **Constant-rate capacity test** with optional C-rate presets from nominal capacity.
  - **Multi-rate test**: 0.2C/0.5C/1C/2C on successive charged cells, overlaid.
  - **Pulse discharge** (e.g. GSM/radio-style bursts, or motor start).
  - **HPPC-style IR vs SoC**: discharge Δ mAh, rest, pulse, measure ΔV/ΔI, repeat to cutoff. This produces an internal-resistance-vs-SoC curve.
  - **Constant-power runtime test**, for devices with DC-DC converters.
- **Safety model** (important, because the app is now in the control loop):
  1. App-side watchdog checks V, I, T, and mAh limits every sample.
  2. **A device-side failsafe is set before input-on.** The Von (break-over) voltage is set to the cutoff with latch OFF, so the load stops sinking below cutoff even if the Mac sleeps or the network drops. I/P protection is also set.
  3. App power assertion: no sleep while a run is active.
  4. Any transport error during a profile sends input OFF on reconnect and logs an abort event.
- Behaviour of item 2 must be verified on hardware (see Phase 5 testing).

**4d. Derived analysis** (computed on completion; viewable for any past run)
- Delivered capacity (mAh, Wh); average, mid-point, and plateau voltage; time to cutoff.
- Internal resistance per DCR/pulse event, and IR vs SoC.
- dV/dQ and dQ/dV curves (smoothed) for chemistry/aging insight.
- Capacity vs nominal (% SoH).
- Export: chart PNG/PDF and a one-page PDF run report.

---

## 5. Phased delivery and testing needs

Legend: 🤖 = I can do it unassisted (no DUT, input stays OFF) · 🔌 = needs you to wire/power something · 👀 = needs your eyes/judgement.

**Testing levels**
- **T0, simulator:** all unit, integration, and UI tests against `SDLSimulator`. 🤖 always.
- **T1, live device, input OFF:** queries, plus setting parameters and reading them back. This changes front-panel settings, so I'll snapshot all settings first and restore them afterwards. I won't use `*RST`. 🤖, but I need your OK to change settings on the device.
- **T2, live device with a bench supply as the DUT:** your **Keysight E36234A** is on the network and I can script it over SCPI too. Wire **one E36234A channel → SDL input**, with current limit ≤ 3 A and voltage ≤ 30 V. I can then run real load tests unattended. I can also *emulate a discharging battery* by ramping the PSU voltage down, which tests cutoffs, Von failsafe, profiles, and recorder accuracy (PSU readback vs SDL readback). 🔌 one-time wiring; then 🤖.
- **T3, real battery:** a real cell or pack, a real discharge, and a final validation of capacity numbers. 🔌👀

| Phase | Scope | Testing | You needed? |
|---|---|---|---|
| **0. Scaffold** | Xcode project, packages, GRDB, `sdlctl`, `SDLSimulator`, CI script (`xcodebuild test`) | T0 | 🤖 |
| **1. Transport + discovery** | SCPI actor, timeouts/resync, reconnect; VXI-11 broadcast + TCP sweep + manual IP; command log/console | T0 + T1 queries | 🤖, plus **one action from you**: run `sdlctl discover` once (or let me run it unsandboxed) to confirm UDP broadcast works on your LAN |
| **2. Shell + Basic** | Sidebar, readout bar, Input/Short/Trigger, Basic pane incl. DYN & LED, settings sheet, live chart | T0, T1 set/readback; T2 for CC/CV/CP/CR sinking, short, slew, dynamic | 🔌 wire PSU once · 👀 UX review |
| **3. Battery + recorder** | Battery pane, DCR tab, recorder, CSV export, reattach-after-disconnect | T0; T2 with PSU voltage ramp to trigger V_Stop/C_Stop/T_Stop; pull network cable mid-run test | 🔌 (cable pull is optional; I can simulate by killing the socket) |
| **4. Run library + analysis** | GRDB store, Runs browser, overlay, derived metrics, PDF report | T0 with synthetic + recorded T2 runs | 👀 review charts/report |
| **5. Profile engine** | Step DSL, templates, safety watchdog, Von failsafe, sleep assertion | T0; **T2 safety verification**: confirm Von+latch-OFF really stops sinking below cutoff with the app disconnected | 🤖 after wiring; 👀 sign-off on safety behaviour |
| **6. List / Program / OCPT-OPPT / Ext** | Remaining panes, table editors, import/export (CSV), run + result polling | T0, T1, T2 (List/Program run on PSU; OCPT needs PSU with its own OCP set — fine) | Ext mode needs a 0–10 V control voltage on the rear terminal 🔌 (optional; can skip) |
| **7. Polish + real battery** | Icons, menus, keyboard shortcuts, error UX, app bundle in /Applications | **T3** full capacity test on a real cell | 🔌👀 |

**Status (2026-11-06):**
- **Approved:** changing SDL settings with input OFF.
- **Approved:** scripting the E36234A at 192.168.1.85, using **Output 2 only**.
- **Verified:** the Output 2 → SDL wiring works, with correct polarity (SDL read 4.998 V at a 5 V setpoint).
- **Resolved:** the UDP discovery question (see §1).
- **Deferred:** the T3 real-battery test to a later session (see §8).

**What I need from you, in summary** (original list)
1. **Now:** OK for me to change settings on the SDL (input stays OFF) during T1 testing. I'll restore your settings afterwards.
2. **Phase 1:** one unsandboxed discovery run (UDP broadcast).
3. **Phase 2:** wire an E36234A channel to the SDL input (no DUT otherwise), and confirm I may script the E36234A. Note its IP (it's on the network as `MY61006154`).
4. **Phases 2, 4, 5:** UX reviews, plus sign-off on the safety failsafe.
5. **Phase 7:** a real battery for the end-to-end capacity test.
6. Optional: a control voltage for Ext mode, a wiring change for remote Sense, and a trigger source for external trigger.

---

## 6. Open technical questions (resolved during build, on hardware)
- Does setting `:INP ON` while in Battery function start the test? Does the device reset `DISCHA:CAP` on each start, or accumulate with C-Add?
- Can the SDL hold **two TCP clients at once** (e.g. the app plus `sdlctl` or EasySDL)? This affects whether the console can share the session.
- List/Program start semantics via `TRIG:SOUR BUS` + `*TRG`. How do `:TEST:STEP?`/`:TEST:STOP?` behave across loops?
- DCR mode has parameter commands but no documented "enter DCR" command. This may need a front-panel step or an undocumented command (to be probed).
- OCPT/OPPT result read-back: no documented result query. It may need inferring from the measurement stream (the app captures the trip point itself).
- Response formats with unit suffixes (`8s`) on other queries.

---

## 7. Repository layout (planned)
```
siglent_sdl1020x/
  prd.md  plan.md  docs/ (PDFs, screenshots)
  LoadLab.xcodeproj
  Packages/
    SCPIKit/  SDLKit/  BatteryKit/  SDLSimulator/
  Apps/
    LoadLab/        (SwiftUI app)
    sdlctl/         (CLI)
  Tests/            (unit + simulator integration)
  scripts/          (build, test, hw-smoke-test)
```
I'll also `git init` the project at Phase 0, so every phase lands as reviewable commits.

---

## 8. Deferred: real-battery validation (T3), notes for a later session
- **Preconditions:** Phases 3–5 are done, and the Von failsafe is verified on the PSU rig.
- **Suggested first cell:** a single 18650 Li-ion (nominal 3.6 V, cutoff 2.8–3.0 V). Use the 36 V and 5 A ranges at a 0.5C–1C discharge. The cell needs a **4-wire Sense** connection for accurate voltage under load, so enable SYST:SENS ON and wire the rear sense terminals.
- **Things to check:**
  - App-integrated mAh against the device's `:BATT:DISCHA:CAP?`. The two should agree within about 1%.
  - Cutoff behaviour at V_Stop.
  - Reattach after the Mac sleeps or the app quits mid-run.
  - The HPPC profile's IR values against the device's DCR result.
- Confirm with the user before any input-ON on a real cell. They must be present for the first run.

---

## 9. Progress log

### 2026-11-06: Phases 0 and 1 done
- **Built:** SwiftPM package with these targets:
  - `SCPIKit`: transport and discovery.
  - `SDLKit`: typed command set (every documented command), limits, and settings snapshot/restore.
  - `SDLSimulator`: a fake device with the real device's quirks and a physics model.
  - `sdlctl`: the command-line tool.
  - A `LoadLab` placeholder.
- **Tests:** 34 run against the simulator. 7 hardware T1 tests (`SDL_HW_HOST=192.168.1.10 swift test --filter HardwareT1`) are all green, and the device is verified back at its original settings afterwards.
- **Hardware findings** are recorded in `docs/hardware-notes.md`. Several change the design:
  - **Single TCP client.** The app must own the one session. `sdlctl` and EasySDL can't run at the same time, and discovery shows the device as *busy*.
  - **Set commands take 30–250 ms to process.** Every write is confirmed with `*OPC?`. Unconfirmed bursts overflowed the SDL input buffer and garbled commands.
  - **Robust resync after timeouts:** wait for quiet, then use an `*IDN?` sentinel.
  - **List/Program step edits only work while in that mode**, and are otherwise silently ignored. The UI will switch the device into a function when its pane is edited.
  - **Out-of-range values are clamped or ignored silently.** The UI clamps to `SDLLimits` and reads back.
  - **Discovery:** the TCP sweep finds the SDL plus the E36234A in about 6 s. The SDL ignores UDP VXI-11.
- **Deviations from the plan:** no Xcode project and no GRDB. Everything stays dependency-free and builds from the command line.
- **Original settings** are saved at `hw-snapshots/original-2026-11-06.json` (git-ignored). The List/Program step tables (all at factory defaults) are documented in hardware-notes.
- **Next:** Phase 2, the app shell and Basic pane, then T2 tests with the E36234A output 2 as the source.

### 2026-11-06: Phase 2 done (pending your UX review)
- **`LoadLabCore`** (`DeviceSession`, `AppModel`, `MeasurementHistory`) does the following:
  - Owns the one SDL connection and polls V/I/P/R at 4 Hz.
  - Refreshes status every second, which picks up front-panel function changes.
  - Reconnects automatically with backoff, and reports "busy" if another program holds the SDL.
  - Applies edits as clamp → confirmed write → read back.
- **The app has these pieces:**
  - Sidebar with instruments (scan, add by IP, recents) and functions.
  - Readout bar with INPUT ON/OFF, Short, Trigger, and status chips.
  - Basic pane: CC/CV/CP/CR/LED, dynamic mode, ranges, slew.
  - Live stacked charts with min/max downsampling.
  - Settings sheet: sense, Von/latch, protections, averaging, trigger, SoF, monitors.
  - SCPI console window (⌥⌘K).
  - Shortcuts: ⇧⌘I toggles the input, ⌘. is emergency off. Quitting the app switches the input off.
- **Build:** `scripts/bundle.sh [--install]` produces `build/LoadLab.app`, ad-hoc signed.
- **Tests:** 52 simulator/unit tests. The T2 hardware suite (9 tests, E36234A output 2, ≤ 0.8 A) is all green. **The Von latch-OFF cutoff is verified as a hardware under-voltage stop.**
- **Dynamic-mode limitation:** the SDL has no query for static vs dynamic, so the app tracks it and assumes static after connecting.
- **Open item:** macOS Local Network privacy blocks `LoadLab.app` until the user allows it. With ad-hoc signing, a rebuild may trigger the prompt again. A stable self-signed signing identity would avoid that.

# Goosky EdgeTX widget development in Visual Studio Code

## 1. Install the local tools

Install Visual Studio Code and accept the workspace recommendation for the
Lua Language Server extension. On Windows, install standalone Lua 5.3 and add
its directory to `PATH`. The test task first looks for `lua.exe`, then
`lua53.exe`, with MiKTeX's `texlua.exe` retained only as a fallback. Restart
VS Code after changing `PATH`.

Open this project folder in VS Code, not only `main.lua`:

```text
NERC-Goosky-FlightDeck/
├── .vscode/
├── SDCARD/WIDGETS/NERC_GSkyFD/main.lua
├── SDCARD/SCRIPTS/TOOLS/GooskySetup.lua
├── tests/mock_edgetx.lua
├── tests/mock_goosky_setup.lua
├── tests/run_tests.lua
└── TESTING.md
```

## 2. Run the automated mock tests

Use **Terminal → Run Task → EdgeTX: Run widget tests**, or press
`Ctrl+Shift+B`. A successful result ends with:

```text
EdgeTX mock refresh OK
Goosky setup wizard mock OK
```

The tests run both native layouts, check screen boundaries and font-flag usage,
supply telemetry values, emulate native Timers 1 and 2, exercise the ELRS CRSF
parameter scan and repair sequence, check RGB/haptic status, and validate the
model wizard's channel curves, logical timer gate, reset functions and image.

Edit the `telemetry` table near the top of `tests/mock_edgetx.lua` to reproduce a
condition. Useful examples are:

```lua
telemetry["RQly"] = 0       -- receiver/link offline
telemetry["TQly"] = 55      -- weak telemetry return
telemetry["RxBt"] = 10.8    -- low 3S pack example
telemetry["2RSS"] = 0       -- single-antenna receiver
timer1_value = 0            -- countdown timer expired
timer2_value = 90           -- native elapsed flight time
status_flags = 4            -- ELRS model mismatch
```

Run the complete task again after every code change. Do not treat a passing
desktop mock as final radio validation; it tests logic and layout bounds, not
the exact firmware rasterizer or physical controls.

## 3. Set up EdgeTX Companion/Simulator 2.12.2

1. Install EdgeTX Companion 2.12.2.
2. Download and extract the matching EdgeTX SD-card contents for the radio
   target into a writable directory, for example `C:\EdgeTX\simulator-sd`.
3. In Companion, create the correct radio profile and start its simulator.
4. Select that extracted directory as the simulator SD path.
5. In VS Code, run **EdgeTX: Copy widget to simulator SD** and provide the SD
   directory when prompted.
6. Restart the simulator or reload its model after copying an updated script.
7. Add `NERC GooSky FlightDeck` to a full-screen main view and use App/Full Screen mode.

The required simulated SD paths include:

```text
<simulator-sd>/WIDGETS/NERC_GSkyFD/main.lua
<simulator-sd>/SCRIPTS/TOOLS/GooskySetup.lua
<simulator-sd>/IMAGES/GKS1OR.png (plus the other five colors/models)
```

The copy task also adds `simulator.lua` beside `main.lua`. Its permanent purple
`SIM:` marker confirms that every displayed sensor and ELRS response is
synthetic. The backend automatically advances every ten seconds through:

1. Ready
2. Battery low
3. Battery critical
4. Link weak
5. Link critical
6. Telemetry return lost
7. Model Match mismatch
8. Incorrect ELRS settings
9. LiHV pack

To hold one condition, edit `FORCED_SCENARIO` near the top of
`dev/simulator.lua`, for example:

```lua
local FORCED_SCENARIO = "LINK CRITICAL"
```

Run the copy task again and restart the simulator after changing it.

Create separate Companion radio profiles for the TX16S MK3 and TX15/GX15
targets. This is the best way to inspect exact font rendering, touch targets,
widget settings, and the two screen layouts.

## 4. What the stock simulator cannot fully prove

The simulator normally does not reproduce the physical internal ELRS module,
the real Goosky receiver, gimbal RGB hardware, or actual haptic motor. The
simulator-only backend emulates the CRSF module responses and telemetry needed
for visual work, but it cannot validate real hardware timing. Use the mock test
for deterministic states, then test these items on the
radio with blades removed or the motor disconnected:

- ELRS parameter discovery and the repair confirmation dialog
- 333Hz Full, 8ch, telemetry 1:32, 100mW, Dynamic Off readback
- Antenna Mode Switch when the TX module exposes that parameter
- Model Match OK and deliberate mismatch
- Green/yellow/red gimbal-ring behavior
- Yellow and red haptic patterns
- CH3 motor-running gate, throttle hold, CH5 pose mode, and Timer 1 reset
- LiPo and LiHV percentage behavior with known pack voltages

Keep the radio and Companion on EdgeTX 2.12.2 so the simulator matches the
firmware used for flight testing.

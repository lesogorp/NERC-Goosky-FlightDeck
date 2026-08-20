# NERC Goosky FlightDeck development rules

## Scope

This repository contains an EdgeTX 2.12.2 widget and model setup tool for the
Goosky S1 V2 and S2 MAX with ELRS. Supported displays are 800x480 and 480x320.

## Canonical files

- Widget: `SDCARD/WIDGETS/NERC_GSkyFD/main.lua`
- Setup tool: `SDCARD/SCRIPTS/TOOLS/GooskySetup.lua`
- Simulator backend: `dev/simulator.lua`
- Automated tests: `tests/`

Do not create a second source copy of `main.lua`. The `SDCARD` tree must remain
directly installable on a radio.

## Required validation

Run all of these after any Lua change:

```bash
texluac -p SDCARD/WIDGETS/NERC_GSkyFD/main.lua
texluac -p SDCARD/SCRIPTS/TOOLS/GooskySetup.lua
texlua tests/run_tests.lua
```

If standalone Lua 5.3 is installed, `lua tests/run_tests.lua` is also valid.
Do not call a change radio-tested until it has been checked on the relevant
physical RadioMaster display.

## Safety invariants

- ELRS discovery and repair must never run after receiver link/telemetry has
  been active in the current model session.
- ELRS writes require configured and active HOLD, final transmitted CH3 at
  -100%, native TELE off, and no receiver/link signal.
- Throttle HOLD must keep the final transmitted CH3 output at -100%.
- CH1-CH6 mixes must ignore trims; trims remain disabled in FM0-FM8.
- Timers must stop immediately when HOLD is active or telemetry is lost.
- Do not change failsafe claims: Lua cannot verify receiver failsafe.

## UI requirements

- Preserve both native layouts: TX16S MK3 800x480 and TX15/GX15 480x320.
- Keep safety warnings and live data readable; branding must not displace them.
- Avoid EdgeTX-incompatible Lua method-call syntax such as `value:gsub()`.
- Keep the widget folder name at 12 characters or fewer: `NERC_GSkyFD`.

## Packaging

Run `bash tools/build-release.sh`. The release ZIP is written to `build/` and
contains the contents of `SDCARD` at the archive root. Do not package tests,
development files, or compiled `.luac` files.

## Licensing

Do not add or modify a license or copyright notice without explicit project
owner approval.


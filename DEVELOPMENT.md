# Development workflow

## Fast local loop

1. Open the repository root in Visual Studio Code.
2. Edit the canonical files under `SDCARD`.
3. Press `Ctrl+Shift+B` to run `EdgeTX: Simulate TX16S MK3`.
4. The task runs the Lua tests, merges the current `SDCARD` payload into the
   correct EdgeTX screen-size SD pack, injects `dev/simulator.lua`, closes the
   previous EdgeTX simulator instance, and launches a fresh simulator.
5. Use `EdgeTX: Simulate GX15` from **Tasks: Run Task** for the compact-radio
   target. On official Companion 2.12 builds without a GX15 simulator target,
   this task uses the TX15 480x320 simulator as the UI/layout proxy.
6. Test safety-sensitive behavior on the physical radio with the motor
   disconnected or the blades removed.
7. Build the install ZIP with `bash tools/build-release.sh`.

See [TESTING.md](TESTING.md) for simulator and hardware-test details.

## One-time EdgeTX simulator setup

The VS Code tasks launch EdgeTX's standalone `simulator.exe`; Companion does
not need to be clicked manually for each test run.

1. Create/select a Companion profile for simulator state. The supplied example
   uses numeric profile ID `0`, which avoids workstation-specific profile-name
   mismatches. The simulator help screen lists the available profile IDs.
2. Keep the official EdgeTX simulator SD packs separated by LCD family. The
   default local example maps:
   - `C:\Temp\EdgeTXSIM\c800x480` -> TX16S MK3
   - `C:\Temp\EdgeTXSIM\c480x320` -> GX15 / TX15-class compact target
   The NERC task merges this repository's `SDCARD` payload into the selected
   pack and does not delete unrelated EdgeTX files.
3. Copy `dev/simulator.local.example.json` to
   `dev/simulator.local.json`.
4. Set `sdRoot` to the folder that contains `c800x480` and `c480x320` if your
   local path differs from `C:\Temp\EdgeTXSIM`.
5. Set `simulatorExe` if automatic discovery does not find the Companion 2.12
   `simulator.exe` installation.
6. Normally leave profile `0` in place. The example explicitly selects
   `edgetx-tx16smk3` for the 800x480 task and `edgetx-tx15` for the compact
   480x320 task.

`dev/simulator.local.json` is intentionally ignored by Git so workstation paths
and profile choices do not enter the repository.

Available VS Code tasks:

- `EdgeTX: Run widget tests` - Lua desktop/mock regression tests only.
- `EdgeTX: Sync MK3 simulator SD` - merge into `c800x480` without launching.
- `EdgeTX: Sync GX15 simulator SD` - merge into `c480x320` without launching.
- `EdgeTX: Simulate TX16S MK3` - tests, sync `c800x480`, then launch MK3.
- `EdgeTX: Simulate GX15` - tests, sync `c480x320`, then launch the compact
  simulator target.

If the installed Companion build does not contain a GX15 simulator target,
`edgetx-tx15` is the intended 480x320 UI/layout proxy. Point `simulatorExe` at a
self-built EdgeTX simulator containing GX15 only when exact GX15 target behavior
is required. Physical GX15 validation remains authoritative for target-specific
behavior.

## Branch and pull-request flow

- Keep `main` releasable.
- Use a short branch per change, such as `fix/elrs-ch3-gate` or
  `feature/rs4-profile`.
- Put one logical change in each pull request.
- Record radio model, EdgeTX version, and physical test result in the PR.
- CI must pass before merge.

## Codex workflow

Give Codex a bounded task and the radio evidence that reproduces it. Useful
inputs include a photo, telemetry log, current ELRS values, radio model, and
exact EdgeTX/ELRS versions. Codex should follow `AGENTS.md`, update tests with
the implementation, and return a branch or draft pull request for review.

Recommended request format:

```text
Radio: TX16S MK3
EdgeTX: 2.12.2
ELRS: 3.6.4
Observed: ...
Expected: ...
Safety constraints: ...
Evidence: photo/log
```

Never merge a safety-related change solely because the desktop mock passes.

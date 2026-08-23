# Development workflow

## Fast local loop

1. Open the repository root in Visual Studio Code.
2. Edit the canonical files under `SDCARD`.
3. Press `Ctrl+Shift+B` to run `EdgeTX: Simulate TX16S MK3`.
4. The task runs the Lua tests, merges the current `SDCARD` payload into the
   configured simulator SD directory, injects `dev/simulator.lua`, closes the
   previous EdgeTX simulator instance, and launches a fresh simulator.
5. Use `EdgeTX: Simulate GX15` from **Tasks: Run Task** for the compact-radio
   target.
6. Test safety-sensitive behavior on the physical radio with the motor
   disconnected or the blades removed.
7. Build the install ZIP with `bash tools/build-release.sh`.

See [TESTING.md](TESTING.md) for simulator and hardware-test details.

## One-time EdgeTX simulator setup

The VS Code tasks launch EdgeTX's standalone `simulator.exe`; Companion does
not need to be clicked manually for each test run.

1. In EdgeTX Companion, create radio profiles for the targets you want to run.
   The example configuration expects profiles named `NERC MK3` and `NERC GX15`.
2. Prepare an EdgeTX simulator SD directory containing the normal EdgeTX SD
   files. The NERC task merges this repository's `SDCARD` files into it; it does
   not delete unrelated EdgeTX files.
3. Copy `dev/simulator.local.example.json` to
   `dev/simulator.local.json`.
4. Set `sdPath` to that simulator SD directory.
5. Set `simulatorExe` if automatic discovery does not find the Companion 2.12
   `simulator.exe` installation.
6. Change the `mk3` / `gx15` profile names in the JSON if your Companion profile
   names differ.

`dev/simulator.local.json` is intentionally ignored by Git so workstation paths
and profile names do not enter the repository.

Available VS Code tasks:

- `EdgeTX: Run widget tests` - Lua desktop/mock regression tests only.
- `EdgeTX: Sync simulator SD` - merge the repo payload into the simulator SD
  without launching the simulator.
- `EdgeTX: Simulate TX16S MK3` - tests, sync, then launch the MK3 profile.
- `EdgeTX: Simulate GX15` - tests, sync, then launch the GX15 profile.

If the installed Companion build does not contain a GX15 simulator target, point
`simulatorExe` at a self-built EdgeTX simulator that includes GX15, or use a
TX15-class 480x320 simulator profile for UI checks and retain GX15 hardware
validation for target-specific behavior.

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


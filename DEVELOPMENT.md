# Development workflow

## Fast local loop

1. Open the repository root in Visual Studio Code.
2. Edit the canonical files under `SDCARD`.
3. Run the default VS Code task, `EdgeTX: Run widget tests`.
4. Use `EdgeTX: Copy widget to simulator SD` for visual checks.
5. Test safety-sensitive behavior on the physical radio with the motor
   disconnected or the blades removed.
6. Build the install ZIP with `bash tools/build-release.sh`.

See [TESTING.md](TESTING.md) for simulator and hardware-test details.

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


# NERC Goosky FlightDeck — Test Release

**Telemetry & Flight Status**

One EdgeTX 2.12.2 widget for the Goosky S1 V2 and S2 MAX. It automatically
selects the 800×480 TX16S MK3 layout or the 480×320 TX15/GX15 layout from the
radio screen size.

Installed path: `/WIDGETS/NERC_GSkyFD/main.lua`

## Read this first

GooskySetup changes the **current model**. Back it up in EdgeTX Companion.
Disconnect the motor or remove the main and tail blades before setup or output
testing. This is a test release; complete every safety check before flight.

## Install and set up

1. Copy the package `WIDGETS`, `SCRIPTS`, and `IMAGES` folders to the SD-card
   root. Merge them without deleting unrelated files.
2. Restart EdgeTX or reload the model.
3. Open **MDL → Display**, add **NERC Goosky FlightDeck**, and select **App
   mode**. Lua cannot perform this step automatically.
4. Open the dashboard once, then exit it.
5. Disconnect the motor or remove the blades.
6. Run **SYS → Tools → GooskySetup**.
7. Select the aircraft/color. Select each `ATT`, `BANK`, `HOLD`, and `RESET`
   field, then move the desired switch into its active/final position. Every
   field starts blank. Momentary HOLD/RESET positions latch on first movement.
8. Set Timer 1. It defaults to 5:00 and changes in 30-second steps.
9. Review the changes and select `YES`.

### Mandatory manual steps

Complete these in order after GooskySetup finishes:

1. **Before connecting the helicopter:** open **MDL → Customizable Switches**
   and set `SW1` through `SW6` **Type = None**.
2. **Then connect the helicopter:** open **MDL → Telemetry → Discover New**
   and wait for every sensor to appear.

For S2 MAX, the discovered `GAlt` sensor with ID/sub-ID `0002/4` is rotor
speed. Rename it `RPM` and change its unit to `rpm`. The widget accepts either
sensor name.

## Mandatory safety check

Test with the motor disconnected or the main and tail blades removed:

1. Confirm the correct aircraft and color are displayed.
2. In Channel Monitor, apply HOLD and move the throttle stick through its full
   range in all three banks. CH3 must remain at `-100`.
3. Press every trim. CH1–CH6 and their trim indicators must not change.
4. Release HOLD at idle: the footer must show `THR IDLE` and both timers must
   remain stopped.
5. Raise mixed CH3 above 20% with TELE active: the footer must show
   `THR ACTIVE` and both timers must run.
6. Apply HOLD or disconnect telemetry: both timers must stop immediately.
7. Press RESET and confirm both timers return to their configured starts.
8. Turn RF off and confirm the receiver/flight controller keeps the motor
   stopped. Lua cannot read receiver failsafe, so this RF-loss test is required.
9. Confirm the ELRS warning is clear after its receiver-off check.
10. Create one yellow and one red test condition and verify that the screen,
    gimbal LEDs, numbered-button battery bar, and haptics agree.

## What the setup tool changes

GooskySetup overwrites these items in the current model:

- CH1–CH6 mixes and throttle curves 1–3
- Logical switches L01–L02
- Special functions SF1–SF14
- Native Timer 1 and Timer 2
- Internal RF model settings, model name, and model image

The generated channel assignment is:

| Channel | Function | Setup |
| --- | --- | --- |
| CH1 | Aileron | Direct AETR control; trim off |
| CH2 | Elevator | Direct AETR control; trim off |
| CH3 | Motor | Bank 1 `-100/25/25/25/25`; Bank 2 `35`; Bank 3 `45` |
| CH4 | Rudder | Direct AETR control; trim off |
| CH5 | Pose | `3D=-100`; `ATT=+100` |
| CH6 | Collective | Linear `-100/-50/0/+50/+100`; trim off |

SF1 applies the configured HOLD switch as a final CH3 override to `-100`, so
bank mixer order cannot defeat throttle hold. GooskySetup also clears and
disables every trim in FM0–FM8 and verifies the result. It forces the current
model's ADC filter override Off.

Timer 1 is the countdown. Timer 2 is elapsed flight time. L01 detects mixed CH3
above 20%; L02 requires `L01 AND TELE AND NOT HOLD`. Both timers use L02. RESET
resets both timers, S1 controls display brightness, S2 controls master volume,
and native SD logging runs every second while TELE is active.

SF7–SF14 add one-shot voice alerts for throttle HOLD/active, Bank 1/2/3,
3D mode, stability on, and timer reset. They use the standard EdgeTX 2.12
English sound pack and do not announce the already-active state at model load.

## Dashboard capabilities

The startup splash carries Goosky and New England RC branding without using
permanent dashboard space. It is nonblocking: telemetry processing, ELRS
preflight, LEDs, haptics, and input remain active, and any link or warning
immediately reveals the dashboard.

### Aircraft profiles

| Profile | OEM battery | Full voltage |
| --- | ---: | ---: |
| S1 V2 | 2S / 300 mAh | 8.40 V LiPo |
| S2 MAX | 3S / 750 mAh | 12.60 V LiPo |

`Aircraft=Auto` checks the model name first (`S1` or `S2`), then pack voltage.
Select the aircraft manually if Auto is wrong. Both aircraft use the same
receiver target, so CRSF sensor names alone cannot distinguish them.

### Battery display

`Auto / OEM` uses the selected aircraft's LiPo voltage curve. It maps about
4.20 V/cell to 100%, 3.84 V/cell to 50%, 3.69 V/cell to 10%, and 3.30 V/cell
to 0%. A value above 4.22 V/cell automatically latches LiHV for that widget
session. Select `LiHV Curve` for a partially discharged LiHV pack that can no
longer be distinguished by voltage alone.

Voltage percentage is only an estimate; load, sag, temperature, age, and rest
time affect it. `CapaAdj` corrects consumed capacity against charger results.
For example, if telemetry reports 250 mAh and the charger repeatedly replaces
275 mAh, use `+10%`. Calibrate from several fully charged packs, not one flight.

When valid battery telemetry is available, RGB buttons 1–6 form a six-segment
battery bar. Segments are green above 30%, yellow from 16–30%, and red at 15%
or below. `SW1`–`SW6` must have `Type=None`; EdgeTX does not let Lua set this.

### Pilot alerts

With `StatusHelp=On`, the worst monitored condition controls the screen message,
gimbal LEDs, and haptics:

- Green: monitored conditions normal
- Yellow: caution; one short pulse, repeated about every 30 seconds
- Red: critical/land warning; strong two-part pulse, repeated about every 5 seconds

Before the first receiver connection, unavailable data remains neutral `---`
without alarms. After a receiver has connected, later loss becomes a real
offline warning. A missing or constant-zero second RSSI is treated as an unused
second antenna and does not create an alarm.

After landing, apply HOLD and press RESET while TELE is offline to acknowledge
the removed battery. This resets the timers and maximum-power capture and stops
repeating offline alerts. Receiver reconnection re-arms protection.

### Telemetry

Used sensors include `1RSS`, `2RSS`, `RQly`, `RSNR`, `ANT`, `RFMD`, `TPWR`,
`TRSS`, `TQly`, `TSNR`, `RxBt`, `Curr`, `Capa`, and optional `Bat%`.

The receiver target may also list GPS fields that do not provide real data;
the widget ignores them. EdgeTX Lua cannot discover, add, rename, or change the
unit of a telemetry sensor. Run Discover New manually for each model.

## ELRS receiver-off preflight

The dashboard performs one bounded check for:

| Setting | Required value |
| --- | --- |
| Packet Rate | `333Hz Full` |
| Switch Mode | `8ch` |
| Telemetry Ratio | `1:32` |
| Max Power | `100mW` |
| Dynamic Power | `Off` |
| Antenna Mode | `Switch` when the TX exposes this setting |

It can start only when HOLD is configured and active, final transmitted CH3 is
exactly `-100`, native TELE is off, no link/signal exists, and the receiver has not
previously connected in the current session. It stops after completion or its
retry limit and never polls continuously in flight.

If a mismatch is found, the dashboard asks before changing anything. Choose
`YES`/`NO` by touch, or turn the scroll wheel and press it. Repair writes only
the five core settings above plus Antenna Mode when available, reads them back,
and leaves Model Match unchanged. `Switch` is used for the single-antenna
BetaFPV 2.4 GHz Nano receiver target in these Goosky models; a transmitter that
does not expose Antenna Mode keeps the five-setting flow.
The first screen boxes **Current Settings** beside **Recommended**. After YES,
the result screen preserves **Original Settings** beside **Verified Current**
and confirms when all five or six applicable settings match.
CH5 must be low (`3D`) because the ELRS CH5 ARM flag can affect Dynamic Power;
that flag is not the helicopter's motor state.

Normal ELRS settings stay hidden. The alert bar appears only for an actionable
settings mismatch, a true Model Match mismatch, or a failed TX-module/parameter
exchange. Returning from the separate ELRS tool requests one fresh bounded
scan, but only if all receiver-off safety conditions still pass.

If the receiver is off but the check is prevented before discovery, the alert
bar names the rejected gate: `HOLD NOT CONFIGURED`, `THROTTLE HOLD OFF`, or the
actual final CH3 output when it is not at `-100%`. An unavailable HOLD mapping displays `HOLD NOT SET`; it is
never treated or displayed as an active hold.

## Widget options

| Option | Purpose |
| --- | --- |
| `Aircraft` | Auto, S1 V2, or S2 MAX |
| `BatteryPct` | Auto/OEM, LiPo, LiHV, Bat% sensor, or capacity used |
| `PackCap` | `0` uses 300 mAh for S1 or 750 mAh for S2 MAX |
| `CapaAdj` | Corrects consumed-capacity telemetry by -50% to +100% |
| `SquareColor` | Panel borders and labels |
| `ValueColor` | Live values |
| `StatusHelp` | On, Screen Only, or Off |
| `BankSwitch` | Blank uses the BANK captured by GooskySetup |
| `HoldSwitch` | Blank uses the HOLD captured by GooskySetup |
| `TimerReset` | Blank uses the RESET captured by GooskySetup |

GooskySetup stores these per-model switch captures under `/SCRIPTS/TOOLS` so a
widget-folder replacement cannot remove them. The dashboard also reads the old
widget-folder location to migrate existing installations.

To open settings from App mode, press `RTN` or long-press outside an ELRS
dialog to return to the dashboard. Long-press the widget and select **Widget
settings**. EdgeTX does not expose an API that opens this menu directly.

## Limits and troubleshooting

- `APP MODE REQUIRED`: add the widget to Display and select App mode.
- No telemetry values: connect the receiver and run **MDL → Telemetry →
  Discover New**.
- Battery buttons do not light: set **MDL → Customizable Switches → SW1–SW6 →
  Type=None**.
- Wrong aircraft/color: run GooskySetup again or select `Aircraft` manually.
- No ELRS repair prompt: the receiver-off safety gates above are not all true,
  or the receiver already connected during this model session. Power the
  receiver off and reopen/reload the widget before connecting it.
- `NO ELRS TX MODULE RESPONSE`: the radio-side ELRS module did not answer the
  bounded discovery request. Confirm the normal ExpressLRS tool opens, then
  return to the dashboard for one fresh check.
- `ELRS READ INCOMPLETE`: the TX module answered, but one or more named settings
  could not be read; the alert identifies the missing setting names.
- EdgeTX Lua cannot add the widget, select App mode, create another model,
  configure telemetry sensors, set Customizable Switch Type, or verify actual
  receiver failsafe.

## Model images

Aircraft images are stored under `/IMAGES`; the widget folder contains only
code and dashboard UI assets. Images are used with attribution to SkyRaccoon:
<https://www.skyraccoon.com/category/helicopters>. See
`/IMAGES/SKYRACCOON.txt` for individual source pages.

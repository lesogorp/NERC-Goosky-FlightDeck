NERC Goosky FlightDeck - Test Release
Telemetry & Flight Status

For Goosky S1 V2 and S2 MAX on EdgeTX 2.12.2.
Supported displays:
- RadioMaster TX16S MK3: 800x480
- RadioMaster TX15 and GX15: 480x320

SAFETY FIRST
This setup changes the CURRENT model. Back up the radio/model in EdgeTX
Companion. Disconnect the motor or remove the main and tail blades before
running setup or testing outputs. Do not fly until the checks below pass.

INSTALL AND INITIAL SETUP
1. Copy WIDGETS, SCRIPTS and IMAGES to the root of the radio SD card. Merge the
   folders; do not delete unrelated files.
2. Restart EdgeTX or reload the model.
3. Open MDL > Display, add NERC Goosky FlightDeck and select App mode.
   Lua cannot add the widget or select App mode automatically.
4. Open the dashboard once, then exit it.
5. With the motor disconnected or blades removed, run:
   SYS > Tools > GooskySetup
6. Select the aircraft/color. For ATT, BANK, HOLD and RESET, select the field
   and move the desired switch into its active/final position. All four start
   blank.
7. Set Timer 1, review the warning and select YES.

TWO MANDATORY MANUAL STEPS
Complete these in order after GooskySetup finishes:

1. BEFORE connecting the helicopter:
   MDL > Customizable Switches > set SW1-SW6 Type to None.

2. THEN connect the helicopter:
   MDL > Telemetry > Discover New > wait for all sensors to appear.

S2 MAX ONLY
The discovered GAlt sensor with ID/sub-ID 0002/4 is rotor speed. Rename it RPM
and change its unit to rpm. The dashboard accepts either GAlt or RPM.

REQUIRED SAFETY CHECK
Use EdgeTX Channel Monitor with the motor disconnected or blades removed:
- HOLD must force CH3 to -100 in every bank and at every throttle-stick position.
- CH1-CH6 must not move when any trim key is pressed.
- Timer 1 and Timer 2 must stop with HOLD on or telemetry disconnected.
- With RF turned off, the receiver/flight controller must keep the motor stopped.
  Lua cannot verify receiver failsafe; this physical RF-loss test is mandatory.

WHAT GooskySetup CONFIGURES
- AETR channels 1-4, fixed CH5 pose mode and linear CH6 collective pitch
- Three motor banks and a final CH3=-100 throttle-hold override
- Native Timer 1 countdown and Timer 2 flight time
- Timer gate: CH3 above 20%, HOLD released and native TELE active
- Timer reset, S1 display brightness and S2 master volume
- One-shot voice alerts for HOLD/active, Bank 1-3, 3D/ATT and timer reset
- Trim disabled on CH1-CH6 and in all flight modes
- Per-model ADC filter override Off
- Native 1-second SD telemetry logging while TELE is active
- Selected model name/image and internal RF model settings

MAIN DASHBOARD FEATURES
- Branded nonblocking startup splash; active telemetry or warnings bypass it
- Automatic 800x480 or 480x320 layout
- Combined S1 V2/S2 MAX aircraft profiles
- LiPo/LiHV battery estimate, consumed capacity and adjustable calibration
- Six RGB buttons used as a battery bar when SW1-SW6 Type=None
- Plain-language cautions, gimbal RGB status and haptic alerts
- Link, current, power, rotor RPM, throttle state and both native timers
- Quiet neutral state before a receiver has connected for the first time

ELRS PREFLIGHT CHECK
Before receiver connection, the dashboard can check and offer to repair:
- Packet Rate: 333Hz Full
- Switch Mode: 8ch
- Telemetry Ratio: 1:32
- Max Power: 100mW
- Dynamic Power: Off
- Antenna Mode: Switch (when the TX module exposes this setting)

The scan is bounded and receiver-off only. It requires HOLD on, final transmitted
CH3 at -100, native TELE off, no link/signal and no earlier receiver connection in the
current session. It never continuously polls or changes ELRS settings in flight.
Repair requires selecting YES and verifies each written value.
The warning boxes Current versus Recommended settings. After repair it boxes
Original versus Verified Current values and confirms all applicable matches.
Antenna Mode is conditional: Gemini-capable transmitters are set to Switch for
the single-antenna BetaFPV 2.4 GHz Nano receiver; other transmitters retain the
five-setting check.
If the radio-side module does not answer, the dashboard now reports NO ELRS TX
MODULE RESPONSE. If discovery succeeds but parameters do not, it reports which
settings could not be read instead of silently leaving the check pending.
If discovery is prevented before it starts, the red bar identifies the rejected
gate, including the final CH3 output value when it is not at -100%.

WIDGET SETTINGS
Aircraft     Auto, S1 V2 or S2 MAX
BatteryPct   Auto/OEM, LiPo, LiHV, Bat% sensor or capacity used
PackCap      0 uses OEM capacity: S1 300mAh; S2 MAX 750mAh
CapaAdj      Correct consumed-capacity telemetry against charger results
StatusHelp   On, Screen Only or Off
Colors       Panel/label and live-value colors
Switches     BANK, HOLD and RESET default blank; blank uses GooskySetup values

GooskySetup stores the per-model BANK/HOLD/RESET capture under SCRIPTS/TOOLS so
replacing the widget folder cannot remove it. Existing widget-folder captures
remain readable. An unavailable HOLD capture displays HOLD NOT SET; it is never
assumed to mean HOLD ON.

To edit settings from App mode, press RTN or long-press outside an ELRS dialog,
then long-press the widget and choose Widget settings.

AFTER A FLIGHT
If removing the flight battery triggers the receiver-offline alert, apply HOLD
and press the configured RESET switch while TELE is offline. This acknowledges
the completed flight, resets both timers and silences repeating alerts. The next
receiver connection automatically re-arms protection.

LIMITATIONS
- EdgeTX Lua cannot add the widget, select App mode, discover/edit telemetry
  sensors, set SW1-SW6 Type, create a separate model or verify receiver failsafe.
- GPS fields exposed by the receiver target are placeholders and are ignored.
- Battery percentage from voltage is an estimate affected by load, temperature,
  battery age and voltage sag. Keep normal timer and low-voltage protections.

MODEL IMAGE SOURCES
Aircraft images are used with attribution to SkyRaccoon:
https://www.skyraccoon.com/category/helicopters
See IMAGES/SKYRACCOON.txt for individual source pages.

Detailed operation and troubleshooting:
/WIDGETS/NERC_GSkyFD/README.md

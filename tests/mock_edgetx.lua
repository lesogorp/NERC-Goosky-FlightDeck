LCD_W = 800
LCD_H = 480

CHOICE, COLOR, BOOL, SOURCE, SWITCH, VALUE = 1, 2, 3, 4, 5, 6
WHITE, BLACK, GREEN, RED, YELLOW, ORANGE = 1, 2, 3, 4, 5, 6
BOLD, CENTER, VCENTER, RIGHT = 8, 16, 32, 64
DBLSIZE, XXLSIZE, MIDSIZE, CUSTOM_COLOR, SOLID, SMLSIZE = 128, 256, 512, 1024, 2048, 4096
PLAY_NOW, EVT_TOUCH_FIRST, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 1, 2, 3, 4
EVT_VIRTUAL_PREV, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_ENTER = 5, 6, 7
bit32 = {
    band = function(a, b) return a & b end,
    btest = function(a, b) return (a & b) ~= 0 end
}

local tick = 0
local timer1_value = 180
local timer2_value = 0
local timer1_reset_count = 0
local timer2_reset_count = 0
local switch_states = {}
local status_flags = 4
local drawn_text = {}
local offline_small_font_count = 0
local strict_screen_bounds = false
local fullscreen_exit_count = 0
local telemetry = {
    ["1RSS"] = -45, ["2RSS"] = -47, ["RQly"] = 100, ["RSNR"] = 9,
    ["ANT"] = 0, ["RFMD"] = 8, ["TPWR"] = 10, ["TRSS"] = -42,
    ["TQly"] = 100, ["TSNR"] = 8, ["RxBt"] = 12.3, ["Curr"] = 4.2,
    ["Capa"] = 250, ["Bat%"] = 72, ["tx-voltage"] = 8.1,
    ["ch3"] = 0, ["ch5"] = 1024
}
local output_values = {}

function getTime()
    tick = tick + 10
    return tick
end

function getRtcTime() return math.floor(tick / 100) end
function getDateTime() return { hour = 12, min = 34, sec = 56 } end
function getFieldInfo(name) return telemetry[name] and { id = name } or nil end
function getValue(id) return telemetry[id] or 0 end
function getOutputValue(index)
    if output_values[index] ~= nil then return output_values[index] end
    return getValue("ch" .. tostring(index + 1))
end
function getSwitchValue(id)
    if switch_states[id] ~= nil then return switch_states[id] end
    if id == 997 then return (telemetry["RQly"] or 0) > 0 end
    return false
end
function getSwitchIndex(name)
    if name == "TELE" then return 997 end
    return 0
end
function playTone(...) end
local haptic_calls = {}
function playHaptic(duration, pause, flags)
    haptic_calls[#haptic_calls + 1] = { duration, pause, flags }
end
function fstat(_) return true end

-- TX16S MK3/TX15 expose 20 gimbal/decorative LEDs followed by six
-- function-switch LEDs.
LED_STRIP_LENGTH = 26
local led_colors = {}
local led_apply_count = 0
local reject_button_led_writes = false
function setRGBLedColor(index, red, green, blue)
    if reject_button_led_writes and index >= 20 then return false end
    led_colors[index] = { red, green, blue }
    return true
end
function applyRGBLedColors()
    led_apply_count = led_apply_count + 1
end

local mock_model_info = {
    name = "Goosky S2 Max", filename = "goosky-s2.yml",
    bitmap = "GKS2PU.png", jitterFilter = 2
}

model = {
    getInfo = function()
        return {
            name = mock_model_info.name,
            filename = mock_model_info.filename,
            bitmap = mock_model_info.bitmap,
            jitterFilter = mock_model_info.jitterFilter
        }
    end,
    setInfo = function(values)
        for key, value in pairs(values) do mock_model_info[key] = value end
    end,
    getTimer = function(index)
        if index == 0 then return { value = timer1_value, start = 180 } end
        if index == 1 then return { value = timer2_value, start = 0 } end
        return nil
    end,
    resetTimer = function(index)
        if index == 0 then
            timer1_reset_count = timer1_reset_count + 1
            timer1_value = 180
        elseif index == 1 then
            timer2_reset_count = timer2_reset_count + 1
            timer2_value = 0
        else
            error("unexpected timer index")
        end
    end
}
local bitmap_open_paths = {}
Bitmap = { open = function(path)
    bitmap_open_paths[#bitmap_open_paths + 1] = path
    return path
end }

local function assert_valid_font_flags(flags, value)
    flags = flags or 0
    local explicit_sizes = 0
    if (flags & BOLD) ~= 0 then explicit_sizes = explicit_sizes + 1 end
    if (flags & DBLSIZE) ~= 0 then explicit_sizes = explicit_sizes + 1 end
    if (flags & XXLSIZE) ~= 0 then explicit_sizes = explicit_sizes + 1 end
    if (flags & MIDSIZE) ~= 0 then explicit_sizes = explicit_sizes + 1 end
    if (flags & SMLSIZE) ~= 0 then explicit_sizes = explicit_sizes + 1 end
    assert(explicit_sizes <= 1, "multiple EdgeTX font-size flags combined: " .. tostring(value) .. " flags=" .. tostring(flags))
end

lcd = {
    RGB = function(r, g, b) return r * 65536 + g * 256 + b end,
    setColor = function(...) end,
    getColor = function(_) return 1 end,
    drawFilledRectangle = function(x, y, w, h, ...)
        if strict_screen_bounds then
            assert(x >= 0 and y >= 0 and w >= 0 and h >= 0)
            assert(x + w <= LCD_W and y + h <= LCD_H, "rectangle outside screen")
        end
    end,
    drawText = function(x, y, value, flags)
        assert_valid_font_flags(flags, value)
        if tostring(value) == "OFFLINE" and (flags & SMLSIZE) ~= 0 then
            offline_small_font_count = offline_small_font_count + 1
        end
        if strict_screen_bounds then
            assert(x >= 0 and x <= LCD_W and y >= 0 and y <= LCD_H, "text anchor outside screen: " .. tostring(value))
        end
        drawn_text[#drawn_text + 1] = tostring(value)
    end,
    drawBitmap = function(...) end,
    drawAnnulus = function(x, y, inner, outer, ...)
        if strict_screen_bounds then
            assert(x - outer >= 0 and x + outer <= LCD_W and y - outer >= 0 and y + outer <= LCD_H, "annulus outside screen")
        end
    end,
    drawArc = function(x, y, radius, ...)
        if strict_screen_bounds then
            assert(x - radius >= 0 and x + radius <= LCD_W and y - radius >= 0 and y + radius <= LCD_H, "arc outside screen")
        end
    end,
    drawRectangle = function(x, y, w, h, ...)
        if strict_screen_bounds then
            assert(x >= 0 and y >= 0 and x + w <= LCD_W and y + h <= LCD_H, "outline outside screen")
        end
    end,
    drawLine = function(x1, y1, x2, y2, ...)
        if strict_screen_bounds then
            assert(x1 >= 0 and x1 <= LCD_W and x2 >= 0 and x2 <= LCD_W)
            assert(y1 >= 0 and y1 <= LCD_H and y2 >= 0 and y2 <= LCD_H, "line outside screen")
        end
    end,
    exitFullScreen = function() fullscreen_exit_count = fullscreen_exit_count + 1 end,
    sizeText = function(value, flags)
        assert_valid_font_flags(flags, value)
        local width = #tostring(value) * (((flags & SMLSIZE) ~= 0) and 6 or 9)
        if (flags & MIDSIZE) ~= 0 then width = width * 2 end
        local height = 18
        if (flags & SMLSIZE) ~= 0 then height = 12 end
        if (flags & BOLD) ~= 0 then height = 20 end
        if (flags & MIDSIZE) ~= 0 then height = 32 end
        if (flags & DBLSIZE) ~= 0 then height = 36 end
        return width, height
    end
}

local crsf_queue = {}
local write_busy_remaining = { [5] = 2, [6] = 2, [7] = 2 }
local require_elrs_lua_address = false
local saw_elrs_lua_address = false
local rejected_legacy_local_address = 0
local crsf_push_count = 0
local crsf_pop_count = 0
local discovery_busy_remaining = 0
local antenna_parameter_available = true

local function push_string(target, value)
    for i = 1, #value do target[#target + 1] = string.byte(value, i) end
    target[#target + 1] = 0
end

local parameters = {
    { "Packet Rate", "50Hz;333Hz Full (-105dBm)", 1, "" },
    { "Telem Ratio", "Std;Off;1:128;1:64;1:32", 4, "" },
    { "Switch Mode", "8ch;16ch Rate/2;12ch Mixed", 0, "" },
    { "Model Match", "Off;On", 1, " (ID: 07)" },
    { "Max Power", "10;25;50;100;250", 3, "mW" },
    { "Dynamic", "Off;Dyn;AUX9;AUX10;AUX11;AUX12", 0, "" },
    { "Antenna Mode", "Gemini;Ant1;Ant2;Switch", 3, "" }
}

local function queue_parameter(field_id, handset_id)
    local parameter = parameters[field_id]
    local data = { handset_id or 0xEA, 0xEE, field_id, 0, 0, 9 }
    push_string(data, parameter[1])
    push_string(data, parameter[2])
    data[#data + 1] = parameter[3]
    data[#data + 1] = 0
    data[#data + 1] = 0
    data[#data + 1] = 0
    push_string(data, parameter[4])
    crsf_queue[#crsf_queue + 1] = { 0x2B, data }
end

function crossfireTelemetryPush(command, data)
    crsf_push_count = crsf_push_count + 1
    if command == 0x28 then
        if discovery_busy_remaining > 0 then
            discovery_busy_remaining = discovery_busy_remaining - 1
            return false
        end
        local info = { 0xEA, 0xEE }
        push_string(info, "ELRS TX")
        -- ExpressLRS device signature followed by the remaining device-info
        -- metadata. The field count is at name-end offset + 12.
        info[#info + 1] = 0x45
        info[#info + 1] = 0x4C
        info[#info + 1] = 0x52
        info[#info + 1] = 0x53
        for _ = 1, 8 do info[#info + 1] = 0 end
        info[#info + 1] = antenna_parameter_available and #parameters or (#parameters - 1)
        crsf_queue[#crsf_queue + 1] = { 0x29, info }
    elseif command == 0x2C then
        if data[2] == 0xEF then saw_elrs_lua_address = true end
        if require_elrs_lua_address and data[2] ~= 0xEF then
            rejected_legacy_local_address = rejected_legacy_local_address + 1
            return true
        end
        queue_parameter(data[3], data[2])
    elseif command == 0x2D then
        if data[2] == 0xEF then saw_elrs_lua_address = true end
        if require_elrs_lua_address and data[2] ~= 0xEF then
            rejected_legacy_local_address = rejected_legacy_local_address + 1
            return true
        end
        if data[3] == 0 then
            crsf_queue[#crsf_queue + 1] = { 0x2E, { data[2], 0xEE, 0, 0, 0, status_flags } }
        else
            local parameter = parameters[data[3]]
            assert(parameter)
            if write_busy_remaining[data[3]] and write_busy_remaining[data[3]] > 0 then
                write_busy_remaining[data[3]] = write_busy_remaining[data[3]] - 1
                return false
            end
            parameter[3] = data[4]
            if data[3] == 1 and data[4] == 1 then
                -- Full-resolution packet rates expose full-resolution switch modes.
                parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
                parameters[3][3] = 1
            end
        end
    end
    return true
end

function crossfireTelemetryPop()
    crsf_pop_count = crsf_pop_count + 1
    if #crsf_queue == 0 then return nil end
    local frame = table.remove(crsf_queue, 1)
    return frame[1], frame[2]
end

local widget_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
assert(#"NERC_GSkyFD" <= 12, "EdgeTX widget directory name exceeds loader limit")
assert(widget_module.name == "NERC Goosky FlightDeck")
assert(#widget_module.options <= 10)
local native_options = {}
for _, option in ipairs(widget_module.options) do
    assert(option[1] ~= "ThrSource")
    native_options[option[1]] = option
end
assert(native_options.BankSwitch and native_options.BankSwitch[3] == 0)
assert(native_options.HoldSwitch and native_options.HoldSwitch[3] == 0)
assert(native_options.TimerReset and native_options.TimerReset[3] == 0)
local widget = widget_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
assert(widget.splash_pending == true and widget.splash_until == 0,
    "splash timer must wait for the first visible App Mode refresh")

-- A dashboard placed in a genuinely small normal widget zone must not render
-- full-screen coordinates. A nil event alone is not sufficient: TX15 can also
-- send nil during an idle App Mode refresh.
widget.zone.w = 360
widget.zone.h = 180
drawn_text = {}
widget_module.refresh(widget, nil, nil)
local app_mode_warning_seen = false
for _, value in ipairs(drawn_text) do
    if value == "APP MODE REQUIRED" then app_mode_warning_seen = true end
end
assert(app_mode_warning_seen)
assert(widget.splash_pending == true,
    "a normal-size warning render must not consume the startup splash")
drawn_text = {}
widget.zone.w = 800
widget.zone.h = 480

-- A corrupted/stale widget context must not throw "attempt to index a string
-- value" while deciding whether App Mode is available.
local saved_zone = widget.zone
widget.zone = "stale-zone"
local malformed_zone_ok = pcall(widget_module.refresh, widget, nil, nil)
assert(malformed_zone_ok)
widget.zone = saved_zone
assert(widget.splash_pending == true,
    "invalid widget geometry must not consume the startup splash")
drawn_text = {}

-- Complete the ELRS pre-link scan first, then establish native TELE. This is
-- the required flight-safe order on the real radio.
switch_states[10] = true
telemetry["ch3"] = -1024
telemetry["RQly"] = 0
switch_states[997] = false
widget_module.refresh(widget, 0, nil)
assert(widget.splash_pending == false and widget.splash_until > 0,
    "first full-screen refresh did not start the startup splash timer")
for _ = 1, 29 do
    widget_module.refresh(widget, 0, nil)
end
switch_states[997] = true
telemetry["RQly"] = 100
widget_module.refresh(widget, 0, nil)
assert(mock_model_info.jitterFilter == 1,
    "dashboard must detect and force the model ADC filter off")

-- Model-match mismatch is critical: the gimbal/decorative LEDs are red while
-- the numbered buttons remain a battery gauge.
for index = 0, 19 do
    assert(led_colors[index][1] == 255 and led_colors[index][2] == 0 and led_colors[index][3] == 0)
end
local initial_battery_segments = 0
for index = 20, 25 do
    if led_colors[index][2] == 190 then initial_battery_segments = initial_battery_segments + 1 end
end
assert(initial_battery_segments == 6)
assert(#haptic_calls >= 2)

local last_hud = ""
for _, value in ipairs(drawn_text) do
    if string.find(value, "TLM", 1, true) then last_hud = value end
end

assert(string.find(last_hud, "333", 1, true))
assert(string.find(last_hud, "8ch", 1, true))
assert(string.find(last_hud, "1:32", 1, true))
assert(string.find(last_hud, "07", 1, true))
assert(string.find(last_hud, "MISMATCH", 1, true))
assert(string.find(last_hud, "ARM OFF", 1, true))
assert(timer1_reset_count == 0)
switch_states[997] = nil

-- Native EdgeTX TELE is the hard safety gate for all automatic ELRS reads.
-- A newly created widget must make no CRSF push/pop calls while TELE is on;
-- once TELE is off it may begin its bounded receiver-off preflight scan.
local safety_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local safety_widget = safety_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
switch_states[10] = true
telemetry["ch3"] = -1024
telemetry["RQly"] = 0
switch_states[997] = true
local safe_push_before, safe_pop_before = crsf_push_count, crsf_pop_count
for _ = 1, 20 do safety_module.refresh(safety_widget, 0, nil) end
assert(crsf_push_count == safe_push_before and crsf_pop_count == safe_pop_before,
    "ELRS CRSF traffic must stop while native TELE is active")
switch_states[997] = false
safety_widget = safety_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
safety_module.refresh(safety_widget, 0, nil)
assert(crsf_push_count > safe_push_before,
    "bounded ELRS preflight scan must be allowed after TELE becomes inactive")
for _ = 1, 30 do safety_module.refresh(safety_widget, 0, nil) end
local bounded_pushes, bounded_pops = crsf_push_count, crsf_pop_count
for _ = 1, 50 do safety_module.refresh(safety_widget, 0, nil) end
assert(crsf_push_count == bounded_pushes and crsf_pop_count == bounded_pops,
    "completed ELRS preflight scan must not become continuous polling")

-- Leaving the dashboard for the ELRS tool and returning requests one fresh,
-- bounded scan. This catches settings changed after the widget's first scan.
parameters[1][3] = 0
drawn_text = {}
safety_module.background(safety_widget)
for _ = 1, 50 do safety_module.refresh(safety_widget, 0, nil) end
local resumed_warning = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then resumed_warning = true end
end
assert(resumed_warning,
    "returning from the ELRS tool did not recheck externally changed settings")
assert(crsf_push_count > bounded_pushes,
    "returning from the ELRS tool did not start a fresh bounded scan")
parameters[1][3] = 1
switch_states[997] = nil

-- The other three gates are independent and mandatory: configured HOLD must
-- be active, CH3 must be at its -100% endpoint, and no receiver signal may be
-- present. None of these blocked states may touch the shared CRSF queue.
local strict_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local strict_widget = strict_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
switch_states[997] = false
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
switch_states[10] = false
local strict_pushes, strict_pops = crsf_push_count, crsf_pop_count
for _ = 1, 10 do strict_module.refresh(strict_widget, 0, nil) end
assert(crsf_push_count == strict_pushes and crsf_pop_count == strict_pops,
    "ELRS scan ran with throttle hold released")

switch_states[10] = true
telemetry["ch3"] = 0
for _ = 1, 10 do strict_module.refresh(strict_widget, 0, nil) end
assert(crsf_push_count == strict_pushes and crsf_pop_count == strict_pops,
    "ELRS scan ran while CH3 was not at -100%")

telemetry["ch3"] = -1024
telemetry["RQly"] = 100
for _ = 1, 10 do strict_module.refresh(strict_widget, 0, nil) end
assert(crsf_push_count == strict_pushes and crsf_pop_count == strict_pops,
    "ELRS scan ran while receiver signal was present")

telemetry["RQly"] = 0
strict_module.refresh(strict_widget, 0, nil)
assert(crsf_push_count > strict_pushes,
    "ELRS scan did not start after all receiver-off safety gates became true")
switch_states[997] = nil

-- SF1 overrides the final transmitted CH3 output after the mixer channel
-- source is calculated. The ELRS gate must use getOutputValue(2), matching the
-- EdgeTX Outputs page, rather than rejecting the pre-override getValue("ch3").
local sf_output_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local sf_output_widget = sf_output_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
switch_states[997] = false
switch_states[10] = true
telemetry["RQly"] = 0
telemetry["ch3"] = 0
output_values[2] = -1024
local sf_output_pushes = crsf_push_count
drawn_text = {}
sf_output_module.refresh(sf_output_widget, 0, nil)
assert(crsf_push_count > sf_output_pushes,
    "ELRS scan ignored final CH3=-100 Special Function override")
for _, value in ipairs(drawn_text) do
    assert(not string.find(value, "CH3 OUTPUT", 1, true),
        "final CH3=-100 was incorrectly reported as unsafe")
end
output_values[2] = nil
telemetry["ch3"] = -1024
switch_states[997] = nil

-- TX16S MK3 can temporarily reject discovery writes while the internal ELRS
-- module is starting or the ELRS tool is releasing the CRSF FIFO. Busy writes
-- must not consume the bounded scan; discovery must continue until a packet is
-- actually accepted.
local tx16_busy_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local tx16_busy_widget = tx16_busy_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
switch_states[997] = false
switch_states[10] = true
telemetry["ch3"] = -1024
telemetry["RQly"] = 0
parameters[1][3] = 0
crsf_queue = {}
discovery_busy_remaining = 4
drawn_text = {}
for _ = 1, 80 do tx16_busy_module.refresh(tx16_busy_widget, 0, nil) end
local tx16_busy_warning = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then tx16_busy_warning = true end
end
assert(discovery_busy_remaining == 0,
    "TX16S busy-discovery test did not exercise every rejected FIFO write")
assert(tx16_busy_warning,
    "TX16S ELRS mismatch was not detected after transient CRSF FIFO busy responses")
parameters[1][3] = 1
switch_states[997] = nil

-- If the radio-side TX module never answers, the bounded check must stop and
-- expose a useful on-screen transport failure instead of silently leaving the
-- pilot with an unexplained pending state.
local no_reply_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local no_reply_widget = no_reply_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN,
    StatusHelp = 1, BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
switch_states[997] = false
switch_states[10] = true
telemetry["ch3"] = -1024
telemetry["RQly"] = 0
crsf_queue = {}
discovery_busy_remaining = 1000
drawn_text = {}
for _ = 1, 180 do no_reply_module.refresh(no_reply_widget, 0, nil) end
local no_reply_visible = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS AUTO CHECK FAILED: NO ELRS TX MODULE RESPONSE" then
        no_reply_visible = true
    end
end
assert(no_reply_visible, "missing ELRS TX-module no-response diagnostic")
discovery_busy_remaining = 0
switch_states[997] = nil

local saw_timer1_label = false
local saw_timer1_value = false
local saw_hold = false
local saw_attitude = false
local saw_pilot_control = false
local saw_pilot_telemetry = false
local saw_pilot_system = false
local saw_header_model_name = false
for _, value in ipairs(drawn_text) do
    if value == "COUNTDOWN" then saw_timer1_label = true end
    if value == "03:00" then saw_timer1_value = true end
    if value == "HOLD ON" then saw_hold = true end
    if value == "ATT" then saw_attitude = true end
    if value == "CONTROL LINK" or value == "SIGNAL" then saw_pilot_control = true end
    if value == "TELEM" then saw_pilot_telemetry = true end
    if value == "SYSTEM" then saw_pilot_system = true end
    if value == mock_model_info.name then saw_header_model_name = true end
    assert(value ~= "S2 MAX", "aircraft type is redundant above the model name")
end
assert(saw_timer1_label)
assert(saw_timer1_value)
assert(saw_hold)
assert(saw_attitude)
assert(saw_pilot_control and saw_pilot_telemetry and saw_pilot_system)
assert(saw_header_model_name)

-- Battery percentage defaults to a per-cell standard-LiPo curve instead of
-- trusting the receiver's Bat% value.  3.84V/cell is the 50% curve anchor.
telemetry["RxBt"] = 11.52
telemetry["Bat%"] = 99
drawn_text = {}
widget_module.refresh(widget, 0, nil)
local saw_curve_50 = false
for _, value in ipairs(drawn_text) do
    if value == "50%" then saw_curve_50 = true end
end
assert(saw_curve_50)

-- The optional legacy source still displays the receiver-supplied percentage.
widget.options.BatteryPct = 4
drawn_text = {}
widget_module.refresh(widget, 0, nil)
local saw_sensor_99 = false
for _, value in ipairs(drawn_text) do
    if value == "99%" then saw_sensor_99 = true end
end
assert(saw_sensor_99)
widget.options.BatteryPct = 1
telemetry["RxBt"] = 12.3
telemetry["Bat%"] = 72

-- Goosky S2 MAX publishes rotor speed in CRSF GPS-altitude field GAlt
-- (sensor ID/sub-ID 0002/4). The dashboard must relabel it as RPM.
telemetry["GAlt"] = 2450
tick = tick + 600
drawn_text = {}
widget_module.refresh(widget, 0, nil)
local saw_rotor_rpm_label, saw_rotor_rpm_value = false, false
for _, value in ipairs(drawn_text) do
    if value == "ROTOR RPM" then saw_rotor_rpm_label = true end
    if value == "2450" then saw_rotor_rpm_value = true end
end
assert(saw_rotor_rpm_label and saw_rotor_rpm_value)
telemetry["GAlt"] = nil

-- A non-None function-switch type makes EdgeTX reject raw SW1-SW6 LED
-- writes. The widget must retry the same battery state and recover as soon as
-- the pilot changes all six switch types to None, without needing a reload.
reject_button_led_writes = true
for index = 20, 25 do led_colors[index] = { 0, 0, 0 } end
local led_retry_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local led_retry_widget = led_retry_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
led_retry_widget.splash_pending = false
led_retry_widget.splash_until = 0
led_retry_module.refresh(led_retry_widget, 0, nil)
for index = 20, 25 do
    assert(led_colors[index][1] == 0 and led_colors[index][2] == 0 and led_colors[index][3] == 0)
end
reject_button_led_writes = false
tick = tick + 101
led_retry_module.refresh(led_retry_widget, 0, nil)
for index = 20, 25 do
    assert(led_colors[index][2] == 190,
        "battery LED bar did not recover after SW1-SW6 changed to Type=None")
end

-- OEM capacity and correction are used by Capacity Used mode.  A reported
-- 250mAh with +10% adjustment becomes 275mAh; 475mAh remains from a 750mAh
-- S2 pack, which rounds to 63%.
telemetry["Capa"] = 250
widget.options.BatteryPct = 5
widget.options.PackCap = 0
widget.options.CapaAdj = 10
drawn_text = {}
widget_module.refresh(widget, 0, nil)
local saw_corrected_capacity = false
local saw_capacity_percent = false
for _, value in ipairs(drawn_text) do
    if value == "275mAh" then saw_corrected_capacity = true end
    if value == "63%" then saw_capacity_percent = true end
end
assert(saw_corrected_capacity and saw_capacity_percent)
widget.options.BatteryPct = 1
widget.options.CapaAdj = 0

-- The same per-cell curve must produce the same result for the S1's 2S pack.
telemetry["RxBt"] = 7.68
telemetry["Bat%"] = 1
drawn_text = {}
local s1_battery_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local s1_battery_widget = s1_battery_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 2,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 0,
    TimerReset = 0
})
s1_battery_widget.splash_pending = false
s1_battery_widget.splash_until = 0
s1_battery_module.refresh(s1_battery_widget, 0, nil)
local saw_s1_curve_50 = false
for _, value in ipairs(drawn_text) do
    if value == "50%" then saw_s1_curve_50 = true end
end
assert(saw_s1_curve_50)

-- Capacity Used mode still applies the hidden OEM capacity. With the default
-- 300mAh S1 pack, 75mAh used leaves 75%.
telemetry["Capa"] = 75
s1_battery_widget.options.BatteryPct = 5
drawn_text = {}
s1_battery_module.refresh(s1_battery_widget, 0, nil)
local saw_oem_s1_capacity = false
for _, value in ipairs(drawn_text) do
    if value == "75%" then saw_oem_s1_capacity = true end
end
assert(saw_oem_s1_capacity)

-- A nonzero PackCap overrides the selected profile's OEM capacity.
s1_battery_widget.options.PackCap = 450
telemetry["Capa"] = 225
drawn_text = {}
s1_battery_module.refresh(s1_battery_widget, 0, nil)
local saw_custom_capacity = false
for _, value in ipairs(drawn_text) do
    if value == "50%" then saw_custom_capacity = true end
end
assert(saw_custom_capacity)
telemetry["RxBt"] = 12.3
telemetry["Bat%"] = 72
telemetry["Capa"] = 250

-- Auto chemistry defaults to the OEM LiPo profile but latches LiHV after a
-- physically unambiguous reading above 4.22V/cell. The explicit LiHV choice
-- also supports packs first connected in a partially discharged state.
telemetry["RxBt"] = 13.0
drawn_text = {}
local lihv_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local lihv_widget = lihv_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 0,
    TimerReset = 0
})
lihv_module.refresh(lihv_widget, 0, nil)
assert(lihv_widget.detected_chemistry == "lihv")
telemetry["RxBt"] = 12.0
drawn_text = {}
lihv_module.refresh(lihv_widget, 0, nil)
assert(lihv_widget.detected_chemistry == "lihv")
lihv_widget.options.BatteryPct = 3
drawn_text = {}
lihv_module.refresh(lihv_widget, 0, nil)
assert(lihv_widget.options.BatteryPct == 3)
telemetry["RxBt"] = 12.3

-- Goosky pose mode is always read directly from fixed CH5.
telemetry["ch5"] = -1024
drawn_text = {}
widget_module.refresh(widget, 0, nil)
local saw_3d = false
for _, value in ipairs(drawn_text) do
    if value == "3D" then saw_3d = true end
end
assert(saw_3d)
telemetry["ch5"] = 1024

-- A configured reset switch resets both native model timers once on its rising edge.
switch_states[42] = true
local reset_widget = widget_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 0,
    TimerReset = 42
})
widget_module.refresh(reset_widget, 0, nil)
widget_module.refresh(reset_widget, 0, nil)
assert(timer1_reset_count == 1)
assert(timer2_reset_count == 1)

-- A normal preflight no-link state is not actionable and must not consume the
-- ELRS alert row.
status_flags = 0
telemetry["RQly"] = 0
-- A flat helicopter throttle curve may leave CH3 active while throttle hold
-- remains on. The warning must still appear in that safe state.
telemetry["ch3"] = 512
drawn_text = {}
local no_link_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local no_link_widget = no_link_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 0,
    TimerReset = 0
})
for _ = 1, 30 do no_link_module.refresh(no_link_widget, 0, nil) end
local no_link_hud = ""
for _, value in ipairs(drawn_text) do
    if string.find(value, "TLM", 1, true) then no_link_hud = value end
end
assert(no_link_hud == "")

-- When Model Match is disabled, no match result is displayed.
parameters[4][3] = 0
drawn_text = {}
local mm_off_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local mm_off_widget = mm_off_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 0,
    TimerReset = 0
})
for _ = 1, 30 do mm_off_module.refresh(mm_off_widget, 0, nil) end
local mm_off_hud = ""
for _, value in ipairs(drawn_text) do
    if string.find(value, "TLM", 1, true) then mm_off_hud = value end
    assert(value ~= "MODEL MATCH")
end
assert(mm_off_hud == "")

local function last_value_after(label)
    local result = nil
    for index, value in ipairs(drawn_text) do
        if value == label then result = drawn_text[index + 1] end
    end
    return result
end

-- Flight time now comes from native model Timer 2. The setup wizard applies
-- the CH3-active plus hold-released gate to both timers.
tick = 0
parameters[4][3] = 1
status_flags = 1
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
telemetry["ch3"] = 204
switch_states[10] = false
drawn_text = {}
local gate_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local gate_widget = gate_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 20 do gate_module.refresh(gate_widget, 0, nil) end
assert(last_value_after("FLIGHT TIME") == "00:00")

telemetry["ch3"] = 512
timer2_value = 20
drawn_text = {}
for _ = 1, 20 do gate_module.refresh(gate_widget, 0, nil) end
local active_time = last_value_after("FLIGHT TIME")
assert(active_time == "00:20")

switch_states[10] = true
drawn_text = {}
for _ = 1, 20 do gate_module.refresh(gate_widget, 0, nil) end
assert(last_value_after("FLIGHT TIME") == active_time)

-- A rate/mode mismatch automatically prompts, then writes only after YES.
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
parameters[1][2] = "50Hz;333Hz Full (-105dBm)"
parameters[1][3] = 0
parameters[2][3] = 0
parameters[3][2] = "Hybrid;Wide"
parameters[3][3] = 0
parameters[5][3] = 1
parameters[6][3] = 1
parameters[7][3] = 0
drawn_text = {}
local fix_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local fix_widget = fix_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 50 do fix_module.refresh(fix_widget, 0, nil) end
local saw_warning = false
local saw_yes = false
local saw_no = false
local saw_current_settings = false
local saw_recommended_settings = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then saw_warning = true end
    if string.find(value, "YES", 1, true) then saw_yes = true end
    if string.find(value, "NO", 1, true) then saw_no = true end
    if value == "CURRENT SETTINGS" then saw_current_settings = true end
    if value == "RECOMMENDED" then saw_recommended_settings = true end
end
assert(saw_warning and saw_yes and saw_no)
assert(saw_current_settings and saw_recommended_settings)

-- Once visible, the warning must remain latched even if EdgeTX subsequently
-- reports an active CH3 mixer value and a released hold source. This models a
-- Special Function keeping the transmitted output at -100 while Lua still
-- observes movement in the underlying mixer source.
fix_widget.options.HoldSwitch = 10
switch_states[10] = false
telemetry["ch3"] = 512
drawn_text = {}
fix_module.refresh(fix_widget, 0, nil)
local warning_latched = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then warning_latched = true end
end
assert(warning_latched)
switch_states[10] = true

-- The ENTER event used to launch App Mode must not immediately activate the
-- default NO selection when the dialog first appears.
fix_widget.elrs_dialog = false
fix_widget.elrs_prompt_dismissed = nil
drawn_text = {}
fix_module.refresh(fix_widget, EVT_VIRTUAL_ENTER, nil)
drawn_text = {}
fix_module.refresh(fix_widget, 0, nil)
local warning_survived_entry = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then warning_survived_entry = true end
end
assert(warning_survived_entry)

telemetry["ch3"] = -1024
for _ = 1, 5 do fix_module.refresh(fix_widget, 0, nil) end
fix_module.refresh(fix_widget, EVT_TOUCH_TAP, { x = 310, y = 349 })
for _ = 1, 220 do fix_module.refresh(fix_widget, 0, nil) end
assert(parameters[1][3] == 1)
assert(parameters[2][3] == 4)
assert(parameters[3][3] == 0)
assert(parameters[5][3] == 3)
assert(parameters[6][3] == 0)
assert(parameters[7][3] == 3)
assert(write_busy_remaining[5] == 0)
assert(write_busy_remaining[6] == 0)
assert(write_busy_remaining[7] == 0)
local saw_verified = false
local saw_original_box = false
local saw_current_box = false
for _, value in ipairs(drawn_text) do
    if value == "6 OF 6 SETTINGS MATCH" then saw_verified = true end
    if value == "ORIGINAL SETTINGS" then saw_original_box = true end
    if value == "VERIFIED CURRENT" then saw_current_box = true end
end
assert(saw_verified and saw_original_box and saw_current_box)

-- The rotary wheel can select YES and press to apply the same correction.
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
parameters[1][3] = 0
parameters[2][3] = 0
parameters[3][2] = "Hybrid;Wide"
parameters[3][3] = 0
parameters[5][3] = 1
parameters[6][3] = 1
parameters[7][3] = 0
drawn_text = {}
local wheel_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local wheel_widget = wheel_module.create({ x = 21, y = 37, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 50 do wheel_module.refresh(wheel_widget, 0, nil) end
drawn_text = {}
wheel_module.refresh(wheel_widget, EVT_VIRTUAL_PREV, nil)
local wheel_yes_highlighted = false
for _, value in ipairs(drawn_text) do
    if value == "> YES <" then wheel_yes_highlighted = true end
end
assert(wheel_yes_highlighted)
wheel_module.refresh(wheel_widget, EVT_VIRTUAL_ENTER, nil)
for _ = 1, 220 do wheel_module.refresh(wheel_widget, 0, nil) end
assert(parameters[1][3] == 1)
assert(parameters[2][3] == 4)
assert(parameters[3][3] == 0)
assert(parameters[5][3] == 3)
assert(parameters[6][3] == 0)
assert(parameters[7][3] == 3)

-- YES is blocked while a receiver is connected, and NO dismisses the prompt.
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
parameters[1][3] = 0
parameters[2][3] = 0
parameters[3][2] = "Hybrid;Wide"
parameters[3][3] = 0
parameters[5][3] = 1
parameters[6][3] = 1
parameters[7][3] = 0
drawn_text = {}
local blocked_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local blocked_widget = blocked_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1,
    SquareColor = WHITE,
    BackgroundColor = BLACK,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 50 do blocked_module.refresh(blocked_widget, 0, nil) end
-- Establish the link only after the receiver-off preflight found the mismatch.
telemetry["RQly"] = 100
blocked_module.refresh(blocked_widget, 0, nil)
blocked_module.refresh(blocked_widget, EVT_TOUCH_TAP, { x = 310, y = 349 })
for _ = 1, 5 do blocked_module.refresh(blocked_widget, 0, nil) end
assert(parameters[1][3] == 0)
assert(parameters[2][3] == 0)
local saw_power_off = false
for _, value in ipairs(drawn_text) do
    if string.find(value, "POWER OFF HELICOPTER", 1, true) then saw_power_off = true end
end
assert(saw_power_off)

-- A long touch release works, including full-screen coordinates when the
-- widget retains a non-zero dashboard-zone origin.
blocked_widget.zone.x = 21
blocked_widget.zone.y = 37
blocked_module.refresh(blocked_widget, EVT_TOUCH_BREAK, { x = 490, y = 349 })
drawn_text = {}
for _ = 1, 5 do blocked_module.refresh(blocked_widget, 0, nil) end
local warning_returned = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then warning_returned = true end
end
assert(not warning_returned)

-- Long-pressing outside a dialog exits App Mode for native widget settings.
parameters[1][3] = 1
parameters[2][3] = 4
parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
parameters[3][3] = 0
parameters[5][3] = 3
parameters[6][3] = 0
parameters[7][3] = 3
local exits_before = fullscreen_exit_count
blocked_module.refresh(blocked_widget, EVT_TOUCH_BREAK, { x = 700, y = 420 })
assert(fullscreen_exit_count == exits_before + 1)

-- Native 480x320 layout used by the RadioMaster TX15/GX15 class. Every
-- primitive must remain within the physical screen and all dashboard groups
-- present on the 800x480 layout must still be rendered.
-- This mock also reproduces the TX15 transport behavior: discovery from 0xEA
-- succeeds, but every local ELRS parameter/status request must come from 0xEF.
LCD_W = 480
LCD_H = 320
strict_screen_bounds = true
require_elrs_lua_address = true
saw_elrs_lua_address = false
rejected_legacy_local_address = 0
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
telemetry["RxBt"] = 12.3
telemetry["Capa"] = 250
parameters[1][2] = "50Hz;333Hz Full (-105dBm)"
parameters[1][3] = 1
parameters[2][3] = 4
parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
parameters[3][3] = 0
parameters[5][3] = 3
parameters[6][3] = 0
parameters[7][3] = 3
drawn_text = {}
local compact_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local compact_widget = compact_module.create({ x = 0, y = 0, w = 480, h = 320 }, {
    Aircraft = 1,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
compact_widget.splash_pending = false
compact_widget.splash_until = 0
-- TX15 App Mode may supply nil instead of zero while idle. Its full-size zone
-- must still render the dashboard and never show the App Mode warning.
compact_module.refresh(compact_widget, nil, nil)
local compact_nil_event_dashboard_seen = false
for _, value in ipairs(drawn_text) do
    if value == "Goosky S2 MAX" then compact_nil_event_dashboard_seen = true end
    assert(value ~= "APP MODE REQUIRED")
end
assert(compact_nil_event_dashboard_seen)
for _ = 1, 35 do compact_module.refresh(compact_widget, 0, nil) end
telemetry["RQly"] = 100
compact_module.refresh(compact_widget, 0, nil)
for index = 0, 19 do
    assert(led_colors[index][1] == 0 and led_colors[index][2] == 190 and led_colors[index][3] == 0)
end
local compact_expected = {
    ["Goosky S2 MAX"] = false,
    ["FLIGHT BATTERY"] = false,
    ["FLT"] = false,
    ["T1"] = false,
    ["ELRS LINK"] = false,
    ["SIGNAL"] = false,
    ["QUALITY"] = false,
    ["TELEM"] = false,
    ["MATCH"] = false,
    ["CURRENT"] = false,
    ["POWER"] = false,
    ["MAX POWER"] = false,
    ["THROTTLE"] = false,
    ["HOLD ON"] = false
}
local compact_hud = ""
for _, value in ipairs(drawn_text) do
    if compact_expected[value] ~= nil then compact_expected[value] = true end
    if string.find(value, "333", 1, true) and string.find(value, "1:32", 1, true) then compact_hud = value end
    assert(value ~= "1RSS" and value ~= "2RSS" and value ~= "TRSS" and value ~= "TQly")
    assert(value ~= "LP 3S/12.60V/750mAh")
end
for label, seen in pairs(compact_expected) do
    assert(seen, "missing 480x320 dashboard value: " .. label)
end
assert(compact_hud == "")
assert(saw_elrs_lua_address, "TX15 ELRS scan never switched to CRSF address 0xEF")
assert(rejected_legacy_local_address == 0, "TX15 ELRS scan used legacy 0xEA after discovery")

-- A single-antenna receiver may publish a permanent zero for 2RSS. It must be
-- shown as unavailable and must not lower the combined health state.
telemetry["2RSS"] = 0
compact_widget.options.StatusHelp = 3
drawn_text = {}
compact_module.refresh(compact_widget, 0, nil)
local saw_second_rssi_na = false
for _, value in ipairs(drawn_text) do
    if value == "---" then saw_second_rssi_na = true end
end
assert(saw_second_rssi_na)
for index = 0, LED_STRIP_LENGTH - 1 do
    assert(led_colors[index][1] == 0 and led_colors[index][2] == 0 and led_colors[index][3] == 0)
end
compact_widget.options.StatusHelp = 1
telemetry["2RSS"] = -47

-- A telemetry-ratio-only mismatch must trigger the compact 480x320 warning.
-- NO must dismiss it without triggering a settings write.
tick = 0
status_flags = 0
telemetry["RQly"] = 0
parameters[1][3] = 1
parameters[2][3] = 0
parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
parameters[3][3] = 0
parameters[5][3] = 3
parameters[6][3] = 0
drawn_text = {}
local compact_dialog_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local compact_dialog_widget = compact_dialog_module.create({ x = 0, y = 0, w = 480, h = 320 }, {
    Aircraft = 1,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 50 do compact_dialog_module.refresh(compact_dialog_widget, 0, nil) end
local compact_warning_seen = false
for _, value in ipairs(drawn_text) do
    if value == "ELRS SETTINGS MISMATCH" then compact_warning_seen = true end
end
assert(compact_warning_seen)
compact_dialog_module.refresh(compact_dialog_widget, EVT_TOUCH_TAP, { x = 330, y = 250 })
drawn_text = {}
compact_dialog_module.refresh(compact_dialog_widget, 0, nil)
for _, value in ipairs(drawn_text) do
    assert(value ~= "ELRS SETTINGS MISMATCH")
end

-- This compact widget was online earlier, so a later loss must display the
-- complete OFFLINE word using the fitted small font inside its cell.
local offline_fit_before = offline_small_font_count
telemetry["RQly"] = 0
telemetry["TQly"] = 0
compact_module.refresh(compact_widget, 0, nil)
assert(offline_small_font_count > offline_fit_before)
strict_screen_bounds = false
LCD_W = 800
LCD_H = 480

-- A non-Gemini transmitter may not expose Antenna Mode at all. The five core
-- settings must still complete normally instead of reporting an incomplete
-- scan or attempting a nonexistent sixth write.
antenna_parameter_available = false
require_elrs_lua_address = false
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
switch_states[10] = true
switch_states[997] = false
parameters[1][3] = 1
parameters[2][3] = 4
parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
parameters[3][3] = 0
parameters[5][3] = 3
parameters[6][3] = 0
drawn_text = {}
local no_antenna_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local no_antenna_widget = no_antenna_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 1, SquareColor = WHITE, BackgroundColor = BLACK,
    ValueColor = GREEN, StatusHelp = 1, BankSwitch = 0,
    HoldSwitch = 10, TimerReset = 0
})
for _ = 1, 60 do no_antenna_module.refresh(no_antenna_widget, 0, nil) end
for _, value in ipairs(drawn_text) do
    assert(value ~= "ELRS SETTINGS MISMATCH")
    assert(not string.find(value, "ELRS READ INCOMPLETE", 1, true))
    assert(value ~= "ANTENNA")
end
antenna_parameter_available = true

-- A linked receiver with a new model but no discovered telemetry sensors must
-- be neutral: native TELE proves the link, while absent sensor definitions
-- request discovery without yellow LEDs, haptics, or ELRS-check warnings.
local saved_get_field_info = getFieldInfo
getFieldInfo = function(_) return nil end
switch_states[997] = true
drawn_text = {}
local undiscovered_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local undiscovered_widget = undiscovered_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
local undiscovered_haptics = #haptic_calls
local undiscovered_pushes, undiscovered_pops = crsf_push_count, crsf_pop_count
for _ = 1, 10 do undiscovered_module.refresh(undiscovered_widget, 0, nil) end
local saw_discover = false
for _, value in ipairs(drawn_text) do
    if value == "DISCOVER" then saw_discover = true end
    assert(value ~= "ELRS CHECK IN PROGRESS")
end
assert(saw_discover)
assert(#haptic_calls == undiscovered_haptics)
assert(crsf_push_count == undiscovered_pushes and crsf_pop_count == undiscovered_pops)
for index = 0, 19 do
    assert(led_colors[index][1] == 190 and led_colors[index][2] == 190 and led_colors[index][3] == 190)
end
getFieldInfo = saved_get_field_info
switch_states[997] = nil

-- Per-model switch captures written by GooskySetup fill blank native widget
-- options. Verify BANK, HOLD and RESET are consumed by the dashboard.
local saved_io_open, saved_io_read, saved_io_close = io.open, io.read, io.close
local dashboard_auto_handle = {}
io.open = function(path, mode)
    if path == "/SCRIPTS/TOOLS/NERC_GSkyFD_goosky-s2_yml.cfg" and mode == "r" then
        return dashboard_auto_handle
    end
    return saved_io_open(path, mode)
end
io.read = function(file, size)
    if file == dashboard_auto_handle then
        assert(size == 2048)
        return "version=1\nbank_source=202\nbank_name=SB\nhold_switch=813\nreset_switch=413\n"
    end
    return saved_io_read(file, size)
end
io.close = function(file)
    if file == dashboard_auto_handle then return true end
    return saved_io_close(file)
end
telemetry[202] = -1024
telemetry["RQly"], telemetry["TQly"], telemetry["RxBt"], telemetry["ch3"] = 100, 100, 12.3, 0
switch_states[813], switch_states[413] = false, true
drawn_text = {}
local auto_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local auto_widget = auto_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
local auto_reset_before = timer1_reset_count
auto_module.refresh(auto_widget, 0, nil)
local saw_auto_hold_release = false
for _, value in ipairs(drawn_text) do
    if value == "THR IDLE" then saw_auto_hold_release = true end
end
assert(auto_widget.auto_switches.bank_source == 202)
assert(auto_widget.options.BankSwitch == 202
    and auto_widget.options.HoldSwitch == 813
    and auto_widget.options.TimerReset == 413,
    "replacement widget did not recover BANK/HOLD/RESET into blank options")
assert(saw_auto_hold_release)
assert(timer1_reset_count == auto_reset_before + 1)

-- A later nonblank native option must override the imported setup capture.
telemetry[202], telemetry[203] = 1024, -1024
switch_states[813], switch_states[413] = false, false
switch_states[814], switch_states[414] = true, true
drawn_text = {}
local override_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local override_widget = override_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 203, HoldSwitch = 814, TimerReset = 414
})
local override_reset_before = timer1_reset_count
override_module.refresh(override_widget, 0, nil)
local saw_native_hold = false
local saw_native_bank = false
for _, value in ipairs(drawn_text) do
    if value == "HOLD ON" then saw_native_hold = true end
    if value == "1" then saw_native_bank = true end
end
assert(saw_native_hold)
assert(saw_native_bank)
assert(timer1_reset_count == override_reset_before + 1)
io.open, io.read, io.close = saved_io_open, saved_io_read, saved_io_close
telemetry[202], telemetry[203] = nil, nil
switch_states[813], switch_states[413] = nil, nil
switch_states[814], switch_states[414] = nil, nil

-- A missing HOLD mapping must never masquerade as HOLD ON. It must block all
-- CRSF activity and state the exact gate on-screen so a real-radio report can
-- distinguish configuration, channel, telemetry, and signal gating.
switch_states[997] = false
telemetry["RQly"], telemetry["TQly"], telemetry["RxBt"] = 0, 0, 0
telemetry["ch3"] = -1024
drawn_text = {}
local missing_hold_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local missing_hold_widget = missing_hold_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, BackgroundColor = BLACK, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
local missing_hold_pushes, missing_hold_pops = crsf_push_count, crsf_pop_count
missing_hold_module.refresh(missing_hold_widget, 0, nil)
local saw_hold_not_set, saw_hold_gate = false, false
for _, value in ipairs(drawn_text) do
    if value == "HOLD NOT SET" then saw_hold_not_set = true end
    if value == "ELRS AUTO CHECK BLOCKED: HOLD NOT CONFIGURED" then saw_hold_gate = true end
end
assert(saw_hold_not_set, "unconfigured HOLD was not shown truthfully")
assert(saw_hold_gate, "unconfigured HOLD gate was not identified on-screen")
assert(crsf_push_count == missing_hold_pushes and crsf_pop_count == missing_hold_pops,
    "ELRS traffic ran without a configured HOLD source")
switch_states[997] = nil

-- Bench use starts neutral. Until RQly has been valid once, missing receiver,
-- telemetry, and battery data must show compact neutral dashes in white with
-- no haptic alarm.
tick = 0
status_flags = 0
telemetry["RQly"] = 0
telemetry["TQly"] = 0
telemetry["RxBt"] = 0
parameters[1][3] = 1
parameters[2][3] = 4
parameters[3][3] = 0
parameters[5][3] = 3
parameters[6][3] = 0
drawn_text = {}
local neutral_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local neutral_widget = neutral_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 10, TimerReset = 0
})
local neutral_haptics_before = #haptic_calls
for _ = 1, 20 do neutral_module.refresh(neutral_widget, 0, nil) end
local saw_waiting = false
for _, value in ipairs(drawn_text) do
    if value == "---" then saw_waiting = true end
    assert(value ~= "WAITING" and value ~= "WAIT" and value ~= "N/A")
    assert(value ~= "OFFLINE")
    assert(not string.find(value, "CAUTION:", 1, true))
end
assert(saw_waiting)
assert(#haptic_calls == neutral_haptics_before)
for index = 0, 19 do
    assert(led_colors[index][1] == 190 and led_colors[index][2] == 190 and led_colors[index][3] == 190)
end
for index = 20, 25 do
    assert(led_colors[index][1] == 0 and led_colors[index][2] == 0 and led_colors[index][3] == 0,
        "SW1-SW6 must remain off before battery telemetry is established")
end

-- Once a valid link has existed, losing it must change from neutral to the
-- normal warning path and trigger haptic feedback.
telemetry["RQly"] = 100
telemetry["TQly"] = 100
telemetry["RxBt"] = 12.3
neutral_module.refresh(neutral_widget, 0, nil)
drawn_text = {}
local linked_haptics_before = #haptic_calls
telemetry["RQly"] = 0
telemetry["TQly"] = 0
telemetry["RxBt"] = 0
neutral_module.refresh(neutral_widget, 0, nil)
local saw_offline_after_link = false
for _, value in ipairs(drawn_text) do
    if value == "OFFLINE" then saw_offline_after_link = true end
end
assert(saw_offline_after_link)
assert(#haptic_calls > linked_haptics_before)

-- With HOLD on and TELE offline, the configured RESET switch acknowledges the
-- completed flight. It must clear the remembered receiver session and silence
-- all repeating offline haptics until the receiver links again.
neutral_widget.options.TimerReset = 88
switch_states[88] = false
neutral_module.refresh(neutral_widget, 0, nil)
switch_states[88] = true
drawn_text = {}
neutral_module.refresh(neutral_widget, 0, nil)
local acknowledged_haptics = #haptic_calls
for _ = 1, 40 do neutral_module.refresh(neutral_widget, 0, nil) end
local reset_returned_to_bench = false
for _, value in ipairs(drawn_text) do
    if value == "---" then reset_returned_to_bench = true end
    assert(value ~= "OFFLINE")
    assert(not string.find(value, "RECEIVER OFFLINE", 1, true))
end
assert(reset_returned_to_bench)
assert(#haptic_calls == acknowledged_haptics,
    "offline haptics repeated after RESET acknowledged the completed flight")

-- The acknowledgement is not a permanent mute. A new link re-arms receiver
-- loss protection for the next flight.
switch_states[88] = false
telemetry["RQly"] = 100
telemetry["TQly"] = 100
telemetry["RxBt"] = 12.3
neutral_module.refresh(neutral_widget, 0, nil)
local rearmed_haptics = #haptic_calls
telemetry["RQly"] = 0
telemetry["TQly"] = 0
telemetry["RxBt"] = 0
neutral_module.refresh(neutral_widget, 0, nil)
assert(#haptic_calls > rearmed_haptics,
    "receiver reconnect did not re-arm the offline haptic alarm")
switch_states[88] = nil

-- Companion simulation mode loads a separate backend from the simulated SD
-- card. It must visibly identify synthetic data and complete ELRS discovery
-- without using the real Crossfire functions.
tick = 0
drawn_text = {}
switch_states[10] = true
switch_states[997] = false
telemetry["RQly"] = 0
telemetry["ch3"] = -1024
function loadScript(path)
    if string.find(path, "simulator.lua", 1, true) then
        return loadfile("dev/simulator.lua")
    end
    return nil
end
local visual_sim_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local visual_sim_widget = visual_sim_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3,
    BatteryPct = 1,
    PackCap = 0,
    CapaAdj = 0,
    SquareColor = WHITE,
    ValueColor = GREEN,
    StatusHelp = 1,
    BankSwitch = 0,
    HoldSwitch = 10,
    TimerReset = 0
})
for _ = 1, 25 do visual_sim_module.refresh(visual_sim_widget, 0, nil) end
local saw_sim_marker = false
local saw_sim_elrs = false
for _, value in ipairs(drawn_text) do
    if string.find(value, "SIM:", 1, true) == 1 then saw_sim_marker = true end
    if value == "MODEL MATCH" or value == "MATCH" then saw_sim_elrs = true end
end
assert(saw_sim_marker, "Companion simulator telemetry marker was not drawn")
assert(saw_sim_elrs, "Companion simulator ELRS backend did not complete discovery")

-- The dashboard must follow the native EdgeTX model bitmap written by
-- GooskySetup. Changing Purple -> Blue -> Orange must invalidate the cache;
-- wide radios use dashboard-sized assets and compact radios use /IMAGES.
local saved_color_name = mock_model_info.name
local saved_color_bitmap = mock_model_info.bitmap
mock_model_info.name = "S2 MAX Purple"
mock_model_info.bitmap = "GKS2PU.png"
local color_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local color_widget = color_module.create({ x = 0, y = 0, w = 800, h = 480 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
color_module.refresh(color_widget, 0, nil)
assert(bitmap_open_paths[#bitmap_open_paths] == "/IMAGES/GKS2PU_800.png")
mock_model_info.name = "S2 MAX Blue"
mock_model_info.bitmap = "GKS2BL.png"
color_module.refresh(color_widget, 0, nil)
assert(bitmap_open_paths[#bitmap_open_paths] == "/IMAGES/GKS2BL_800.png")
local saved_color_lcd_w, saved_color_lcd_h = LCD_W, LCD_H
LCD_W, LCD_H = 480, 320
local compact_color_module = dofile("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
local compact_color_widget = compact_color_module.create({ x = 0, y = 0, w = 480, h = 320 }, {
    Aircraft = 3, BatteryPct = 1, PackCap = 0, CapaAdj = 0,
    SquareColor = WHITE, ValueColor = GREEN, StatusHelp = 1,
    BankSwitch = 0, HoldSwitch = 0, TimerReset = 0
})
compact_color_module.refresh(compact_color_widget, 0, nil)
assert(bitmap_open_paths[#bitmap_open_paths] == "/IMAGES/GKS2BL.png")
mock_model_info.name = "S2 MAX Orange"
mock_model_info.bitmap = "GKS2OR.png"
compact_color_module.refresh(compact_color_widget, 0, nil)
assert(bitmap_open_paths[#bitmap_open_paths] == "/IMAGES/GKS2OR.png")
LCD_W, LCD_H = saved_color_lcd_w, saved_color_lcd_h
mock_model_info.name = saved_color_name
mock_model_info.bitmap = saved_color_bitmap
print("EdgeTX mock refresh OK: " .. last_hud)

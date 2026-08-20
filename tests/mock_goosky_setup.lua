LCD_W, LCD_H = 800, 480
WHITE, BLACK, GREEN, RED, CUSTOM_COLOR = 1, 2, 3, 4, 5
BOLD, CENTER, RIGHT, SMLSIZE = 8, 16, 32, 64
EVT_VIRTUAL_PREV, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_ENTER = 1, 2, 3
EVT_VIRTUAL_EXIT, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 4, 5, 6
LS_FUNC_VPOS, LS_FUNC_AND, FUNC_RESET, FUNC_OVERRIDE_CHANNEL = 3, 9, 4, 5
FUNC_BACKLIGHT, FUNC_VOLUME = 6, 7
FUNC_LOGS = 8
FUNC_PLAY_TRACK = 9

local setup_drawn_text = {}
local setup_drawn_bitmaps = {}
local setup_strict_bounds = false

lcd = {
    RGB = function(r, g, b) return r * 65536 + g * 256 + b end,
    setColor = function(...) end,
    drawFilledRectangle = function(x, y, w, h, ...)
        if setup_strict_bounds then
            assert(x >= 0 and y >= 0 and w >= 0 and h >= 0)
            assert(x + w <= LCD_W and y + h <= LCD_H)
        end
    end,
    drawRectangle = function(x, y, w, h, ...)
        if setup_strict_bounds then
            assert(x >= 0 and y >= 0 and w >= 0 and h >= 0)
            assert(x + w <= LCD_W and y + h <= LCD_H)
        end
    end,
    drawText = function(x, y, value, flags)
        assert((flags & CUSTOM_COLOR) ~= 0, "setup text must use the selected custom color")
        if setup_strict_bounds then assert(x >= 0 and x <= LCD_W and y >= 0 and y <= LCD_H) end
        setup_drawn_text[#setup_drawn_text + 1] = tostring(value)
    end,
    drawBitmap = function(bitmap, x, y)
        if setup_strict_bounds then assert(x >= 0 and y >= 0) end
        setup_drawn_bitmaps[#setup_drawn_bitmaps + 1] = tostring(bitmap)
    end
}

local config_lines = {
    "version=1",
    "filename=goosky.yml",
    "model_name=Goosky",
    "aircraft=2",
    "bank_source=301",
    "bank_name=SB",
    "hold_switch=420",
    "reset_switch=430"
}

local real_open = io.open
local real_read = io.read
local real_write = io.write
local real_close = io.close
local config_available = true
local config_handle = {}
local auto_written = {}
io.open = function(path, mode)
    if (string.find(path, "/WIDGETS/NERC_GSkyFD/auto_", 1, true) == 1
        or string.find(path, "/SCRIPTS/TOOLS/NERC_GSkyFD_", 1, true) == 1)
        and mode == "w" then
        return { auto_path = path }
    end
    if path ~= "/WIDGETS/NERC_GSkyFD/setup.cfg" or mode ~= "r" then
        return real_open(path, mode)
    end
    if not config_available then return nil end
    return config_handle
end
io.read = function(file, size)
    if file == config_handle then
        assert(size == 4096)
        return table.concat(config_lines, "\n") .. "\n"
    end
    return real_read(file, size)
end
io.write = function(file, value)
    if type(file) == "table" and file.auto_path then
        auto_written[file.auto_path] = tostring(value)
        return file
    end
    return real_write(file, value)
end
io.close = function(file)
    if file == config_handle then return true end
    if type(file) == "table" and file.auto_path then return true end
    return real_close(file)
end

local source_ids = {
    ail = 1, ele = 2, thr = 3, rud = 4, max = 5, ch3 = 103,
    s1 = 111, s2 = 112,
    sa = 201, sb = 202, sc = 203, sd = 204, se = 205,
    sf = 206, sg = 207, sh = 208
}
for index = 1, 6 do source_ids["sw" .. tostring(index)] = 500 + index end

local physical_switch_values = {
    sa = -1024, sb = -1024, sc = -1024, sd = -1024, se = -1024,
    sf = -1024, sg = -1024, sh = -1024
}

function getValue(name)
    return physical_switch_values[string.lower(name)] or 0
end

function getFieldInfo(name)
    local id = source_ids[string.lower(name)]
    return id and { id = id } or nil
end

function getSourceName(index)
    if index == 301 then return "SB" end
    return nil
end

function getSourceIndex(name)
    return source_ids[string.lower(name)] or 0
end

function getSwitchInfo(index)
    if index >= 501 and index <= 506 then
        return { type = 0, isCustomisableSwitch = true, name = "SW" .. tostring(index - 500) }
    end
    return nil
end

function getSwitchName(index) return "SW" .. tostring(index) end
function getSwitchIndex(name)
    local up, down = "\194\130", "\194\131"
    local known = {
        ["SB" .. up] = 311, ["SB-"] = 312, ["SB" .. down] = 313,
        ["SA" .. up] = 211, ["SA-"] = 212, ["SA" .. down] = 213,
        ["SC" .. up] = 411, ["SC-"] = 412, ["SC" .. down] = 413,
        ["SH" .. up] = 811, ["SH-"] = 812, ["SH" .. down] = 813,
        ["L01"] = 900, ["L1"] = 900, ["L02"] = 901, ["L2"] = 901,
        ["TELE"] = 998, ["ON"] = 999
    }
    return known[name] or 0
end

local calls = {
    curves = {}, mixes = {}, outputs = {}, timers = {}, logical = {},
    custom = {}, modules = {}, warnings = {}, deleted = {}, flight_modes = {}, info = nil
}

model = {
    getInfo = function() return { name = "Goosky", filename = "goosky.yml", bitmap = "" } end,
    setInfo = function(value) calls.info = value end,
    deleteMixes = function(channel) calls.deleted[channel] = true end,
    setCurve = function(index, value) calls.curves[index] = value; return 0 end,
    insertMix = function(channel, line, value)
        calls.mixes[channel] = calls.mixes[channel] or {}
        calls.mixes[channel][line] = value
    end,
    setOutput = function(channel, value) calls.outputs[channel] = value end,
    setLogicalSwitch = function(index, value) calls.logical[index] = value end,
    setSwitchWarning = function(name, value) calls.warnings[name] = value end,
    setTimer = function(index, value) calls.timers[index] = value end,
    setCustomFunction = function(index, value) calls.custom[index] = value end,
    setModule = function(index, value) calls.modules[index] = value end,
    setFlightMode = function(index, value)
        local stored = { trimsValues = {}, trimsModes = {} }
        for trim = 1, 4 do
            stored.trimsValues[trim] = value.trimsValues[trim]
            stored.trimsModes[trim] = value.trimsModes[trim]
        end
        calls.flight_modes[index] = stored
        return 0
    end,
    getFlightMode = function(index)
        return calls.flight_modes[index]
            or { trimsValues = { 0, 0, 0, 0 }, trimsModes = { 0, 0, 0, 0 } }
    end
}

local wizard = dofile("SDCARD/SCRIPTS/TOOLS/GooskySetup.lua")
wizard.init()

-- Even a stale widget handoff containing previous switch assignments must not
-- preselect them. Every setup run starts with all four switch fields blank.
setup_drawn_text = {}
wizard.run(0, nil)
assert(setup_drawn_bitmaps[1]
    and string.find(setup_drawn_bitmaps[1], "brand_goosky_800.png", 1, true))
assert(setup_drawn_bitmaps[2]
    and string.find(setup_drawn_bitmaps[2], "brand_nerc_800.png", 1, true))
local blank_bank, blank_hold, blank_reset = false, false, false
for _, value in ipairs(setup_drawn_text) do
    if value == "BANK  NOT SET" then blank_bank = true end
    if value == "HOLD  NOT SET" then blank_hold = true end
    if value == "RESET  NOT SET" then blank_reset = true end
end
assert(blank_bank and blank_hold and blank_reset,
    "GooskySetup inherited default/stale switch assignments")
setup_drawn_text = {}

-- The last physical switch movement automatically selects both ATT switch and
-- final position. Exercise a three-position transition and finish at DOWN.
wizard.run(EVT_VIRTUAL_NEXT, nil)
wizard.run(EVT_VIRTUAL_NEXT, nil)
physical_switch_values.sa = 0
wizard.run(0, nil)
physical_switch_values.sa = 1024
wizard.run(0, nil)

-- Capture BANK, HOLD and RESET from the bottom cells. The currently selected
-- cell receives the next physical switch movement and its final position.
wizard.run(EVT_VIRTUAL_NEXT, nil) -- Timer
wizard.run(EVT_VIRTUAL_ENTER, nil) -- Edit Timer 1
wizard.run(EVT_VIRTUAL_NEXT, nil) -- +30 seconds
wizard.run(EVT_VIRTUAL_PREV, nil) -- -30 seconds
wizard.run(EVT_VIRTUAL_ENTER, nil) -- Finish timer edit
wizard.run(EVT_VIRTUAL_NEXT, nil) -- Bank
physical_switch_values.sb = 0
wizard.run(0, nil)
wizard.run(EVT_VIRTUAL_NEXT, nil) -- Hold
physical_switch_values.sh = 1024
wizard.run(0, nil)
-- A momentary HOLD immediately springs back. The release must not overwrite
-- the first captured (active) position.
physical_switch_values.sh = -1024
wizard.run(0, nil)
wizard.run(EVT_VIRTUAL_NEXT, nil) -- Reset
physical_switch_values.sc = 1024
wizard.run(0, nil)
-- RESET is tested as a one-refresh pulse too.
physical_switch_values.sc = -1024
wizard.run(0, nil)
wizard.run(EVT_VIRTUAL_NEXT, nil) -- Apply
wizard.run(EVT_VIRTUAL_ENTER, nil)
wizard.run(EVT_VIRTUAL_NEXT, nil)
wizard.run(EVT_VIRTUAL_ENTER, nil)

for channel = 0, 5 do assert(calls.deleted[channel]) end
assert(calls.curves[0].y[1] == -100 and calls.curves[0].y[2] == 25)
assert(calls.curves[1].y[1] == 35 and calls.curves[2].y[1] == 45)
assert(calls.mixes[2][0].name == "Bank 1")
assert(calls.mixes[2][1].switch == 312)
assert(calls.mixes[2][2].switch == 313)
assert(calls.info.jitterFilter == 1, "setup must force the model ADC filter off")
for index = 1, 6 do
    assert(calls.warnings["SW" .. tostring(index)] == 0,
        "setup must disable SW1-SW6 model prestart warnings")
end
assert(calls.mixes[2][3] == nil)
assert(calls.mixes[4][0].weight == -100 and calls.mixes[4][1].weight == 100)
assert(calls.mixes[4][1].switch == 213)
assert(calls.mixes[5][0].source == source_ids.thr)
for _, channel_mixes in pairs(calls.mixes) do
    for _, mix in pairs(channel_mixes) do
        assert(mix.carryTrim == false, "all generated mixer lines must have Trim OFF")
    end
end
for flight_mode = 0, 8 do
    local mode = calls.flight_modes[flight_mode]
    assert(mode, "setup must configure trim state in every flight mode")
    for trim = 1, 4 do
        assert(mode.trimsValues[trim] == 0,
            "setup must clear existing trim values in every flight mode")
        assert(mode.trimsModes[trim] == 31,
            "setup must disable every physical trim key in every flight mode")
    end
end
assert(calls.logical[0].v1 == source_ids.ch3)
assert(calls.logical[0].v2 == 20)
assert(calls.logical[0]["and"] == 0)
assert(calls.logical[1].func == LS_FUNC_AND)
assert(calls.logical[1].v1 == 900 and calls.logical[1].v2 == 998)
assert(calls.logical[1]["and"] == -813)
assert(calls.timers[0].mode == 901 and calls.timers[0].start == 300)
assert(calls.timers[1].mode == 901 and calls.timers[1].start == 0)
assert(calls.custom[0].switch == 813)
assert(calls.custom[0].func == FUNC_OVERRIDE_CHANNEL)
assert(calls.custom[0].param == 2 and calls.custom[0].value == -100 and calls.custom[0].mode == 0 and calls.custom[0].active == 1)
assert(calls.custom[1].switch == 413 and calls.custom[1].value == 0)
assert(calls.custom[2].switch == 413 and calls.custom[2].value == 1)
assert(calls.custom[3].switch == 999 and calls.custom[3].func == FUNC_BACKLIGHT and calls.custom[3].value == source_ids.s1)
assert(calls.custom[4].switch == 999 and calls.custom[4].func == FUNC_VOLUME and calls.custom[4].value == source_ids.s2)
assert(calls.custom[5].switch == 998 and calls.custom[5].func == FUNC_LOGS)
assert(calls.custom[5].param == 10 and calls.custom[5].active == 1)
local voice_expected = {
    [6] = { switch = 813, name = "thrhld" },
    [7] = { switch = -813, name = "thract" },
    [8] = { switch = 311, name = "bank-1" },
    [9] = { switch = 312, name = "bank-2" },
    [10] = { switch = 313, name = "bank-3" },
    [11] = { switch = -213, name = "3d-mod" },
    [12] = { switch = 213, name = "sxrstb" },
    [13] = { switch = 413, name = "timrs1" }
}
for index, expected in pairs(voice_expected) do
    local actual = calls.custom[index]
    assert(actual and actual.func == FUNC_PLAY_TRACK)
    assert(actual.switch == expected.switch and actual.name == expected.name)
    assert(actual.repetition == -1 and actual.active == 1)
end
assert(calls.modules[0].Type == 5 and calls.modules[0].channelsCount == 8)
assert(calls.info.name == "S1 V2 Orange")
assert(calls.info.bitmap == "GKS1OR.png")
local saved_auto = auto_written["/SCRIPTS/TOOLS/NERC_GSkyFD_goosky_yml.cfg"] or ""
local saved_auto_by_name = auto_written["/SCRIPTS/TOOLS/NERC_GSkyFD_s1_v2_orange.cfg"] or ""
assert(string.find(saved_auto, "bank_source=202", 1, true))
assert(string.find(saved_auto, "bank_name=SB", 1, true))
assert(string.find(saved_auto, "hold_switch=813", 1, true))
assert(string.find(saved_auto, "reset_switch=413", 1, true))
assert(saved_auto_by_name == saved_auto,
    "dashboard switch settings were not saved under the model-name fallback")
assert(auto_written["/WIDGETS/NERC_GSkyFD/auto_goosky_yml.cfg"] == saved_auto,
    "legacy widget-folder switch capture was not retained for compatibility")

-- The completion page is a short, ordered, safety-critical manual checklist.
-- These two EdgeTX fields are not writable through the Lua model API.
setup_drawn_text = {}
wizard.run(0, nil)
local result_expected = {
    ["MANUAL STEPS REQUIRED"] = false,
    ["DO NOT FLY UNTIL BOTH STEPS ARE COMPLETE"] = false,
    ["SET SW1-SW6 TYPE TO NONE"] = false,
    ["MDL > CUSTOMIZABLE SWITCHES"] = false,
    ["CONNECT HELICOPTER"] = false,
    ["MDL > TELEMETRY > DISCOVER NEW"] = false,
    ["TRIM KEYS ARE DISABLED IN ALL FLIGHT MODES"] = false
}
for _, value in ipairs(setup_drawn_text) do
    if result_expected[value] ~= nil then result_expected[value] = true end
end
for value, seen in pairs(result_expected) do
    assert(seen, "missing mandatory completion instruction: " .. value)
end

-- If the widget has not been added/configured/refreshed, the setup tool must
-- show a readable, explicit recovery sequence instead of a low-contrast error.
config_available = false
setup_drawn_text = {}
local blocked_wizard = dofile("SDCARD/SCRIPTS/TOOLS/GooskySetup.lua")
blocked_wizard.init()
blocked_wizard.run(0, nil)
local blocked_expected = {
    ["SETUP REQUIRED"] = false,
    ["The dashboard has not saved its setup yet."] = false,
    ["1. Add NERC Goosky FlightDeck to Display."] = false,
    ["2. Select App mode and open the dashboard once."] = false,
    ["3. Rerun this tool; switches are detected here."] = false
}
for _, value in ipairs(setup_drawn_text) do
    if blocked_expected[value] ~= nil then blocked_expected[value] = true end
end
for value, seen in pairs(blocked_expected) do
    assert(seen, "missing blocked-setup instruction: " .. value)
end


-- The professional setup layout, switch cells, lower APPLY button and motor
-- warning must all stay within the TX15/GX15 480x320 screen.
LCD_W, LCD_H = 480, 320
setup_strict_bounds = true
config_available = true
local compact_wizard = dofile("SDCARD/SCRIPTS/TOOLS/GooskySetup.lua")
compact_wizard.init()
for _ = 1, 7 do compact_wizard.run(EVT_VIRTUAL_NEXT, nil) end
compact_wizard.run(0, nil)
setup_strict_bounds = false

print("Goosky setup wizard mock OK")

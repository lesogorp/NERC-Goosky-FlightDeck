-- Goosky S1 V2 / S2 MAX model setup wizard for EdgeTX 2.12 color radios.
-- Configures the CURRENT model only.  Keep the motor disconnected while using.

local CFG_PATH = "/WIDGETS/NERC_GSkyFD/setup.cfg"
local AUTO_CFG_PREFIX = "/SCRIPTS/TOOLS/NERC_GSkyFD_"
local LEGACY_AUTO_CFG_PREFIX = "/WIDGETS/NERC_GSkyFD/auto_"
local BRAND_PATH = "/WIDGETS/NERC_GSkyFD/"

local aircraft_values = { "S1 V2", "S2 MAX" }
local color_values = { "Orange", "Blue", "Purple" }
local countdown_values = {}
for seconds = 30, 1200, 30 do countdown_values[#countdown_values + 1] = seconds end
local image_names = {
    { "GKS1OR.png", "GKS1BL.png", "GKS1PU.png" },
    { "GKS2OR.png", "GKS2BL.png", "GKS2PU.png" }
}

local state = {
    page = "setup",
    row = 1,
    editing = false,
    confirm_yes = false,
    aircraft = 1,
    color = 1,
    pose_name = nil,
    pose_position = nil,
    -- Five-minute default; every wheel/touch adjustment is a clear 30 seconds.
    countdown = 10,
    pose_sources = {},
    pose_snapshot = {},
    bank_display = "NOT SET",
    hold_display = "NOT SET",
    reset_display = "NOT SET",
    capture_latched = {},
    switch_warnings_off = false,
    function_leds_ready = nil,
    config = {},
    error = nil,
    result = nil
}

-- High-contrast setup theme: black surfaces, white information, and red only
-- for selection, confirmation, and safety emphasis.
local theme = {
    background = { 0, 0, 0 },
    header = { 204, 32, 30 },
    panel = { 8, 8, 8 },
    panel_alt = { 24, 24, 24 },
    cyan = { 245, 245, 245 },
    selected = { 125, 0, 0 },
    green = { 255, 255, 255 },
    orange = { 220, 0, 0 },
    yellow = { 255, 255, 255 },
    muted = { 145, 145, 145 },
    red = { 220, 0, 0 }
}

local brand_logos = {}

local function get_brand_logo(name)
    if brand_logos[name] == false then return nil end
    if brand_logos[name] ~= nil then return brand_logos[name] end
    brand_logos[name] = false
    if type(Bitmap) ~= "table" or type(Bitmap.open) ~= "function"
        or type(fstat) ~= "function" or type(lcd.drawBitmap) ~= "function" then return nil end
    local suffix = LCD_W >= 700 and "_800.png" or ".png"
    local filename = "brand_" .. name .. suffix
    local path = BRAND_PATH .. filename
    if not fstat(path) then return nil end
    local ok, bitmap = pcall(Bitmap.open, path)
    if ok and bitmap then brand_logos[name] = bitmap end
    return brand_logos[name] or nil
end

local function set_theme_color(name)
    local color = theme[name]
    lcd.setColor(CUSTOM_COLOR, lcd.RGB(color[1], color[2], color[3]))
end

local function event_is(event, value)
    return type(value) == "number" and event == value
end

local function clean(value)
    return string.gsub(tostring(value or ""), "[\r\n]", "")
end

local function load_widget_config()
    local config = {}
    local file = io and io.open and io.open(CFG_PATH, "r") or nil
    if not file then return nil, "Configure this widget on the current model first." end
    local contents = io.read(file, 4096) or ""
    io.close(file)
    for line in string.gmatch(contents, "[^\r\n]+") do
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        if key then config[key] = value end
    end
    config.aircraft = tonumber(config.aircraft) or 1
    -- Switches are never inherited from widget options or a previous run.
    -- Every model setup must explicitly capture BANK, HOLD, RESET and ATT.
    config.bank_source = 0
    config.bank_name = ""
    config.hold_switch = 0
    config.reset_switch = 0
    return config
end

local function source_exists(name)
    if type(getFieldInfo) ~= "function" then return false end
    local info = getFieldInfo(string.lower(name))
    return info and info.id ~= nil
end

local function read_physical_switch(name)
    if type(getValue) ~= "function" then return nil end
    local value = getValue(string.lower(name))
    if type(value) ~= "number" then return nil end
    return value
end

local function pose_position_from_value(value)
    -- EdgeTX switch sources are approximately -1024 at the up position,
    -- zero in the middle, and +1024 at the down position.
    if value < -512 then return "up" end
    if value > 512 then return "down" end
    return "mid"
end

local function position_display(position)
    if position == "mid" then return "MIDDLE" end
    return string.upper(position or "")
end

local function snapshot_pose_switches()
    state.pose_snapshot = {}
    for _, name in ipairs(state.pose_sources) do
        state.pose_snapshot[name] = read_physical_switch(name)
    end
end

local function build_pose_sources()
    state.pose_sources = {}
    for _, name in ipairs({ "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "SI", "SJ" }) do
        if source_exists(name) then state.pose_sources[#state.pose_sources + 1] = name end
    end
    if #state.pose_sources == 0 then
        state.pose_sources = { "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH" }
    end
    snapshot_pose_switches()
end

local source_index
local switch_position

local function capture_pose_switch()
    local captured_name = nil
    local captured_value = nil
    for _, name in ipairs(state.pose_sources) do
        local current = read_physical_switch(name)
        local previous = state.pose_snapshot[name]
        if current ~= nil and previous ~= nil and math.abs(current - previous) > 256 then
            captured_name = name
            captured_value = current
        end
        state.pose_snapshot[name] = current
    end
    if not captured_name then return end

    -- HOLD and RESET are often momentary switches. Latch their first detected
    -- movement so the immediate spring-return edge cannot overwrite the
    -- active position before the user advances to the next setup field.
    if (state.row == 6 or state.row == 7) and state.capture_latched[state.row] then
        return
    end

    local position = pose_position_from_value(captured_value)
    if state.row == 3 then
        state.pose_name = captured_name
        state.pose_position = position
    elseif state.row == 5 then
        state.config.bank_name = captured_name
        state.config.bank_source = source_index(captured_name)
        state.bank_display = captured_name
    elseif state.row == 6 then
        state.config.hold_switch = switch_position(captured_name, position)
        state.hold_display = captured_name .. " " .. position_display(position)
        state.capture_latched[6] = true
    elseif state.row == 7 then
        state.config.reset_switch = switch_position(captured_name, position)
        state.reset_display = captured_name .. " " .. position_display(position)
        state.capture_latched[7] = true
    end
end

local function validate_config()
    local config, err = load_widget_config()
    if not config then return nil, err end
    local info = model.getInfo and model.getInfo() or {}
    if config.filename ~= "" and info.filename and info.filename ~= "" and config.filename ~= info.filename then
        return nil, "Widget settings belong to a different model."
    end
    return config
end

local function field_id(name)
    local info = getFieldInfo and getFieldInfo(name)
    if not info or info.id == nil then error("Missing EdgeTX source: " .. name) end
    return info.id
end

source_index = function(name)
    local index = type(getSourceIndex) == "function" and getSourceIndex(name) or 0
    if index and index ~= 0 then return index end
    return field_id(string.lower(name))
end

switch_position = function(name, position)
    if type(getSwitchIndex) ~= "function" then error("getSwitchIndex unavailable") end
    -- getSwitchIndex expects the same two-byte arrow glyphs EdgeTX renders in
    -- its switch menus. CHAR_UP/CHAR_DOWN are not guaranteed Lua globals and
    -- CHAR_MID does not exist, so use EdgeTX's stable encoded names directly.
    local suffix = position == "up" and "\194\130"
        or (position == "mid" and "-" or "\194\131")
    local index = getSwitchIndex(name .. suffix)
    if not index or index == 0 then error("Cannot resolve " .. name .. " " .. position) end
    return index
end

local function model_config_key(info)
    local raw = type(info) == "table" and (info.filename or info.name) or "model"
    local key = string.lower(clean(raw))
    key = string.gsub(key, "[^%w_-]", "_")
    if key == "" then key = "model" end
    return key
end

local function save_dashboard_switches(info)
    local content = table.concat({
        "version=1",
        "bank_source=" .. tostring(state.config.bank_source or 0),
        "bank_name=" .. clean(state.config.bank_name),
        "hold_switch=" .. tostring(state.config.hold_switch or 0),
        "reset_switch=" .. tostring(state.config.reset_switch or 0),
        ""
    }, "\n")
    local path = AUTO_CFG_PREFIX .. model_config_key(info) .. ".cfg"
    local name_path = AUTO_CFG_PREFIX
        .. model_config_key({ name = info and info.name or "model" }) .. ".cfg"
    local legacy_path = LEGACY_AUTO_CFG_PREFIX .. model_config_key(info) .. ".cfg"
    local legacy_name_path = LEGACY_AUTO_CFG_PREFIX
        .. model_config_key({ name = info and info.name or "model" }) .. ".cfg"

    local function write_switch_config(candidate)
        local file = io and io.open and io.open(candidate, "w") or nil
        if not file then error("Cannot save dashboard switch settings") end
        io.write(file, content)
        io.close(file)
    end

    -- Save by both immutable model filename and visible model name. Some
    -- EdgeTX builds briefly omit filename while recreating a deleted widget;
    -- the name-keyed copy lets the dashboard recover the same switch map.
    write_switch_config(path)
    if name_path ~= path then write_switch_config(name_path) end
    -- Keep compatibility with installed earlier widget builds while new builds
    -- use the durable copy under /SCRIPTS/TOOLS.
    write_switch_config(legacy_path)
    if legacy_name_path ~= legacy_path then write_switch_config(legacy_name_path) end
end

local function clear_channel(channel)
    if model.deleteMixes then
        model.deleteMixes(channel)
        return
    end
    if not model.getMixesCount or not model.deleteMix then error("Mix delete API unavailable") end
    for line = model.getMixesCount(channel) - 1, 0, -1 do model.deleteMix(channel, line) end
end

local function disable_function_switch_warnings()
    if not model or type(model.setSwitchWarning) ~= "function" then return false end
    for index = 1, 6 do
        local ok = pcall(model.setSwitchWarning, "SW" .. tostring(index), 0)
        if not ok then return false end
    end
    return true
end

local function function_switch_leds_ready()
    if type(getSourceIndex) ~= "function" or type(getSwitchInfo) ~= "function" then
        return nil
    end
    local found = 0
    for index = 1, 6 do
        local source = getSourceIndex("SW" .. tostring(index))
        if source and source ~= 0 then
            local info = getSwitchInfo(source)
            if type(info) == "table" and info.isCustomisableSwitch then
                found = found + 1
                if tonumber(info.type) ~= 0 then return false end
            end
        end
    end
    return found == 6
end

-- EdgeTX stores trim enable/link state independently for every flight mode.
-- carryTrim=false on a mixer prevents a trim offset reaching that mix, but it
-- does not stop the physical trim keys from changing the stored trim value.
-- Mode 31 is EdgeTX TRIM_MODE_NONE: the trim is visibly Off and its keys do
-- nothing. Apply it to every trim in every flight mode and verify the write.
local TRIM_MODE_NONE = 31
local FLIGHT_MODE_COUNT = 9

local function disable_all_trims()
    if not model or type(model.setFlightMode) ~= "function"
        or type(model.getFlightMode) ~= "function" then
        error("This EdgeTX build cannot disable the trim keys")
    end

    -- Six entries cover every current color-radio trim layout. EdgeTX ignores
    -- entries beyond the number of trims supported by the radio.
    local trim_values = { 0, 0, 0, 0, 0, 0 }
    local trim_modes = {
        TRIM_MODE_NONE, TRIM_MODE_NONE, TRIM_MODE_NONE,
        TRIM_MODE_NONE, TRIM_MODE_NONE, TRIM_MODE_NONE
    }
    for flight_mode = 0, FLIGHT_MODE_COUNT - 1 do
        local result = model.setFlightMode(flight_mode, {
            trimsValues = trim_values,
            trimsModes = trim_modes
        })
        if result ~= 0 then
            error("Cannot disable trims in flight mode " .. tostring(flight_mode))
        end
    end

    for flight_mode = 0, FLIGHT_MODE_COUNT - 1 do
        local info = model.getFlightMode(flight_mode)
        if type(info) ~= "table" or type(info.trimsModes) ~= "table"
            or #info.trimsModes == 0 then
            error("Cannot verify trims in flight mode " .. tostring(flight_mode))
        end
        for _, mode in ipairs(info.trimsModes) do
            if tonumber(mode) ~= TRIM_MODE_NONE then
                error("Trim keys remain enabled in flight mode " .. tostring(flight_mode))
            end
        end
    end
end

local function apply_model()
    local config = state.config
    local bank_name = clean(config.bank_name)
    local bank_up = switch_position(bank_name, "up")
    local bank_mid = switch_position(bank_name, "mid")
    local bank_down = switch_position(bank_name, "down")
    local hold_switch = config.hold_switch
    local reset_switch = config.reset_switch
    if not state.pose_name or not state.pose_position then
        error("Move the ATT switch to its desired position first")
    end
    local pose_switch = switch_position(state.pose_name, state.pose_position)
    local logical_timer = getSwitchIndex("L01") or getSwitchIndex("L1")
    if not logical_timer or logical_timer == 0 then error("Cannot resolve logical switch L01") end
    -- Logical-switch source IDs are contiguous in EdgeTX. L02 is the final
    -- flight-condition gate consumed by both native timers.
    local logical_flight = logical_timer + 1

    local src_ail = field_id("ail")
    local src_ele = field_id("ele")
    local src_thr = field_id("thr")
    local src_rud = field_id("rud")
    local src_max = field_id("max")
    local src_ch3 = field_id("ch3")
    local src_s1 = source_index("S1")
    local src_s2 = source_index("S2")
    local always_on = getSwitchIndex("ON")
    if not always_on or always_on == 0 then error("Cannot resolve the ON switch") end
    local telemetry_on = 0
    for _, name in ipairs({ "TELE", "Telemetry", "TELEM" }) do
        local candidate = getSwitchIndex(name)
        if candidate and candidate ~= 0 then
            telemetry_on = candidate
            break
        end
    end
    if telemetry_on == 0 then error("Cannot resolve the EdgeTX TELE switch") end
    if type(FUNC_LOGS) ~= "number" then error("This EdgeTX build does not expose SD Logs") end
    if type(FUNC_PLAY_TRACK) ~= "number" then error("This EdgeTX build does not expose Play Track") end

    for channel = 0, 5 do clear_channel(channel) end

    -- User-approved Goosky curves. Curves 2 and 3 are flat bank speeds.
    assert(model.setCurve(0, { name = "THR1", y = { -100, 25, 25, 25, 25 } }) == 0)
    assert(model.setCurve(1, { name = "THR2", y = { 35, 35, 35, 35, 35 } }) == 0)
    assert(model.setCurve(2, { name = "THR3", y = { 45, 45, 45, 45, 45 } }) == 0)

    -- Flight-controller models must never receive transmitter trim offsets.
    -- carryTrim=false makes every generated mixer line explicitly Trim OFF.
    model.insertMix(0, 0, { source = src_ail, name = "Aileron", weight = 100, carryTrim = false })
    model.insertMix(1, 0, { source = src_ele, name = "Elevator", weight = 100, carryTrim = false })
    model.insertMix(2, 0, { source = src_thr, name = "Bank 1", weight = 100, carryTrim = false, curveType = 3, curveValue = 1 })
    model.insertMix(2, 1, { source = src_thr, name = "Bank 2", weight = 100, carryTrim = false, switch = bank_mid, multiplex = 2, curveType = 3, curveValue = 2 })
    model.insertMix(2, 2, { source = src_thr, name = "Bank 3", weight = 100, carryTrim = false, switch = bank_down, multiplex = 2, curveType = 3, curveValue = 3 })
    model.insertMix(3, 0, { source = src_rud, name = "Rudder", weight = 100, carryTrim = false })
    model.insertMix(4, 0, { source = src_max, name = "3D", weight = -100, carryTrim = false })
    model.insertMix(4, 1, { source = src_max, name = "ATT", weight = 100, carryTrim = false, switch = pose_switch, multiplex = 2 })
    model.insertMix(5, 0, { source = src_thr, name = "Collective", weight = 100, carryTrim = false })

    -- This second layer disables the physical trim keys themselves in FM0-8
    -- and clears any trim values that may already exist in the current model.
    disable_all_trims()

    for channel, name in ipairs({ "AIL", "ELE", "MOTOR", "RUD", "POSE", "PITCH" }) do
        model.setOutput(channel - 1, { name = name })
    end

    -- L01 detects commanded motor throttle. L02 is the final flight condition:
    -- throttle active, receiver telemetry connected, and HOLD released. Keep
    -- HOLD as an explicit switch gate because a special-function CH3 override
    -- occurs too late in EdgeTX processing to be a reliable timer input.
    model.setLogicalSwitch(0, {
        func = LS_FUNC_VPOS,
        v1 = src_ch3,
        v2 = 20,
        ["and"] = 0,
        delay = 0,
        duration = 0
    })
    model.setLogicalSwitch(1, {
        func = LS_FUNC_AND,
        v1 = logical_timer,
        v2 = telemetry_on,
        ["and"] = -hold_switch,
        delay = 0,
        duration = 0
    })

    local seconds = countdown_values[state.countdown]
    model.setTimer(0, {
        mode = logical_flight,
        start = seconds,
        value = seconds,
        countdownBeep = 2,
        minuteBeep = false,
        persistent = 0,
        name = "LIMIT"
    })
    model.setTimer(1, {
        mode = logical_flight,
        start = 0,
        value = 0,
        countdownBeep = 0,
        minuteBeep = false,
        persistent = 0,
        name = "FLIGHT"
    })

    -- Make throttle hold independent of mixer order by overriding the final
    -- CH3 output.  EdgeTX custom-function channel indexes are zero based.
    model.setCustomFunction(0, {
        switch = hold_switch,
        func = FUNC_OVERRIDE_CHANNEL,
        param = 2,
        value = -100,
        mode = 0,
        active = 1
    })

    -- Reset both native timers from the user-captured RESET position.
    model.setCustomFunction(1, { switch = reset_switch, func = FUNC_RESET, param = 0, value = 0, mode = 0, active = 1 })
    model.setCustomFunction(2, { switch = reset_switch, func = FUNC_RESET, param = 0, value = 1, mode = 0, active = 1 })

    -- Consistent radio ergonomics for every generated Goosky model.
    model.setCustomFunction(3, { switch = always_on, func = FUNC_BACKLIGHT, param = 0, value = src_s1, mode = 0, active = 1 })
    model.setCustomFunction(4, { switch = always_on, func = FUNC_VOLUME, param = 0, value = src_s2, mode = 0, active = 1 })
    -- Native EdgeTX telemetry-streaming condition. FUNC_LOGS stores its
    -- interval in 100 ms units, so param=10 records one row per second.
    model.setCustomFunction(5, { switch = telemetry_on, func = FUNC_LOGS, param = 10, value = 0, mode = 0, active = 1 })

    -- Standard EdgeTX 2.12 voice-pack tracks. repetition=-1 is !1x: announce
    -- only after a real switch transition, not merely because that switch
    -- state was already active when the model loaded.
    local function set_voice_alert(index, switch, track)
        model.setCustomFunction(index, {
            switch = switch,
            func = FUNC_PLAY_TRACK,
            name = track,
            repetition = -1,
            active = 1
        })
    end
    set_voice_alert(6, hold_switch, "thrhld")
    set_voice_alert(7, -hold_switch, "thract")
    set_voice_alert(8, bank_up, "bank-1")
    set_voice_alert(9, bank_mid, "bank-2")
    set_voice_alert(10, bank_down, "bank-3")
    set_voice_alert(11, -pose_switch, "3d-mod")
    set_voice_alert(12, pose_switch, "sxrstb")
    set_voice_alert(13, reset_switch, "timrs1")

    -- TX16S MK3, TX15 and GX15 use the internal CRSF/ExpressLRS module.
    model.setModule(0, { Type = 5, firstChannel = 0, channelsCount = 8 })

    local color = color_values[state.color]
    local info = model.getInfo()
    info.name = (state.aircraft == 1 and "S1 V2 " or "S2 MAX ") .. color
    info.bitmap = image_names[state.aircraft][state.color]
    -- EdgeTX model setting values are: 0=Global, 1=Off, 2=On. Force the
    -- per-model ADC filter override off so a radio-wide setting cannot add
    -- unwanted control latency to this flight-controller model.
    info.jitterFilter = 1
    model.setInfo(info)
    state.switch_warnings_off = disable_function_switch_warnings()
    state.function_leds_ready = function_switch_leds_ready()
    save_dashboard_switches(info)
end

local function selected_values()
    local pose_value = "MOVE SWITCH TO ATT"
    if state.pose_name and state.pose_position then
        pose_value = state.pose_name .. " " .. string.upper(state.pose_position)
    end
    return {
        aircraft_values[state.aircraft],
        color_values[state.color],
        pose_value,
        string.format("%d:%02d", math.floor(countdown_values[state.countdown] / 60), countdown_values[state.countdown] % 60)
    }
end

local function change_value(direction)
    if state.row == 1 then
        state.aircraft = ((state.aircraft - 1 + direction) % #aircraft_values) + 1
    elseif state.row == 2 then
        state.color = ((state.color - 1 + direction) % #color_values) + 1
    elseif state.row == 4 then
        state.countdown = math.max(1, math.min(#countdown_values, state.countdown + direction))
    end
end

local function draw_text(x, y, value, flags)
    -- EdgeTX does not use the color selected by lcd.setColor unless the
    -- CUSTOM_COLOR flag is also supplied to the text primitive.
    lcd.drawText(x, y, value, (flags or 0) + CUSTOM_COLOR)
end

local function draw_header(title)
    local header_h = math.floor(LCD_H * 0.14)
    set_theme_color("background")
    lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, CUSTOM_COLOR)
    set_theme_color("header")
    lcd.drawFilledRectangle(0, 0, LCD_W, header_h, CUSTOM_COLOR)
    set_theme_color("cyan")
    lcd.drawFilledRectangle(0, header_h - 3, LCD_W, 2, CUSTOM_COLOR)
    set_theme_color("orange")
    lcd.drawFilledRectangle(0, header_h - 1, LCD_W, 2, CUSTOM_COLOR)

    local wide = LCD_W >= 700
    local goosky = get_brand_logo("goosky")
    local nerc = get_brand_logo("nerc")
    local goosky_w, goosky_h = wide and 72 or 48, wide and 48 or 32
    local nerc_w, nerc_h = wide and 58 or 39, wide and 48 or 32
    local side_pad = wide and 10 or 6
    if goosky then
        lcd.drawBitmap(goosky, side_pad, math.max(1, math.floor((header_h - goosky_h) / 2)))
    end
    if nerc then
        lcd.drawBitmap(nerc, LCD_W - nerc_w - side_pad,
            math.max(1, math.floor((header_h - nerc_h) / 2)))
    end

    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.035), title, CENTER + BOLD)
end

local function setup_geometry()
    local geometry = {
        top = math.floor(LCD_H * 0.18),
        row_h = math.floor(LCD_H * 0.10),
        left = math.floor(LCD_W * 0.06),
        width = math.floor(LCD_W * 0.88)
    }
    geometry.status_y = geometry.top + 4 * geometry.row_h + 3
    geometry.status_h = math.max(26, math.floor(LCD_H * 0.09))
    geometry.gap = math.max(3, math.floor(LCD_W * 0.008))
    geometry.cell_w = math.floor((geometry.width - geometry.gap * 2) / 3)
    geometry.apply_y = geometry.status_y + geometry.status_h + geometry.gap
    geometry.apply_h = geometry.row_h - 3
    return geometry
end

local function draw_setup()
    draw_header("Goosky Model Setup")
    local labels = { "Aircraft", "Color", "ATT switch / position", "Timer 1 limit" }
    local values = selected_values()
    local geometry = setup_geometry()
    local top, row_h = geometry.top, geometry.row_h
    local left, width = geometry.left, geometry.width

    for row = 1, #labels do
        local y = top + (row - 1) * row_h
        set_theme_color(row % 2 == 0 and "panel_alt" or "panel")
        lcd.drawFilledRectangle(left, y, width, row_h - 3, CUSTOM_COLOR)
        if row == state.row then
            set_theme_color(state.editing and "orange" or "selected")
            lcd.drawFilledRectangle(left, y, width, row_h - 3, CUSTOM_COLOR)
        end
        set_theme_color(row == state.row and "cyan" or "muted")
        lcd.drawRectangle(left, y, width, row_h - 3, CUSTOM_COLOR)
        lcd.setColor(CUSTOM_COLOR, WHITE)
        draw_text(left + 10, y + math.floor(row_h * 0.22), labels[row], SMLSIZE)
        if row <= 4 then
            set_theme_color(row == 3 and not state.pose_name and "yellow" or "green")
            local value_text
            if row == 3 then
                value_text = values[row]
            elseif row == 4 then
                value_text = "-30s   " .. values[row] .. "   +30s"
            else
                value_text = "<  " .. values[row] .. "  >"
            end
            draw_text(left + width - 10, y + math.floor(row_h * 0.22), value_text, RIGHT + SMLSIZE)
        end
    end

    -- Select one of these equal cells, then move the desired physical switch.
    local status_y, status_h = geometry.status_y, geometry.status_h
    local gap, cell_w = geometry.gap, geometry.cell_w
    local status_values = {
        "BANK  " .. state.bank_display,
        "HOLD  " .. state.hold_display,
        "RESET  " .. state.reset_display
    }
    for index = 1, 3 do
        local x = left + (index - 1) * (cell_w + gap)
        local selected = state.row == index + 4
        set_theme_color(selected and "selected" or "panel_alt")
        lcd.drawFilledRectangle(x, status_y, cell_w, status_h, CUSTOM_COLOR)
        set_theme_color(selected and "orange" or "cyan")
        lcd.drawRectangle(x, status_y, cell_w, status_h, CUSTOM_COLOR)
        set_theme_color(string.find(status_values[index], "NOT SET", 1, true) and "yellow" or "green")
        draw_text(x + cell_w / 2, status_y + math.floor(status_h * 0.24),
            status_values[index], CENTER + SMLSIZE)
    end

    -- APPLY is deliberately one level below the three switch assignments.
    set_theme_color(state.row == 8 and "selected" or "panel")
    lcd.drawFilledRectangle(left, geometry.apply_y, width, geometry.apply_h, CUSTOM_COLOR)
    set_theme_color(state.row == 8 and "orange" or "cyan")
    lcd.drawRectangle(left, geometry.apply_y, width, geometry.apply_h, CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(LCD_W / 2, geometry.apply_y + math.floor(geometry.apply_h * 0.22),
        "APPLY TO MODEL", CENTER + BOLD)

    set_theme_color("yellow")
    draw_text(LCD_W / 2, geometry.apply_y + geometry.apply_h + math.max(7, math.floor(LCD_H * 0.018)),
        "MOTOR MUST BE DISCONNECTED", CENTER + BOLD)
end

local function draw_error()
    draw_header("Goosky Setup Blocked")
    local left = math.floor(LCD_W * 0.05)
    local top = math.floor(LCD_H * 0.19)
    local width = LCD_W - left * 2
    local height = math.floor(LCD_H * 0.62)
    local banner_h = math.max(30, math.floor(LCD_H * 0.11))

    set_theme_color("panel")
    lcd.drawFilledRectangle(left, top, width, height, CUSTOM_COLOR)
    set_theme_color("red")
    lcd.drawRectangle(left, top, width, height, CUSTOM_COLOR)
    lcd.drawFilledRectangle(left, top, width, banner_h, CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(LCD_W / 2, top + math.floor(banner_h * 0.24),
        "SETUP REQUIRED", CENTER + BOLD)

    local missing_widget = state.error == "Configure this widget on the current model first."
    lcd.setColor(CUSTOM_COLOR, WHITE)
    if missing_widget then
        draw_text(LCD_W / 2, top + banner_h + math.floor(LCD_H * 0.055),
            "The dashboard has not saved its setup yet.", CENTER + BOLD)
        draw_text(left + 16, top + banner_h + math.floor(LCD_H * 0.16),
            "1. Add NERC Goosky FlightDeck to Display.", SMLSIZE)
        draw_text(left + 16, top + banner_h + math.floor(LCD_H * 0.24),
            "2. Select App mode and open the dashboard once.", SMLSIZE)
        draw_text(left + 16, top + banner_h + math.floor(LCD_H * 0.32),
            "3. Rerun this tool; switches are detected here.", SMLSIZE)
    else
        draw_text(LCD_W / 2, top + banner_h + math.floor(LCD_H * 0.075),
            clean(state.error or "Unknown setup error"), CENTER + BOLD)
        draw_text(LCD_W / 2, top + banner_h + math.floor(LCD_H * 0.22),
            "Correct the dashboard widget settings,", CENTER + SMLSIZE)
        draw_text(LCD_W / 2, top + banner_h + math.floor(LCD_H * 0.30),
            "open the dashboard once, then rerun this tool.", CENTER + SMLSIZE)
    end

    set_theme_color("muted")
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.88), "EXIT to close", CENTER + SMLSIZE)
end

local function draw_confirm()
    draw_header("CONFIRM MODEL CHANGES")
    set_theme_color("yellow")
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.22), "Overwrites CH1-6, curves, L01-2, SF1-14 and timers 1-2.", CENTER + SMLSIZE)
    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.34), aircraft_values[state.aircraft] .. " / " .. color_values[state.color], CENTER + BOLD)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.40), "ATT: " .. state.pose_name .. " " .. string.upper(state.pose_position), CENTER + SMLSIZE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.44), "CH3: -100/25 | 35 | 45   HOLD: -100   ALL TRIMS OFF", CENTER + SMLSIZE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.49), "BANK " .. state.bank_display .. " | HOLD " .. state.hold_display .. " | RESET " .. state.reset_display, CENTER + SMLSIZE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.55), "Timers require CH3 >20%, HOLD released, and TELE connected.", CENTER + SMLSIZE)

    local y = math.floor(LCD_H * 0.68)
    local w = math.floor(LCD_W * 0.30)
    local h = math.floor(LCD_H * 0.14)
    local no_x = math.floor(LCD_W * 0.16)
    local yes_x = LCD_W - no_x - w
    set_theme_color(state.confirm_yes and "panel_alt" or "selected")
    lcd.drawFilledRectangle(no_x, y, w, h, CUSTOM_COLOR)
    set_theme_color(state.confirm_yes and "selected" or "panel_alt")
    lcd.drawFilledRectangle(yes_x, y, w, h, CUSTOM_COLOR)
    set_theme_color("cyan")
    lcd.drawRectangle(no_x, y, w, h, CUSTOM_COLOR)
    lcd.drawRectangle(yes_x, y, w, h, CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(no_x + w / 2, y + h / 3, "NO", CENTER + BOLD)
    draw_text(yes_x + w / 2, y + h / 3, "YES", CENTER + BOLD)
end

local function draw_result()
    if state.result ~= "ok" then
        draw_header("SETUP FAILED")
        set_theme_color("red")
        draw_text(LCD_W / 2, math.floor(LCD_H * 0.34), clean(state.error), CENTER + BOLD)
        lcd.setColor(CUSTOM_COLOR, WHITE)
        draw_text(LCD_W / 2, math.floor(LCD_H * 0.50),
            "The model may be partially changed. Review it before use.", CENTER + SMLSIZE)
        draw_text(LCD_W / 2, math.floor(LCD_H * 0.80), "EXIT to close", CENTER + SMLSIZE)
        return
    end

    draw_header("MANUAL STEPS REQUIRED")
    set_theme_color("red")
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.17),
        "DO NOT FLY UNTIL BOTH STEPS ARE COMPLETE", CENTER + BOLD)

    local left = math.floor(LCD_W * 0.05)
    local width = math.floor(LCD_W * 0.90)
    local badge_w = math.max(44, math.floor(LCD_W * 0.10))
    local panel_h = math.floor(LCD_H * 0.22)
    local first_y = math.floor(LCD_H * 0.27)
    local second_y = math.floor(LCD_H * 0.53)

    local function draw_required_step(y, number, title, path, note)
        set_theme_color("panel")
        lcd.drawFilledRectangle(left, y, width, panel_h, CUSTOM_COLOR)
        set_theme_color("red")
        lcd.drawRectangle(left, y, width, panel_h, CUSTOM_COLOR)
        lcd.drawFilledRectangle(left, y, badge_w, panel_h, CUSTOM_COLOR)
        lcd.setColor(CUSTOM_COLOR, WHITE)
        draw_text(left + badge_w / 2, y + math.floor(panel_h * 0.28),
            tostring(number), CENTER + BOLD)
        draw_text(left + badge_w + 12, y + math.floor(panel_h * 0.12),
            title, BOLD)
        draw_text(left + badge_w + 12, y + math.floor(panel_h * 0.44),
            path, SMLSIZE)
        set_theme_color("muted")
        draw_text(left + badge_w + 12, y + math.floor(panel_h * 0.69),
            note, SMLSIZE)
    end

    draw_required_step(first_y, 1, "SET SW1-SW6 TYPE TO NONE",
        "MDL > CUSTOMIZABLE SWITCHES", "Complete this before connecting the helicopter")
    draw_required_step(second_y, 2, "CONNECT HELICOPTER",
        "MDL > TELEMETRY > DISCOVER NEW", "Wait until all telemetry sensors appear")

    lcd.setColor(CUSTOM_COLOR, WHITE)
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.82),
        "TRIM KEYS ARE DISABLED IN ALL FLIGHT MODES", CENTER + SMLSIZE)
    set_theme_color("muted")
    draw_text(LCD_W / 2, math.floor(LCD_H * 0.90), "EXIT to close", CENTER + SMLSIZE)
end

local function init()
    build_pose_sources()
    local config, err = validate_config()
    if not config then
        state.page = "error"
        state.error = err
        return
    end
    state.config = config
    state.bank_display = "NOT SET"
    state.hold_display = "NOT SET"
    state.reset_display = "NOT SET"
    if config.aircraft == 2 then state.aircraft = 1
    elseif config.aircraft == 3 then state.aircraft = 2 end
end

local function touch_row(touch)
    if not touch then return nil end
    local x = touch.x or touch.startX
    local y = touch.y or touch.startY
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local geometry = setup_geometry()
    if y >= geometry.top and y < geometry.top + 4 * geometry.row_h then
        return math.floor((y - geometry.top) / geometry.row_h) + 1
    end
    if y >= geometry.status_y and y <= geometry.status_y + geometry.status_h then
        for index = 1, 3 do
            local cell_x = geometry.left + (index - 1) * (geometry.cell_w + geometry.gap)
            if x >= cell_x and x <= cell_x + geometry.cell_w then return index + 4 end
        end
    end
    if y >= geometry.apply_y and y <= geometry.apply_y + geometry.apply_h then return 8 end
    return nil
end

local function open_confirmation()
    if not state.pose_name or not state.pose_position then
        state.row = 3
        state.editing = false
        return
    end
    if not state.config.bank_source or state.config.bank_source == 0
        or clean(state.config.bank_name) == "" then state.row = 5; return end
    if not state.config.hold_switch or state.config.hold_switch == 0 then state.row = 6; return end
    if not state.config.reset_switch or state.config.reset_switch == 0 then state.row = 7; return end
    state.page = "confirm"
    state.confirm_yes = false
end

local function handle_setup(event, touch)
    local previous = event_is(event, EVT_VIRTUAL_PREV) or event_is(event, EVT_ROT_LEFT)
    local next_event = event_is(event, EVT_VIRTUAL_NEXT) or event_is(event, EVT_ROT_RIGHT)
    local enter = event_is(event, EVT_VIRTUAL_ENTER) or event_is(event, EVT_ENTER_FIRST) or event_is(event, EVT_ENTER_BREAK)
    if previous then
        if state.editing then
            change_value(-1)
        else
            local old_row = state.row
            state.row = math.max(1, state.row - 1)
            if state.row ~= old_row and (state.row == 6 or state.row == 7) then
                state.capture_latched[state.row] = false
                snapshot_pose_switches()
            end
        end
    elseif next_event then
        if state.editing then
            change_value(1)
        else
            local old_row = state.row
            state.row = math.min(8, state.row + 1)
            if state.row ~= old_row and (state.row == 6 or state.row == 7) then
                state.capture_latched[state.row] = false
                snapshot_pose_switches()
            end
        end
    elseif enter then
        if state.row == 8 then open_confirmation()
        elseif state.row == 3 or (state.row >= 5 and state.row <= 7) then
            if state.row == 3 then state.pose_name, state.pose_position = nil, nil
            elseif state.row == 5 then
                state.config.bank_source, state.config.bank_name = 0, ""
                state.bank_display = "NOT SET"
            elseif state.row == 6 then
                state.config.hold_switch = 0
                state.hold_display = "NOT SET"
                state.capture_latched[6] = false
            else
                state.config.reset_switch = 0
                state.reset_display = "NOT SET"
                state.capture_latched[7] = false
            end
            snapshot_pose_switches()
            state.editing = false
        elseif state.row == 1 or state.row == 2 or state.row == 4 then
            state.editing = not state.editing
        end
    end

    if touch and (event_is(event, EVT_TOUCH_TAP) or event_is(event, EVT_TOUCH_BREAK)) then
        local row = touch_row(touch)
        if row then
            if row == 8 then open_confirmation()
            else
                state.row = row
                if row == 6 or row == 7 then state.capture_latched[row] = false end
                local x = touch.x or touch.startX or LCD_W / 2
                if row == 1 or row == 2 or row == 4 then
                    local split = row == 4 and LCD_W * 0.50 or LCD_W * 0.70
                    change_value(x < split and -1 or 1)
                else
                    snapshot_pose_switches()
                end
            end
        end
    end
end

local function handle_confirm(event, touch)
    if event_is(event, EVT_VIRTUAL_PREV) or event_is(event, EVT_VIRTUAL_NEXT) or event_is(event, EVT_ROT_LEFT) or event_is(event, EVT_ROT_RIGHT) then
        state.confirm_yes = not state.confirm_yes
    end
    if touch and (event_is(event, EVT_TOUCH_TAP) or event_is(event, EVT_TOUCH_BREAK)) then
        local x = touch.x or touch.startX or 0
        local y = touch.y or touch.startY or 0
        if y >= LCD_H * 0.65 then state.confirm_yes = x > LCD_W / 2 end
    end
    if event_is(event, EVT_VIRTUAL_ENTER) or event_is(event, EVT_ENTER_FIRST) or event_is(event, EVT_ENTER_BREAK) or (touch and event_is(event, EVT_TOUCH_TAP)) then
        if not state.confirm_yes then state.page = "setup"; return end
        local ok, err = pcall(apply_model)
        if ok then state.result = "ok" else state.result = "failed"; state.error = err end
        state.page = "result"
    end
end

local function run(event, touch)
    if event_is(event, EVT_VIRTUAL_EXIT) or event_is(event, EVT_EXIT_BREAK) then
        if state.page == "confirm" then state.page = "setup"; return 0 end
        if state.editing then state.editing = false; return 0 end
        return 2
    end
    if state.page == "setup" then capture_pose_switch(); handle_setup(event, touch); draw_setup()
    elseif state.page == "confirm" then handle_confirm(event, touch); draw_confirm()
    elseif state.page == "error" then draw_error()
    else draw_result() end
    return 0
end

return { init = init, run = run }

-- Universal Goosky S1 V2 / S2 MAX telemetry widget
-- Native layouts for RadioMaster 800x480 and 480x320 color touch radios.

local NAME = "NERC Goosky FlightDeck"
local WIDGET_PATH = "/WIDGETS/NERC_GSkyFD/"
-- Keep generated model switch captures outside the replaceable widget folder.
-- The legacy location remains readable so existing radios migrate without
-- requiring setup to be rerun.
local AUTO_CFG_PREFIX = "/SCRIPTS/TOOLS/NERC_GSkyFD_"
local LEGACY_AUTO_CFG_PREFIX = WIDGET_PATH .. "auto_"

-- Telemetry order matches the discovered ELRS/CRSF sensors on both aircraft.
local telemetry_fields = {
    "1RSS", "2RSS", "RQly", "RSNR", "ANT", "RFMD", "TPWR", "TRSS", "TQly",
    "TSNR", "RxBt", "Curr", "Capa", "Bat%", "GAlt", "RPM"
}

local SENSOR = {
    RSS1 = 1, RSS2 = 2, RQLY = 3, RSNR = 4, ANT = 5, RFMD = 6, TPWR = 7,
    TRSS = 8, TQLY = 9, TSNR = 10, RXBT = 11, CURR = 12, CAPA = 13,
    BATP = 14, GALT = 15, RPM = 16
}

local PROFILES = {
    S1 = { name = "S1 V2", cells = 2, battery_max = 8.4, capacity = 300, chemistry = "lipo" },
    S2 = { name = "S2 MAX", cells = 3, battery_max = 12.6, capacity = 750, chemistry = "lipo" }
}

-- Approximate standard-LiPo open-circuit state of charge by voltage per cell.
-- A LiPo discharge curve is not linear: most of its usable capacity sits on
-- the relatively flat 3.7-4.0V plateau.  Values seen under motor load will be
-- lower because of voltage sag, so this remains a conservative estimate rather
-- than a fuel gauge.  The endpoints deliberately treat 3.30V/cell as empty;
-- it is not intended as a safe in-flight cutoff target.
local LIPO_SOC_CURVE = {
    { 4.20, 100 }, { 4.15, 95 }, { 4.11, 90 }, { 4.08, 85 },
    { 4.02, 80 },  { 3.98, 75 }, { 3.95, 70 }, { 3.91, 65 },
    { 3.87, 60 },  { 3.85, 55 }, { 3.84, 50 }, { 3.82, 45 },
    { 3.80, 40 },  { 3.79, 35 }, { 3.77, 30 }, { 3.75, 25 },
    { 3.73, 20 },  { 3.71, 15 }, { 3.69, 10 }, { 3.61, 5 },
    { 3.30, 0 }
}

-- LiHV cells add most of their extra usable energy at the top of the curve.
-- Below roughly 3.9V/cell their behavior converges toward conventional LiPo.
-- As with the LiPo table, this is an approximate open-circuit curve; voltage
-- under load will sag and capacity telemetry is preferable when calibrated.
local LIHV_SOC_CURVE = {
    { 4.35, 100 }, { 4.30, 95 }, { 4.25, 90 }, { 4.20, 85 },
    { 4.13, 80 },  { 4.08, 75 }, { 4.04, 70 }, { 4.00, 65 },
    { 3.96, 60 },  { 3.93, 55 }, { 3.90, 50 }, { 3.87, 45 },
    { 3.84, 40 },  { 3.82, 35 }, { 3.80, 30 }, { 3.77, 25 },
    { 3.74, 20 },  { 3.71, 15 }, { 3.69, 10 }, { 3.61, 5 },
    { 3.30, 0 }
}

-- EdgeTX channel sources use approximately 1024 units for 100% positive
-- output. Goosky Bank 1 can command 0 at low stick. Treat only mixed throttle
-- output above 20% as active so low/transition values do not start the timer.
local THROTTLE_ACTIVE_THRESHOLD = 205
-- A settings scan or write is allowed only with the final mixed CH3 output at
-- its true -100% endpoint. This is intentionally much stricter than the 20%
-- threshold used for flight-timer activity.
local THROTTLE_SAFE_MINIMUM = -1000

-- Match the official ExpressLRS Lua discovery cadence: one device ping per
-- second. Keep it bounded so the widget never becomes a permanent competing
-- ELRS Lua client when the receiver-off preflight cannot reach the TX module.
local ELRS_DISCOVERY_WINDOW = 1200
local ELRS_DISCOVERY_INTERVAL = 100

-- Goosky's fixed AETR mapping uses CH5 for the pose/stability command.
-- A positive high output selects Attitude mode; low/default selects 3D mode.
local ATTITUDE_MODE_THRESHOLD = 512

local field_id = {}
local bank_info = { current = 1 }
local assets = { compact = {}, wide = {} }
local cached_model_name = ""
local cached_layout = ""
local cached_model_bitmap = nil
local last_sensor_scan = -1000
local led_cache = { signature = nil, retry_at = 0, buttons_ready = nil }
local auto_profile = nil
local simulation = nil

-- CRSF addresses used by the official ExpressLRS Lua implementation. Device
-- discovery is broadcast from the radio address (0xEA). Once the local ELRS
-- transmitter at 0xEE answers, parameter and status traffic must use the
-- dedicated ELRS Lua address (0xEF). Some radios tolerate 0xEA throughout;
-- the TX15 internal module does not reliably do so.
local CRSF_BROADCAST = 0x00
local CRSF_RADIO = 0xEA
local CRSF_ELRS_LUA = 0xEF
local CRSF_ELRS_TX = 0xEE

local function load_simulation_backend()
    simulation = nil
    if type(loadScript) ~= "function" then return end
    local path = WIDGET_PATH .. "simulator.lua"
    if not fstat(path) then return end
    local chunk = loadScript(path)
    if type(chunk) ~= "function" then return end
    local ok, backend = pcall(chunk)
    if ok and type(backend) == "table" and backend.is_goosky_simulator then
        simulation = backend
    end
end

local function crsf_push(command, data)
    if simulation and type(simulation.push) == "function" then
        return simulation.push(command, data, getTime())
    end
    if type(crossfireTelemetryPush) == "function" then
        return crossfireTelemetryPush(command, data)
    end
    return false
end

-- The official ExpressLRS Lua client does not use the return from
-- crossfireTelemetryPush() as delivery acknowledgement. Preserve that behavior
-- for discovery/read traffic: a call that completes without a Lua error was
-- submitted, and only the corresponding CRSF reply confirms delivery.
local function crsf_submit(command, data)
    if simulation and type(simulation.push) == "function" then
        simulation.push(command, data, getTime())
        return true
    end
    if type(crossfireTelemetryPush) ~= "function" then return false end
    return pcall(crossfireTelemetryPush, command, data)
end

local function crsf_pop()
    if simulation and type(simulation.pop) == "function" then
        return simulation.pop(getTime())
    end
    if type(crossfireTelemetryPop) == "function" then
        return crossfireTelemetryPop()
    end
    return nil
end

-- ELRS device-parameter monitor. Reads are automatic; writes are only sent
-- after an explicit Yes response to the mismatch warning dialog.
local elrs_state = {
    device_id = CRSF_ELRS_TX,
    handset_id = CRSF_RADIO,
    device_found = false,
    device_name = "",
    fields_count = 0,
    queue = {},
    queue_pos = 1,
    current = nil,
    initial_scan = false,
    settings = {},
    field_ids = {},
    next_ping = 0,
    discovery_deadline = 0,
    next_status = 0,
    next_refresh = 0,
    ping_attempts = 0,
    status_requested = false,
    status_deadline = 0,
    refresh_attempts = 0,
    scan_complete = false,
    status_seen = false,
    connected = false,
    armed = false,
    model_mismatch = false,
    transport_error = nil,
    gate_error = nil,
    supported = true,
    fix = { stage = "idle", deadline = 0, message = "" }
}

local ELRS_PARAMETER_NAMES = {
    "Packet Rate", "Telem Ratio", "Switch Mode", "Model Match",
    "Max Power", "Dynamic", "Dynamic Power", "Antenna Mode"
}

local timer_reset_was_active = false
local power_max = 0
local saved_setup_snapshot = ""

local options = {
    { "Aircraft", CHOICE, 1, { "Auto", "S1 V2", "S2 MAX" } },
    { "BatteryPct", CHOICE, 1, { "Auto / OEM", "LiPo Curve", "LiHV Curve", "Bat% Sensor", "Capacity Used" } },
    -- PackCap=0 selects the OEM capacity from the detected aircraft profile.
    { "PackCap", VALUE, 0, 0, 5000 },
    { "CapaAdj", VALUE, 0, -50, 100 },
    { "SquareColor", COLOR, WHITE },
    { "ValueColor", COLOR, GREEN },
    -- Combines plain-language status assistance and the optional radio LEDs so
    -- the widget remains within EdgeTX's ten native-option limit.
    -- On includes both the plain-language screen alerts and the radio's
    -- programmable RGB gimbal lights. Screen Only leaves the lights alone.
    { "StatusHelp", CHOICE, 1, { "On", "Screen Only", "Off" } },
    -- These remain blank unless the user selects a native widget override.
    -- When blank, effective_switch_setting() imports the per-model values
    -- captured by GooskySetup from auto_<model>.cfg.
    { "BankSwitch", SOURCE, 0 },
    { "HoldSwitch", SWITCH, 0 },
    { "TimerReset", SWITCH, 0 }
}

local function reset_elrs_state()
    elrs_state.device_id = CRSF_ELRS_TX
    elrs_state.handset_id = CRSF_RADIO
    elrs_state.device_found = false
    elrs_state.device_name = ""
    elrs_state.fields_count = 0
    elrs_state.queue = {}
    elrs_state.queue_pos = 1
    elrs_state.current = nil
    elrs_state.initial_scan = false
    elrs_state.settings = {}
    elrs_state.field_ids = {}
    elrs_state.next_ping = 0
    elrs_state.discovery_deadline = 0
    elrs_state.next_status = 0
    elrs_state.next_refresh = 0
    elrs_state.ping_attempts = 0
    elrs_state.status_requested = false
    elrs_state.status_deadline = 0
    elrs_state.refresh_attempts = 0
    elrs_state.scan_complete = false
    elrs_state.status_seen = false
    elrs_state.connected = false
    elrs_state.armed = false
    elrs_state.model_mismatch = false
    elrs_state.transport_error = nil
    elrs_state.gate_error = nil
    elrs_state.fix = { stage = "idle", deadline = 0, message = "" }
    elrs_state.supported = simulation ~= nil
        or (type(crossfireTelemetryPush) == "function" and type(crossfireTelemetryPop) == "function")
end

local function open_bitmap(filename)
    local path = WIDGET_PATH .. filename
    if fstat(path) then
        return Bitmap.open(path)
    end
    return nil
end

local function open_model_image(filename)
    local safe_name = string.match(tostring(filename or ""), "([^/\\]+)$") or ""
    if safe_name == "" then return nil end
    local path = "/IMAGES/" .. safe_name
    if fstat(path) then return Bitmap.open(path) end
    return nil
end

local function scan_telemetry_fields()
    for i = 1, #telemetry_fields do
        local simulated = simulation and type(simulation.getSensor) == "function"
        local info = not simulated and getFieldInfo(telemetry_fields[i]) or nil
        if simulated then
            field_id[i] = { id = telemetry_fields[i], available = true, simulated = true }
        elseif info ~= nil then
            field_id[i] = { id = info.id, available = true }
        else
            field_id[i] = { id = 0, available = false }
        end
    end
    last_sensor_scan = getTime()
end

local function create(zone, widget_options)
    local widget = {
        zone = zone,
        options = widget_options,
        -- Start the 3-second splash on the first actual App Mode refresh, not
        -- here. EdgeTX can create restored widgets well before their page is
        -- drawn during radio startup, which would otherwise consume the whole
        -- splash timer off-screen.
        splash_pending = true,
        splash_until = 0,
        elrs_dialog = false,
        elrs_dialog_choice = 2,
        elrs_dialog_opened = 0,
        elrs_prompt_dismissed = nil,
        elrs_dialog_message = "",
        elrs_recheck_requested = false,
        detected_chemistry = nil,
        auto_switches = nil,
        auto_switch_path = nil,
        auto_switch_next = 0,
        adc_filter_ok = nil,
        adc_filter_next = 0
    }

    load_simulation_backend()
    scan_telemetry_fields()
    cached_model_name = ""
    cached_layout = ""
    cached_model_bitmap = nil
    timer_reset_was_active = false
    power_max = 0
    saved_setup_snapshot = ""
    bank_info.current = 1
    auto_profile = nil
    led_cache.signature = nil
    led_cache.retry_at = 0
    led_cache.buttons_ready = nil
    reset_elrs_state()

    assets.compact.default = open_bitmap("Goosky.png")
    assets.compact.title = open_bitmap("title.jpg")
    assets.compact.splash = open_bitmap("brand_splash.png")
    assets.compact.hold_off = open_bitmap("hold1.png")
    assets.compact.hold_on = open_bitmap("hold2.png")

    assets.wide.default = open_bitmap("Goosky_800.png") or assets.compact.default
    assets.wide.title = open_bitmap("title_800.jpg") or assets.compact.title
    assets.wide.splash = open_bitmap("brand_splash_800.png") or assets.compact.splash
    assets.wide.hold_off = open_bitmap("hold1_800.png") or assets.compact.hold_off
    assets.wide.hold_on = open_bitmap("hold2_800.png") or assets.compact.hold_on

    return widget
end

local function update(widget, widget_options)
    widget.options = widget_options
end

local function model_config_key(model_info)
    local raw = type(model_info) == "table" and (model_info.filename or model_info.name) or "model"
    local key = string.lower(tostring(raw or "model"))
    key = string.gsub(key, "[^%w_-]", "_")
    if key == "" then key = "model" end
    return key
end

local function load_auto_switches(widget, model_info)
    local now = getTime()
    local path = AUTO_CFG_PREFIX .. model_config_key(model_info) .. ".cfg"
    local name_path = AUTO_CFG_PREFIX
        .. model_config_key({ name = model_info and model_info.name or "model" }) .. ".cfg"
    local legacy_path = LEGACY_AUTO_CFG_PREFIX .. model_config_key(model_info) .. ".cfg"
    local legacy_name_path = LEGACY_AUTO_CFG_PREFIX
        .. model_config_key({ name = model_info and model_info.name or "model" }) .. ".cfg"
    local cache_key = table.concat({ path, name_path, legacy_path, legacy_name_path }, "|")
    if widget.auto_switch_path == cache_key
        and now < (widget.auto_switch_next or 0) then return end
    widget.auto_switch_path = cache_key
    widget.auto_switch_next = now + 200

    local function read_switch_config(candidate)
        local file = io and io.open and io.open(candidate, "r") or nil
        if not file then return nil end
        local contents = io.read(file, 2048) or ""
        io.close(file)
        local parsed = {}
        for line in string.gmatch(contents, "[^\r\n]+") do
            local key, value = string.match(line, "^([^=]+)=(.*)$")
            if key then parsed[key] = value end
        end
        parsed.bank_source = tonumber(parsed.bank_source) or 0
        parsed.hold_switch = tonumber(parsed.hold_switch) or 0
        parsed.reset_switch = tonumber(parsed.reset_switch) or 0
        return parsed
    end

    local ok, config = pcall(function()
        local parsed = read_switch_config(path)
        if not parsed and name_path ~= path then
            parsed = read_switch_config(name_path)
        end
        if not parsed then parsed = read_switch_config(legacy_path) end
        if not parsed and legacy_name_path ~= legacy_path then
            parsed = read_switch_config(legacy_name_path)
        end
        return parsed
    end)
    widget.auto_switches = ok and config or nil
    if widget.auto_switches and widget.options then
        -- Deleting a widget also deletes EdgeTX's per-instance option values.
        -- Restore blank options from GooskySetup's model-specific file so the
        -- replacement widget operates with the same BANK/HOLD/RESET mapping.
        if (tonumber(widget.options.BankSwitch) or 0) == 0 then
            widget.options.BankSwitch = widget.auto_switches.bank_source
        end
        if (tonumber(widget.options.HoldSwitch) or 0) == 0 then
            widget.options.HoldSwitch = widget.auto_switches.hold_switch
        end
        if (tonumber(widget.options.TimerReset) or 0) == 0 then
            widget.options.TimerReset = widget.auto_switches.reset_switch
        end
    end
end

local function effective_switch_setting(widget, option_name)
    local auto_key = option_name == "BankSwitch" and "bank_source"
        or (option_name == "HoldSwitch" and "hold_switch" or "reset_switch")
    local native = tonumber(widget.options and widget.options[option_name]) or 0
    if native ~= 0 then return native end
    local detected = widget.auto_switches and tonumber(widget.auto_switches[auto_key]) or 0
    return detected
end

local function enforce_adc_filter_off(widget, model_info)
    local now = getTime()
    if now < (widget.adc_filter_next or 0) then
        return widget.adc_filter_ok
    end
    widget.adc_filter_next = now + 500

    -- EdgeTX exposes ADC filtering as a three-state per-model override:
    -- 0=Global, 1=Off, 2=On. A direct Off override is safer than depending on
    -- the radio-wide Hardware setting and is supported by EdgeTX 2.12.
    if type(model_info) == "table" and tonumber(model_info.jitterFilter) == 1 then
        widget.adc_filter_ok = true
        return true
    end
    if not model or type(model.setInfo) ~= "function" then
        widget.adc_filter_ok = false
        return false
    end

    local wrote = pcall(model.setInfo, { jitterFilter = 1 })
    local verified = nil
    if wrote and type(model.getInfo) == "function" then
        local ok, value = pcall(model.getInfo)
        if ok and type(value) == "table" then verified = value end
    end
    widget.adc_filter_ok = wrote and verified ~= nil
        and tonumber(verified.jitterFilter) == 1
    return widget.adc_filter_ok
end

-- A standalone EdgeTX tool cannot inspect the current widget instance. Save
-- only model identity and aircraft selection. BANK, HOLD, RESET and ATT are
-- deliberately never supplied by widget defaults; GooskySetup captures all
-- four directly from the user on every setup run.
-- The file is rewritten only when a value changes, not on every refresh.
local function save_model_setup_options(widget, model_info)
    if not io or type(io.open) ~= "function" or not widget or not widget.options then
        return
    end

    local filename = model_info and model_info.filename or ""
    local model_name = model_info and model_info.name or ""
    filename = string.gsub(tostring(filename), "[\r\n=]", "_")
    model_name = string.gsub(tostring(model_name), "[\r\n=]", "_")

    local aircraft = tonumber(widget.options.Aircraft) or 1

    local content = table.concat({
        "version=1",
        "filename=" .. filename,
        "model_name=" .. model_name,
        "aircraft=" .. aircraft,
        ""
    }, "\n")

    if content == saved_setup_snapshot then return end

    local wrote = false
    pcall(function()
        local file = io.open(WIDGET_PATH .. "setup.cfg", "w")
        if file then
            io.write(file, content)
            io.close(file)
            wrote = true
        end
    end)
    if wrote then saved_setup_snapshot = content end
end

local function background(widget)
    -- Returning from another page/tool is the only automatic rescan trigger.
    -- refresh() still applies every receiver-off safety gate before honoring
    -- it, so background operation itself never touches the CRSF queue.
    widget.elrs_recheck_requested = true
end

local function sensor_available(index)
    return field_id[index] and field_id[index].available
end

local function read_sensor(index)
    if not sensor_available(index) then
        return 0
    end
    local value
    if field_id[index].simulated and simulation then
        value = simulation.getSensor(field_id[index].id, getTime())
    else
        value = getValue(field_id[index].id)
    end
    if type(value) ~= "number" then
        return 0
    end
    return value
end

local function round_number(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function sensor_integer_text(index, suffix)
    if not sensor_available(index) then
        return "---"
    end
    return string.format("%d%s", round_number(read_sensor(index)), suffix or "")
end

local function sensor_decimal_text(index, decimals, suffix)
    if not sensor_available(index) then
        return "---"
    end
    return string.format("%." .. tostring(decimals) .. "f%s", read_sensor(index), suffix or "")
end

local function read_cstring(data, offset)
    local chars = {}
    while offset <= #data and data[offset] ~= 0 do
        chars[#chars + 1] = string.char(data[offset])
        offset = offset + 1
    end
    return table.concat(chars), offset + 1
end

local function split_options(raw)
    local values = {}
    local start_pos = 1
    for i = 1, #raw + 1 do
        if i > #raw or string.byte(raw, i) == 59 then
            values[#values + 1] = string.sub(raw, start_pos, i - 1)
            start_pos = i + 1
        end
    end
    return values
end

local function queue_elrs_fields(ids, initial_scan)
    elrs_state.queue = ids
    elrs_state.queue_pos = 1
    elrs_state.current = nil
    elrs_state.initial_scan = initial_scan or false
end

local function target_settings_complete()
    for _, name in ipairs({ "Packet Rate", "Telem Ratio", "Switch Mode", "Model Match", "Max Power" }) do
        if not elrs_state.settings[name] then
            return false
        end
    end
    return elrs_state.settings["Dynamic"] ~= nil or elrs_state.settings["Dynamic Power"] ~= nil
end

local function missing_target_settings_text()
    local missing = {}
    for _, name in ipairs({ "Packet Rate", "Telem Ratio", "Switch Mode", "Model Match", "Max Power" }) do
        if not elrs_state.settings[name] then missing[#missing + 1] = name end
    end
    if not elrs_state.settings["Dynamic"] and not elrs_state.settings["Dynamic Power"] then
        missing[#missing + 1] = "Dynamic"
    end
    return table.concat(missing, ",")
end

local function parse_elrs_device_info(data)
    if data[2] ~= elrs_state.device_id then
        return
    end

    local device_name, offset = read_cstring(data, 3)
    local field_count = data[offset + 12] or 0

    -- Match the official ExpressLRS Lua address transition. Keep discovery on
    -- 0xEA, but address all local TX-module parameter traffic from 0xEF.
    elrs_state.device_found = true
    elrs_state.device_name = device_name or "ELRS TX"
    elrs_state.handset_id = CRSF_ELRS_LUA
    elrs_state.transport_error = nil

    if field_count <= 0 or field_count == elrs_state.fields_count then
        return
    end

    elrs_state.fields_count = field_count
    local ids = {}
    for id = 1, field_count do
        ids[#ids + 1] = id
    end
    queue_elrs_fields(ids, true)
end

local function parse_elrs_parameter_payload(field_id_value, payload)
    if #payload < 4 then
        return
    end

    local offset = 2 -- skip parent folder ID
    local field_type = bit32.band(payload[offset] or 0, 0x7F)
    offset = offset + 1
    local name
    name, offset = read_cstring(payload, offset)

    -- All four settings we need are CRSF text-selection parameters (type 9).
    if field_type ~= 9 then
        return
    end

    local raw_options
    raw_options, offset = read_cstring(payload, offset)
    local values = split_options(raw_options)
    local selected_index = payload[offset] or 0
    local unit = read_cstring(payload, offset + 4)

    for _, target_name in ipairs(ELRS_PARAMETER_NAMES) do
        if name == target_name then
            elrs_state.settings[name] = {
                value = values[selected_index + 1] or "?",
                unit = unit or "",
                index = selected_index,
                values = values
            }
            elrs_state.field_ids[name] = field_id_value
            break
        end
    end
end

local function finish_elrs_parameter()
    local current = elrs_state.current
    if current then
        parse_elrs_parameter_payload(current.id, current.payload)
    end
    elrs_state.current = nil
end

local function parse_elrs_parameter_frame(data)
    local current = elrs_state.current
    if not current or data[2] ~= elrs_state.device_id or data[3] ~= current.id then
        return
    end

    for i = 5, #data do
        current.payload[#current.payload + 1] = data[i]
    end

    local chunks_remaining = data[4] or 0
    current.attempts = 0
    if chunks_remaining > 0 then
        current.chunk = current.chunk + 1
        current.deadline = 0
    else
        finish_elrs_parameter()
    end
end

local function parse_elrs_status(data)
    if data[2] ~= elrs_state.device_id then
        return
    end
    local flags = data[6] or 0
    elrs_state.status_seen = true
    elrs_state.connected = bit32.btest(flags, 0x01)
    -- ExpressLRS defines bit 1 as its AUX1/CH5 arming flag. On these Goosky
    -- models CH5 is pose mode, so this is diagnostic state, not motor state.
    elrs_state.armed = bit32.btest(flags, 0x02)
    elrs_state.model_mismatch = bit32.btest(flags, 0x04)
end

local function start_next_elrs_parameter(now)
    if elrs_state.current or elrs_state.queue_pos > #elrs_state.queue then
        return
    end
    local id = elrs_state.queue[elrs_state.queue_pos]
    elrs_state.queue_pos = elrs_state.queue_pos + 1
    elrs_state.current = { id = id, chunk = 0, payload = {}, deadline = now, attempts = 0 }
end

local function refresh_elrs_target_settings(now)
    local ids = {}
    for _, name in ipairs(ELRS_PARAMETER_NAMES) do
        if elrs_state.field_ids[name] then
            ids[#ids + 1] = elrs_state.field_ids[name]
        end
    end

    if #ids > 0 then
        queue_elrs_fields(ids, false)
    elseif elrs_state.fields_count > 0 then
        local all_ids = {}
        for id = 1, elrs_state.fields_count do
            all_ids[#all_ids + 1] = id
        end
        queue_elrs_fields(all_ids, true)
    end
    elrs_state.next_refresh = now + 500
end

local function poll_elrs_settings(safe_preflight)
    if not elrs_state.supported or not safe_preflight then
        return
    end

    local fix_active = elrs_state.fix.stage ~= "idle"
        and elrs_state.fix.stage ~= "complete"
        and elrs_state.fix.stage ~= "error"
    -- Never consume the shared CRSF Lua queue after the one-shot preflight
    -- scan. Explicit user-approved repair readbacks are the sole exception.
    if elrs_state.scan_complete and not fix_active then return end

    local command, data
    repeat
        command, data = crsf_pop()
        if command == 0x29 and data then
            parse_elrs_device_info(data)
        elseif command == 0x2B and data then
            parse_elrs_parameter_frame(data)
        elseif command == 0x2E and data then
            parse_elrs_status(data)
        end
    until command == nil

    local now = getTime()
    if elrs_state.discovery_deadline == 0 then
        elrs_state.discovery_deadline = now + ELRS_DISCOVERY_WINDOW
    end
    local sent_this_cycle = false
    if not elrs_state.device_found and now >= elrs_state.discovery_deadline then
        elrs_state.scan_complete = true
        elrs_state.transport_error = "NO ELRS TX MODULE RESPONSE"
    elseif not elrs_state.device_found and now >= elrs_state.next_ping then
        crsf_submit(0x28, { CRSF_BROADCAST, CRSF_RADIO })
        elrs_state.ping_attempts = elrs_state.ping_attempts + 1
        elrs_state.next_ping = now + ELRS_DISCOVERY_INTERVAL
        sent_this_cycle = true
    end

    if elrs_state.device_found and not fix_active and not elrs_state.status_requested
        and now >= elrs_state.next_status then
        -- Special ELRS read-only status query: connected, armed, and mismatch flags.
        local submitted = crsf_submit(0x2D, {
            elrs_state.device_id, elrs_state.handset_id, 0x00, 0x00
        })
        if submitted then
            elrs_state.status_requested = true
            elrs_state.status_deadline = now + 100
        end
        elrs_state.next_status = now + 100
        sent_this_cycle = submitted
    end

    -- An undiscovered TX module correctly has an empty parameter queue. Do not
    -- mistake that for a finished parameter scan; discovery owns the timeout
    -- until a real 0xEE device-information response has been parsed.
    if elrs_state.device_found and not elrs_state.current
        and elrs_state.queue_pos > #elrs_state.queue then
        if elrs_state.initial_scan then
            elrs_state.initial_scan = false
            if target_settings_complete()
                and (elrs_state.status_seen or now >= elrs_state.status_deadline) then
                elrs_state.scan_complete = true
            else
                elrs_state.next_refresh = now + 50
            end
        elseif target_settings_complete()
            and (elrs_state.status_seen or now >= elrs_state.status_deadline) then
            elrs_state.scan_complete = true
        elseif elrs_state.refresh_attempts < 1 and now >= elrs_state.next_refresh then
            elrs_state.refresh_attempts = elrs_state.refresh_attempts + 1
            refresh_elrs_target_settings(now)
        elseif elrs_state.refresh_attempts >= 1 and now >= elrs_state.next_refresh then
            elrs_state.scan_complete = true
            if not target_settings_complete() then
                elrs_state.transport_error = "ELRS READ INCOMPLETE: "
                    .. missing_target_settings_text()
            end
        end
    end

    start_next_elrs_parameter(now)
    if not sent_this_cycle and elrs_state.current
        and now >= elrs_state.current.deadline then
        if (elrs_state.current.attempts or 0) >= 3 then
            -- A missing/unsupported parameter must not create permanent CRSF
            -- traffic. Skip it after three bounded read attempts.
            elrs_state.current = nil
            return
        end
        crsf_submit(0x2C, {
            elrs_state.device_id,
            elrs_state.handset_id,
            elrs_state.current.id,
            elrs_state.current.chunk
        })
        elrs_state.current.attempts = (elrs_state.current.attempts or 0) + 1
        elrs_state.current.deadline = now + 50
    end
end

local function clean_setting_text(value)
    value = value or "?"
    value = string.match(value, "^%s*(.-)%s*$") or value
    local before_sensitivity = string.match(value, "^(.-)%s+%(%-")
    return before_sensitivity or value
end

local function compact_elrs_rate(rate)
    local compact = string.gsub(rate or "?", "Hz", "")
    compact = string.gsub(compact, "%s+[Ff]ull", "F")
    compact = string.gsub(compact, "%s+2%.4G", "")
    compact = string.gsub(compact, "%s+", " ")
    return compact
end

local function elrs_rate_is_target(value)
    local lower = string.lower(clean_setting_text(value or "?"))
    return string.find(lower, "333", 1, true) ~= nil
        and string.find(lower, "full", 1, true) ~= nil
end

local function elrs_switch_is_target(value)
    local lower = string.lower(clean_setting_text(value or "?"))
    return lower == "8ch" or string.match(lower, "^8ch[%s%-]") ~= nil
end

local function elrs_telem_is_target(value)
    return clean_setting_text(value or "?") == "1:32"
end

local function elrs_power_is_target(value)
    local numeric = tonumber(string.match(clean_setting_text(value or ""), "%d+"))
    return numeric == 100
end

local function elrs_dynamic_is_target(value)
    return string.lower(clean_setting_text(value or "?")) == "off"
end

local function elrs_antenna_is_target(value)
    return string.lower(clean_setting_text(value or "?")) == "switch"
end

local function get_dynamic_setting()
    if elrs_state.settings["Dynamic"] then
        return "Dynamic", elrs_state.settings["Dynamic"]
    elseif elrs_state.settings["Dynamic Power"] then
        return "Dynamic Power", elrs_state.settings["Dynamic Power"]
    end
    return nil, nil
end

local function elrs_fix_required()
    local rate_setting = elrs_state.settings["Packet Rate"]
    local telem_setting = elrs_state.settings["Telem Ratio"]
    local switch_setting = elrs_state.settings["Switch Mode"]
    local power_setting = elrs_state.settings["Max Power"]
    local antenna_setting = elrs_state.settings["Antenna Mode"]
    local _, dynamic_setting = get_dynamic_setting()
    if not rate_setting or not telem_setting or not switch_setting
        or not power_setting or not dynamic_setting then
        return false
    end
    return not elrs_rate_is_target(rate_setting.value)
        or not elrs_telem_is_target(telem_setting.value)
        or not elrs_switch_is_target(switch_setting.value)
        or not elrs_power_is_target(power_setting.value)
        or not elrs_dynamic_is_target(dynamic_setting.value)
        or (antenna_setting ~= nil
            and not elrs_antenna_is_target(antenna_setting.value))
end

local function elrs_link_connected()
    if elrs_state.status_seen and elrs_state.connected then return true end
    return sensor_available(SENSOR.RQLY) and read_sensor(SENSOR.RQLY) > 0
end

local function find_elrs_target_index(name, matcher)
    local setting = elrs_state.settings[name]
    if not setting or not setting.values then
        return nil
    end
    for index, value in ipairs(setting.values) do
        if matcher(value) then
            return index - 1
        end
    end
    return nil
end

local function elrs_reads_idle()
    return not elrs_state.current and elrs_state.queue_pos > #elrs_state.queue
end

local function queue_fix_readback(names)
    local ids = {}
    for _, name in ipairs(names) do
        local id = elrs_state.field_ids[name]
        if id then ids[#ids + 1] = id end
    end
    if #ids > 0 then
        queue_elrs_fields(ids, false)
        return true
    end
    return false
end

local ELRS_RECOMMENDED = {
    rate = "333Hz Full",
    channels = "8ch",
    telemetry = "1:32",
    power = "100mW",
    dynamic = "Off",
    antenna = "Switch"
}

local function current_elrs_display_values()
    local rate_setting = elrs_state.settings["Packet Rate"]
    local telem_setting = elrs_state.settings["Telem Ratio"]
    local switch_setting = elrs_state.settings["Switch Mode"]
    local power_setting = elrs_state.settings["Max Power"]
    local antenna_setting = elrs_state.settings["Antenna Mode"]
    local _, dynamic_setting = get_dynamic_setting()
    local power = power_setting and clean_setting_text(power_setting.value) or "?"
    if power_setting and power_setting.unit ~= ""
        and not string.find(string.lower(power), "mw", 1, true) then
        power = power .. power_setting.unit
    end
    return {
        rate = rate_setting and clean_setting_text(rate_setting.value) or "?",
        channels = switch_setting and clean_setting_text(switch_setting.value) or "?",
        telemetry = telem_setting and clean_setting_text(telem_setting.value) or "?",
        power = power,
        dynamic = dynamic_setting and clean_setting_text(dynamic_setting.value) or "?",
        antenna = antenna_setting and clean_setting_text(antenna_setting.value) or nil
    }
end

local function set_elrs_fix_result(stage, message)
    elrs_state.fix.stage = stage
    elrs_state.fix.message = message
end

local function begin_elrs_fix(hold_on)
    if not hold_on then
        return false, "ENABLE THROTTLE HOLD FIRST"
    end
    if elrs_link_connected() then
        return false, "POWER OFF HELICOPTER FIRST"
    end
    if elrs_state.status_seen and elrs_state.armed then
        return false, "SET CH5 TO 3D (-100) FIRST"
    end

    local now = getTime()
    elrs_state.fix = {
        stage = "set_rate",
        -- Six verified writes on Gemini-capable modules can take slightly
        -- longer when CRSF is busy; keep the repair bounded at 45 seconds.
        deadline = now + 4500,
        next_action = now,
        write_retries = 0,
        message = "APPLYING SETTINGS",
        original = current_elrs_display_values()
    }
    -- Prevent the normal refresh cycle from replacing the fix readback queue.
    elrs_state.next_refresh = elrs_state.fix.deadline + 100
    return true
end

local function write_elrs_choice(name, value)
    local field = elrs_state.field_ids[name]
    if not field or value == nil then
        return false
    end
    return crsf_push(0x2D, {
        elrs_state.device_id,
        elrs_state.handset_id,
        field,
        value
    })
end

local function retry_busy_write(fix, now, message)
    fix.write_retries = (fix.write_retries or 0) + 1
    fix.next_action = now + 10
    fix.message = message .. " - CRSF BUSY, RETRYING"
end

local function write_accepted(fix)
    fix.write_retries = 0
end

local function process_elrs_fix(safe_preflight)
    local fix = elrs_state.fix
    if fix.stage == "idle" or fix.stage == "complete" or fix.stage == "error" then
        return
    end

    if not safe_preflight then
        set_elrs_fix_result("error", "PRECHECK CHANGED - CHANGE CANCELLED")
        return
    end

    local now = getTime()
    if now > fix.deadline then
        set_elrs_fix_result("error", "CHANGE NOT VERIFIED - USE ELRS LUA")
        return
    end
    if elrs_link_connected() then
        set_elrs_fix_result("error", "RECEIVER CONNECTED - CHANGE CANCELLED")
        return
    end

    if fix.stage == "queue_rate" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        if not queue_fix_readback({ "Packet Rate", "Switch Mode" }) then
            set_elrs_fix_result("error", "ELRS PARAMETER IDS NOT AVAILABLE")
        else
            fix.stage = "wait_rate"
        end
        return
    elseif fix.stage == "queue_switch" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        if not queue_fix_readback({ "Switch Mode" }) then
            set_elrs_fix_result("error", "SWITCH MODE ID NOT AVAILABLE")
        else
            fix.stage = "wait_switch"
        end
        return
    elseif fix.stage == "queue_telem" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        if not queue_fix_readback({ "Telem Ratio" }) then
            set_elrs_fix_result("error", "TELEMETRY RATIO ID NOT AVAILABLE")
        else
            fix.stage = "wait_telem"
        end
        return
    elseif fix.stage == "queue_power" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        if not queue_fix_readback({ "Max Power" }) then
            set_elrs_fix_result("error", "MAX POWER ID NOT AVAILABLE")
        else
            fix.stage = "wait_power"
        end
        return
    elseif fix.stage == "queue_dynamic" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        local dynamic_name = get_dynamic_setting()
        dynamic_name = dynamic_name or elrs_state.fix.dynamic_name
        if not dynamic_name or not queue_fix_readback({ dynamic_name }) then
            set_elrs_fix_result("error", "DYNAMIC POWER ID NOT AVAILABLE")
        else
            fix.stage = "wait_dynamic"
        end
        return
    elseif fix.stage == "queue_antenna" then
        if now < fix.next_action or not elrs_reads_idle() then return end
        if not queue_fix_readback({ "Antenna Mode" }) then
            set_elrs_fix_result("error", "ANTENNA MODE ID NOT AVAILABLE")
        else
            fix.stage = "wait_antenna"
        end
        return
    end

    if not elrs_reads_idle() then return end
    if fix.next_action and now < fix.next_action then return end

    if fix.stage == "set_rate" then
        local rate_setting = elrs_state.settings["Packet Rate"]
        if rate_setting and elrs_rate_is_target(rate_setting.value) then
            fix.stage = "set_switch"
            return
        end
        local target = find_elrs_target_index("Packet Rate", elrs_rate_is_target)
        if target == nil then
            set_elrs_fix_result("error", "333HZ FULL IS NOT AVAILABLE")
        elseif not write_elrs_choice("Packet Rate", target) then
            retry_busy_write(fix, now, "SETTING 333HZ FULL")
        else
            write_accepted(fix)
            elrs_state.settings["Packet Rate"] = nil
            elrs_state.settings["Switch Mode"] = nil
            fix.stage = "queue_rate"
            fix.next_action = now + 100
            fix.message = "SETTING 333HZ FULL"
        end
    elseif fix.stage == "wait_rate" then
        local rate_setting = elrs_state.settings["Packet Rate"]
        if not rate_setting then return end
        if elrs_rate_is_target(rate_setting.value) then
            fix.stage = "set_switch"
            fix.message = "SETTING 8CH FULL RES"
        else
            set_elrs_fix_result("error", "333HZ FULL CHANGE REJECTED")
        end
    elseif fix.stage == "set_switch" then
        local switch_setting = elrs_state.settings["Switch Mode"]
        if switch_setting and elrs_switch_is_target(switch_setting.value) then
            fix.stage = "set_telem"
            return
        end
        local target = find_elrs_target_index("Switch Mode", elrs_switch_is_target)
        if target == nil then
            set_elrs_fix_result("error", "8CH IS NOT AVAILABLE")
        elseif not write_elrs_choice("Switch Mode", target) then
            retry_busy_write(fix, now, "SETTING 8CH FULL RES")
        else
            write_accepted(fix)
            elrs_state.settings["Switch Mode"] = nil
            fix.stage = "queue_switch"
            fix.next_action = now + 100
            fix.message = "SETTING 8CH FULL RES"
        end
    elseif fix.stage == "wait_switch" then
        local switch_setting = elrs_state.settings["Switch Mode"]
        if not switch_setting then return end
        if elrs_switch_is_target(switch_setting.value) then
            fix.stage = "set_telem"
            fix.message = "SETTING TELEMETRY 1:32"
        else
            set_elrs_fix_result("error", "8CH CHANGE REJECTED")
        end
    elseif fix.stage == "set_telem" then
        local telem_setting = elrs_state.settings["Telem Ratio"]
        if telem_setting and elrs_telem_is_target(telem_setting.value) then
            fix.stage = "set_power"
            return
        end
        local target = find_elrs_target_index("Telem Ratio", elrs_telem_is_target)
        if target == nil then
            set_elrs_fix_result("error", "TELEMETRY 1:32 IS NOT AVAILABLE")
        elseif not write_elrs_choice("Telem Ratio", target) then
            retry_busy_write(fix, now, "SETTING TELEMETRY 1:32")
        else
            write_accepted(fix)
            elrs_state.settings["Telem Ratio"] = nil
            fix.stage = "queue_telem"
            fix.next_action = now + 100
            fix.message = "SETTING TELEMETRY 1:32"
        end
    elseif fix.stage == "wait_telem" then
        local telem_setting = elrs_state.settings["Telem Ratio"]
        if not telem_setting then return end
        if elrs_telem_is_target(telem_setting.value) then
            fix.stage = "set_power"
            fix.message = "SETTING FIXED 100mW"
        else
            set_elrs_fix_result("error", "TELEMETRY 1:32 CHANGE REJECTED")
        end
    elseif fix.stage == "set_power" then
        local power_setting = elrs_state.settings["Max Power"]
        if power_setting and elrs_power_is_target(power_setting.value) then
            fix.stage = "set_dynamic"
            return
        end
        local target = find_elrs_target_index("Max Power", elrs_power_is_target)
        if target == nil then
            set_elrs_fix_result("error", "100mW IS NOT AVAILABLE")
        elseif not write_elrs_choice("Max Power", target) then
            retry_busy_write(fix, now, "SETTING MAX POWER 100mW")
        else
            write_accepted(fix)
            elrs_state.settings["Max Power"] = nil
            fix.stage = "queue_power"
            fix.next_action = now + 100
            fix.message = "SETTING MAX POWER 100mW"
        end
    elseif fix.stage == "wait_power" then
        local power_setting = elrs_state.settings["Max Power"]
        if not power_setting then return end
        if elrs_power_is_target(power_setting.value) then
            fix.stage = "set_dynamic"
            fix.message = "DISABLING DYNAMIC POWER"
        else
            set_elrs_fix_result("error", "100mW CHANGE REJECTED")
        end
    elseif fix.stage == "set_dynamic" then
        local dynamic_name, dynamic_setting = get_dynamic_setting()
        if dynamic_setting and elrs_dynamic_is_target(dynamic_setting.value) then
            if elrs_state.settings["Antenna Mode"] then
                fix.stage = "set_antenna"
                fix.message = "SETTING ANTENNA SWITCH"
            else
                set_elrs_fix_result("complete", "ALL SETTINGS VERIFIED")
            end
            return
        end
        if not dynamic_name then
            set_elrs_fix_result("error", "DYNAMIC POWER SETTING NOT FOUND")
            return
        end
        local target = find_elrs_target_index(dynamic_name, elrs_dynamic_is_target)
        if target == nil then
            set_elrs_fix_result("error", "DYNAMIC POWER OFF IS NOT AVAILABLE")
        elseif not write_elrs_choice(dynamic_name, target) then
            retry_busy_write(fix, now, "DISABLING DYNAMIC POWER")
        else
            write_accepted(fix)
            elrs_state.fix.dynamic_name = dynamic_name
            elrs_state.settings[dynamic_name] = nil
            fix.stage = "queue_dynamic"
            fix.next_action = now + 100
            fix.message = "DISABLING DYNAMIC POWER"
        end
    elseif fix.stage == "wait_dynamic" then
        local _, dynamic_setting = get_dynamic_setting()
        if not dynamic_setting then return end
        if elrs_dynamic_is_target(dynamic_setting.value) then
            if elrs_state.settings["Antenna Mode"] then
                fix.stage = "set_antenna"
                fix.message = "SETTING ANTENNA SWITCH"
            else
                set_elrs_fix_result("complete", "ALL SETTINGS VERIFIED")
            end
        else
            set_elrs_fix_result("error", "DYNAMIC POWER OFF CHANGE REJECTED")
        end
    elseif fix.stage == "set_antenna" then
        local antenna_setting = elrs_state.settings["Antenna Mode"]
        if not antenna_setting then
            set_elrs_fix_result("error", "ANTENNA MODE SETTING NOT FOUND")
            return
        end
        if elrs_antenna_is_target(antenna_setting.value) then
            set_elrs_fix_result("complete", "ALL SETTINGS VERIFIED")
            return
        end
        local target = find_elrs_target_index("Antenna Mode", elrs_antenna_is_target)
        if target == nil then
            set_elrs_fix_result("error", "ANTENNA SWITCH IS NOT AVAILABLE")
        elseif not write_elrs_choice("Antenna Mode", target) then
            retry_busy_write(fix, now, "SETTING ANTENNA SWITCH")
        else
            write_accepted(fix)
            elrs_state.settings["Antenna Mode"] = nil
            fix.stage = "queue_antenna"
            fix.next_action = now + 100
            fix.message = "SETTING ANTENNA SWITCH"
        end
    elseif fix.stage == "wait_antenna" then
        local antenna_setting = elrs_state.settings["Antenna Mode"]
        if not antenna_setting then return end
        if elrs_antenna_is_target(antenna_setting.value) then
            set_elrs_fix_result("complete", "ALL SETTINGS VERIFIED")
        else
            set_elrs_fix_result("error", "ANTENNA SWITCH CHANGE REJECTED")
        end
    end
end

local function make_elrs_hud()
    if not elrs_state.supported then
        return {
            text = "ELRS CHECK UNAVAILABLE",
            medium = "ELRS CHECK UNAVAILABLE",
            compact = "ELRS CHECK N/A",
            level = "unknown"
        }
    end

    if elrs_state.gate_error then
        return {
            text = "ELRS AUTO CHECK BLOCKED: " .. elrs_state.gate_error,
            medium = "ELRS CHECK BLOCKED: " .. elrs_state.gate_error,
            compact = "ELRS BLOCKED: " .. elrs_state.gate_error,
            level = "error"
        }
    end

    if elrs_state.transport_error then
        return {
            text = "ELRS AUTO CHECK FAILED: " .. elrs_state.transport_error,
            medium = "ELRS CHECK FAILED: " .. elrs_state.transport_error,
            compact = elrs_state.device_found and "ELRS READ FAILED"
                or "ELRS TX NO RESPONSE",
            level = "error"
        }
    end

    if not elrs_state.device_found then
        return {
            text = "ELRS AUTO CHECK: SEARCHING TX MODULE",
            medium = "ELRS CHECK: SEARCHING TX",
            compact = "ELRS SEARCHING",
            level = "unknown"
        }
    end

    local rate_setting = elrs_state.settings["Packet Rate"]
    local telem_setting = elrs_state.settings["Telem Ratio"]
    local switch_setting = elrs_state.settings["Switch Mode"]
    local match_setting = elrs_state.settings["Model Match"]
    local power_setting = elrs_state.settings["Max Power"]
    local antenna_setting = elrs_state.settings["Antenna Mode"]
    local _, dynamic_setting = get_dynamic_setting()

    local rate = rate_setting and clean_setting_text(rate_setting.value) or "?"
    local telem = telem_setting and clean_setting_text(telem_setting.value) or "?"
    local switch_mode = switch_setting and clean_setting_text(switch_setting.value) or "?"
    local model_match = match_setting and clean_setting_text(match_setting.value) or "?"
    local match_unit = match_setting and match_setting.unit or ""
    local power = power_setting and clean_setting_text(power_setting.value) or "?"
    if power_setting and power_setting.unit ~= "" and not string.find(string.lower(power), "mw", 1, true) then
        power = power .. power_setting.unit
    end
    local dynamic = dynamic_setting and clean_setting_text(dynamic_setting.value) or "?"
    local antenna = antenna_setting and clean_setting_text(antenna_setting.value) or nil

    -- RFMD is a reliable fallback for the selected packet rate: ELRS 3.x uses
    -- index 8 and ELRS 4.x uses index 28 for 333Hz Full.
    if rate == "?" and sensor_available(SENSOR.RFMD) then
        local rfmd = round_number(read_sensor(SENSOR.RFMD))
        if rfmd == 8 or rfmd == 28 then
            rate = "333Hz Full"
        else
            rate = "RFMD " .. tostring(rfmd)
        end
    end

    local rate_ok = elrs_rate_is_target(rate)
    local switch_ok = elrs_switch_is_target(switch_mode)
    local telem_ok = telem == "1:32"
    local power_ok = elrs_power_is_target(power)
    local dynamic_ok = elrs_dynamic_is_target(dynamic)
    local antenna_ok = antenna == nil or elrs_antenna_is_target(antenna)
    local settings_known = rate ~= "?" and switch_mode ~= "?" and telem ~= "?"
        and power ~= "?" and dynamic ~= "?"
    local config_ok = settings_known and rate_ok and switch_ok and telem_ok and power_ok
        and dynamic_ok and antenna_ok

    local connected = elrs_link_connected()
    local match_enabled = string.lower(model_match) == "on"
    local match_status = ""
    local match_status_medium = ""
    local match_status_compact = ""

    -- Matching status is intentionally shown only when Model Match is enabled.
    if match_enabled then
        if elrs_state.model_mismatch then
            match_status = " | MISMATCH"
            match_status_medium = " MISMATCH"
            match_status_compact = " MIS"
        elseif connected then
            match_status = " | MATCH OK"
            match_status_medium = " MATCH OK"
            match_status_compact = " OK"
        else
            match_status = " | NO LINK / CHECK MATCH"
            match_status_medium = " NO LINK/CHECK MM"
            match_status_compact = " NO LINK"
        end
    end

    local match_text = model_match
    if match_enabled and match_setting and match_unit ~= "" then
        match_text = model_match .. match_unit
    end

    local match_id = string.match(match_unit, "ID:%s*([%d%-]+)") or "?"
    local medium_match
    local compact_match
    if match_enabled then
        medium_match = "MM " .. match_id .. match_status_medium
        compact_match = "MM" .. match_id .. match_status_compact
    elseif model_match == "?" then
        medium_match = "MM ?"
        compact_match = "MM?"
    else
        medium_match = "MM OFF"
        compact_match = "MM OFF"
    end

    local arm_flag = not elrs_state.status_seen and "?" or (elrs_state.armed and "ON" or "OFF")
    local antenna_text = antenna and (" | ANT " .. antenna) or ""
    local text = string.format("ELRS %s | %s | TLM %s | PWR %s %s%s | MM %s%s | CH5 ARM %s", rate, switch_mode, telem, power, dynamic, antenna_text, match_text, match_status, arm_flag)
    local compact_rate = compact_elrs_rate(rate)
    local medium = string.format("ELRS %s | %s | %s | %s %s%s | %s | ARM %s", compact_rate, switch_mode, telem, power, dynamic, antenna_text, medium_match, arm_flag)
    local compact = string.format("%s/%s/%s P%s%s %s ARM%s", compact_rate, switch_mode, telem, power, dynamic == "Off" and "F" or "D", compact_match, arm_flag)

    local level = "unknown"
    if elrs_state.model_mismatch and match_enabled then
        level = "error"
    elseif settings_known and not config_ok then
        level = "error"
    elseif not target_settings_complete() then
        level = "unknown"
    elseif not match_enabled then
        level = "warning"
    elseif config_ok and connected then
        level = "ok"
    else
        level = "warning"
    end

    return { text = text, medium = medium, compact = compact, level = level }
end

local function draw_elrs_hud(wide, screen_width, hud)
    local y = wide and 64 or 50
    local h = wide and 16 or 18
    local bg
    if hud.level == "ok" then
        bg = lcd.RGB(0, 70, 25)
    elseif hud.level == "error" then
        bg = lcd.RGB(115, 0, 0)
    elseif hud.level == "warning" then
        bg = lcd.RGB(105, 70, 0)
    else
        bg = lcd.RGB(45, 45, 45)
    end
    lcd.drawFilledRectangle(0, y, screen_width, h, bg)

    local max_width = screen_width - 12
    local candidates
    if wide then
        candidates = {
            { text = hud.text, font = SMLSIZE },
            { text = hud.medium, font = SMLSIZE },
            { text = hud.compact, font = SMLSIZE }
        }
    else
        candidates = {
            { text = hud.medium, font = SMLSIZE },
            { text = hud.compact, font = SMLSIZE }
        }
    end

    local selected = candidates[#candidates]
    for _, candidate in ipairs(candidates) do
        local measured_width
        if lcd.sizeText then
            local font_flags = candidate.font == 0 and BOLD or candidate.font
            measured_width = lcd.sizeText(candidate.text, font_flags)
        else
            local average_width = candidate.font == (SMLSIZE or -1) and 6 or 9
            measured_width = #candidate.text * average_width
        end
        if measured_width <= max_width then
            selected = candidate
            break
        end
    end

    lcd.drawText(
        screen_width / 2,
        y + h / 2,
        selected.text,
        CENTER + VCENTER + WHITE + (selected.font == 0 and BOLD or selected.font)
    )
end

local function resolve_profile(widget, model_name)
    local selection = widget.options.Aircraft or 1
    if selection == 2 then
        return PROFILES.S1
    elseif selection == 3 then
        return PROFILES.S2
    end

    -- Both aircraft use the same Goosky/Betafpv Nano 2.4GHz ELRS receiver target,
    -- so telemetry field presence cannot distinguish them.
    local lower_name = string.lower(model_name or "")
    if string.find(lower_name, "s2", 1, true) then
        auto_profile = PROFILES.S2
        return auto_profile
    elseif string.find(lower_name, "s1", 1, true) then
        auto_profile = PROFILES.S1
        return auto_profile
    end

    -- A 2S S1 cannot exceed 8.4V. Once a 3S voltage is seen, keep the S2 profile
    -- sticky so a deeply discharged pack cannot make the display change aircraft.
    local pack_voltage = read_sensor(SENSOR.RXBT)
    if pack_voltage > 9.0 then
        auto_profile = PROFILES.S2
    elseif pack_voltage > 0 and auto_profile == nil then
        auto_profile = PROFILES.S1
    end
    return auto_profile or PROFILES.S1
end

local function get_bank_info(widget)
    local bank_source = effective_switch_setting(widget, "BankSwitch")
    if bank_source == 0 then
        bank_info.current = 1
        return
    end

    local bank_value = getValue(bank_source) or 0
    if bank_value < -300 then
        bank_info.current = 1
    elseif bank_value > 300 then
        bank_info.current = 3
    else
        bank_info.current = 2
    end
end

local function get_bank_color(default_color)
    if bank_info.current == 1 then
        return lcd.RGB(0, 100, 255)
    elseif bank_info.current == 2 then
        return lcd.RGB(255, 165, 0)
    elseif bank_info.current == 3 then
        return lcd.RGB(255, 255, 0)
    end
    return default_color
end

local function draw_rounded_rectangle(x, y, w, h, radius, color)
    lcd.drawArc(x + radius, y + radius, radius, 270, 360, color)
    lcd.drawArc(x + radius, y + h - radius, radius, 180, 270, color)
    lcd.drawArc(x + w - radius, y + radius, radius, 0, 90, color)
    lcd.drawArc(x + w - radius, y + h - radius, radius, 90, 180, color)
    lcd.drawLine(x + radius, y, x + w - radius, y, SOLID, color)
    lcd.drawLine(x + radius, y + h, x + w - radius, y + h, SOLID, color)
    lcd.drawLine(x, y + radius, x, y + h - radius, SOLID, color)
    lcd.drawLine(x + w, y + radius, x + w, y + h - radius, SOLID, color)
end

local function clamp_percent(value)
    return math.max(0, math.min(100, value or 0))
end

local function battery_percent_from_curve(pack_voltage, cell_count, curve)
    if type(pack_voltage) ~= "number" or pack_voltage <= 0 or
       type(cell_count) ~= "number" or cell_count < 1 then
        return nil
    end

    local cell_voltage = pack_voltage / cell_count
    if cell_voltage >= curve[1][1] then
        return 100
    end

    for index = 1, #curve - 1 do
        local high = curve[index]
        local low = curve[index + 1]
        if cell_voltage >= low[1] then
            local span = high[1] - low[1]
            local position = span > 0 and (cell_voltage - low[1]) / span or 0
            return clamp_percent(low[2] + position * (high[2] - low[2]))
        end
    end

    return 0
end

local function get_battery_chemistry(widget, pack_voltage, profile)
    if simulation and type(simulation.getBatteryChemistry) == "function" then
        local simulated_chemistry = simulation.getBatteryChemistry(getTime())
        if simulated_chemistry == "lipo" or simulated_chemistry == "lihv" then
            return simulated_chemistry
        end
    end
    local source = widget.options.BatteryPct or 1
    if source == 2 then return "lipo" end
    if source == 3 then return "lihv" end

    if source == 1 and type(pack_voltage) == "number" and pack_voltage > 0 then
        local cell_voltage = pack_voltage / profile.cells
        -- A normal LiPo should never be above 4.20V/cell. A small margin avoids
        -- classifying ordinary telemetry/calibration noise as LiHV.
        if cell_voltage > 4.22 then widget.detected_chemistry = "lihv" end
    end
    return widget.detected_chemistry or profile.chemistry or "lipo"
end

local function get_battery_max_voltage(profile, chemistry)
    if chemistry == "lihv" then return profile.cells * 4.35 end
    return profile.cells * 4.20
end

local function get_pack_capacity(widget, profile)
    local configured_capacity = tonumber(widget.options.PackCap) or 0
    if configured_capacity > 0 then
        return configured_capacity
    end
    return profile.capacity
end

local function get_corrected_consumption(widget, raw_capacity)
    local adjustment = tonumber(widget.options.CapaAdj) or 0
    adjustment = math.max(-50, math.min(100, adjustment))
    return math.max(0, (raw_capacity or 0) * (1 + adjustment / 100))
end

local function get_battery_percent(widget, pack_voltage, profile, chemistry, capacity_used, capacity_available, pack_capacity)
    local sensor_percent = sensor_available(SENSOR.BATP) and read_sensor(SENSOR.BATP) or nil
    local source = widget.options.BatteryPct or 1

    -- Auto/OEM and the two explicit chemistry selections use voltage curves.
    -- The receiver-supplied Bat% value is optional because it may not know the
    -- actual cell count or chemistry fitted to the aircraft.
    if source == 4 and sensor_percent ~= nil then
        return clamp_percent(sensor_percent)
    end

    if source == 5 and capacity_available and pack_capacity > 0 then
        return clamp_percent(100 * (1 - capacity_used / pack_capacity))
    end

    local curve = chemistry == "lihv" and LIHV_SOC_CURVE or LIPO_SOC_CURVE
    local curve_percent = battery_percent_from_curve(pack_voltage, profile.cells, curve)
    if curve_percent ~= nil then
        return curve_percent
    end

    -- Preserve a useful display if RxBt is temporarily unavailable.
    return clamp_percent(sensor_percent or 0)
end

local function gauge_color(percentage)
    percentage = clamp_percent(percentage)
    return lcd.RGB(math.floor(255 - percentage * 2.55), math.floor(percentage * 2.55), 0)
end

local function draw_ring(x, y, radius, thickness, percentage)
    percentage = clamp_percent(percentage)
    local inner_radius = math.max(1, radius - thickness)
    local color = gauge_color(percentage)

    if percentage > 0 and percentage < 100 then
        lcd.drawAnnulus(x, y, inner_radius, radius, (100 - percentage) * 3.6, 360, color)
    elseif percentage >= 100 then
        lcd.drawAnnulus(x, y, inner_radius, radius, 1, 360, color)
        lcd.drawAnnulus(x, y, inner_radius, radius, -5, 5, color)
    end
end

local function draw_battery_gauge(x, y, radius, voltage, max_voltage, value_color, wide)
    local percentage = max_voltage > 0 and voltage / max_voltage * 100 or 0
    draw_ring(x, y, radius, wide and 20 or 13, percentage)
    local flags = CENTER + VCENTER + value_color + (wide and BOLD or 0)
    lcd.drawText(x, y, string.format("%.2fV", voltage), flags)
end

local function draw_fuel_gauge(x, y, radius, capacity, percentage, value_color, wide)
    percentage = clamp_percent(percentage)
    draw_ring(x, y, radius, wide and 24 or 25, percentage)

    local percent_flags = CENTER + VCENTER + value_color + (wide and BOLD or DBLSIZE)
    lcd.drawText(x, y - (wide and 7 or 10), string.format("%d%%", round_number(percentage)), percent_flags)
    lcd.drawText(x, y + (wide and 19 or 15), string.format("%dmAh", round_number(capacity)), CENTER + VCENTER + SMLSIZE + value_color)
end

local function fitted_gauge_font(text, preferred, max_width)
    if lcd.sizeText and lcd.sizeText(text, preferred) > max_width then
        return SMLSIZE
    end
    return preferred
end

local function draw_flight_battery_gauge(x, y, radius, capacity, percentage, voltage, value_color, available)
    if not available then
        draw_ring(x, y, radius, 3, 0)
        lcd.drawText(x, y, "---", CENTER + VCENTER + BOLD + value_color)
        return
    end
    percentage = clamp_percent(percentage)
    local thickness = 7
    local safe_text_width = (radius - thickness - 5) * 2
    local percent_text = string.format("%d%%", round_number(percentage))
    local voltage_text = string.format("%.2fV", voltage)
    local capacity_text = string.format("%dmAh", round_number(capacity))

    draw_ring(x, y, radius, thickness, percentage)
    lcd.drawText(x, y - 24, percent_text, CENTER + VCENTER + fitted_gauge_font(percent_text, BOLD, safe_text_width) + value_color)
    lcd.drawText(x, y, voltage_text, CENTER + VCENTER + fitted_gauge_font(voltage_text, BOLD, safe_text_width) + value_color)
    lcd.drawText(x, y + 24, capacity_text, CENTER + VCENTER + fitted_gauge_font(capacity_text, SMLSIZE, safe_text_width) + value_color)
end

local function draw_rqly_bars(x, y, rqly_percent, default_color, wide)
    local block_size = wide and 10 or 5
    local block_spacing = wide and 14 or 7
    rqly_percent = clamp_percent(rqly_percent)
    local active_blocks = math.floor((rqly_percent + 19) / 20)

    for i = 1, 5 do
        local block_color = default_color
        if rqly_percent > 0 and i <= active_blocks then
            if i == 1 then
                block_color = RED
            elseif i == 2 then
                block_color = ORANGE
            elseif i == 3 then
                block_color = YELLOW
            elseif i == 4 then
                block_color = lcd.RGB(173, 255, 47)
            else
                block_color = GREEN
            end
        end
        lcd.drawFilledRectangle(x + (i - 1) * block_spacing, y, block_size, block_size, block_color)
    end
end

local function status_help_enabled(widget)
    return (widget.options.StatusHelp or 1) ~= 3
end

local function status_color(level)
    if level == "critical" then return RED end
    if level == "warning" then return YELLOW end
    if level == "neutral" then return WHITE end
    return GREEN
end

local function update_splash_leds()
    if not LED_STRIP_LENGTH or LED_STRIP_LENGTH <= 0
        or type(setRGBLedColor) ~= "function"
        or type(applyRGBLedColors) ~= "function" then
        return nil
    end

    -- EdgeTX exposes the two gimbal/decorative rings first and SW1-SW6 as the
    -- final six LEDs. During the short branding splash, run a red comet around
    -- both gimbals and a red ping-pong (Knight Rider) sweep over SW1-SW6.
    local function_led_count = LED_STRIP_LENGTH >= 26 and 6 or 0
    local system_led_count = LED_STRIP_LENGTH - function_led_count
    local now = getTime()
    local ring_phase = math.floor(now / 8)
    local switch_phase = math.floor(now / 10)
    local signature = "splash:" .. tostring(ring_phase) .. ":" .. tostring(switch_phase)
    if led_cache.signature == signature then return led_cache.buttons_ready end

    for index = 0, LED_STRIP_LENGTH - 1 do
        pcall(setRGBLedColor, index, 0, 0, 0)
    end

    local ring_count = system_led_count >= 20 and 2 or 1
    local ring_start = 0
    local comet_red = { 255, 110, 35 }
    for ring = 1, ring_count do
        local ring_size = ring == ring_count
            and (system_led_count - ring_start)
            or math.floor(system_led_count / ring_count)
        if ring_size > 0 then
            local head = ring_phase % ring_size
            for tail = 0, #comet_red - 1 do
                local offset = (head - tail) % ring_size
                pcall(setRGBLedColor, ring_start + offset, comet_red[tail + 1], 0, 0)
            end
        end
        ring_start = ring_start + ring_size
    end

    local buttons_ready = function_led_count == 6
    if function_led_count == 6 then
        local sweep = { 0, 1, 2, 3, 4, 5, 4, 3, 2, 1 }
        local head = sweep[(switch_phase % #sweep) + 1]
        for segment = 0, 5 do
            local distance = math.abs(segment - head)
            local red = distance == 0 and 255 or (distance == 1 and 55 or 0)
            local ok, accepted = pcall(setRGBLedColor,
                system_led_count + segment, red, 0, 0)
            if not ok or accepted == false then buttons_ready = false end
        end
    end

    pcall(applyRGBLedColors)
    led_cache.signature = signature
    led_cache.buttons_ready = buttons_ready
    return buttons_ready
end

local function update_status_leds(widget, level, battery_available, battery_percent)
    if not LED_STRIP_LENGTH or LED_STRIP_LENGTH <= 0
        or type(setRGBLedColor) ~= "function"
        or type(applyRGBLedColors) ~= "function" then
        return nil
    end

    -- EdgeTX 2.12 exposes 20 decorative/gimbal LEDs followed by the six RGB
    -- function-switch LEDs on TX16S MK3 and TX15. Keep the gimbals on overall
    -- safety status and turn buttons 1-6 into a battery fuel gauge whenever
    -- valid battery telemetry is available.
    local led_enabled = (widget.options.StatusHelp or 1) == 1
    local requested_level = led_enabled and (level or "warning") or "off"
    local function_led_count = LED_STRIP_LENGTH >= 26 and 6 or 0
    local system_led_count = LED_STRIP_LENGTH - function_led_count
    local clamped_percent = math.max(0, math.min(100, tonumber(battery_percent) or 0))
    local battery_segments = 0
    if led_enabled and battery_available and function_led_count > 0 then
        battery_segments = math.ceil(clamped_percent * function_led_count / 100)
        if battery_segments == 0 then battery_segments = 1 end
    end
    local signature = table.concat({
        requested_level,
        battery_available and "battery" or "status",
        tostring(battery_segments),
        clamped_percent <= 15 and "red" or (clamped_percent <= 30 and "yellow" or "green")
    }, ":")
    local now = getTime()
    if led_cache.signature == signature then return led_cache.buttons_ready end
    if led_cache.buttons_ready == false and now < (led_cache.retry_at or 0) then
        return false
    end

    local red, green, blue = 0, 0, 0
    if requested_level == "ok" then
        red, green, blue = 0, 190, 0
    elseif requested_level == "neutral" then
        red, green, blue = 190, 190, 190
    elseif requested_level == "warning" then
        red, green, blue = 255, 150, 0
    elseif requested_level == "critical" then
        red, green, blue = 255, 0, 0
    end

    for i = 0, system_led_count - 1 do
        pcall(setRGBLedColor, i, red, green, blue)
    end

    local buttons_ready = function_led_count == 6
    for segment = 1, function_led_count do
        -- SW1-SW6 are battery-only indicators. Keep them dark during prestart
        -- checks and whenever valid battery telemetry is unavailable; overall
        -- system state remains on the gimbal/decorative LEDs.
        local segment_red, segment_green, segment_blue = 0, 0, 0
        if led_enabled and battery_available then
            if segment > battery_segments then
                segment_red, segment_green, segment_blue = 0, 0, 0
            elseif clamped_percent <= 15 then
                segment_red, segment_green, segment_blue = 255, 0, 0
            elseif clamped_percent <= 30 then
                segment_red, segment_green, segment_blue = 255, 150, 0
            else
                segment_red, segment_green, segment_blue = 0, 190, 0
            end
        end
        -- EdgeTX exposes the six function-switch LEDs as the final six virtual
        -- strip indices on TX15 and TX16S MK3. A write returns false while the
        -- corresponding switch type is not None. Do not cache that failure:
        -- after the pilot fixes SW1-SW6 the bar must begin working without a
        -- widget reload.
        local call_ok, accepted = pcall(setRGBLedColor,
            system_led_count + segment - 1,
            segment_red, segment_green, segment_blue)
        if not call_ok or accepted == false then buttons_ready = false end
    end
    pcall(applyRGBLedColors)
    led_cache.buttons_ready = buttons_ready
    if buttons_ready then
        led_cache.signature = signature
        led_cache.retry_at = 0
    else
        led_cache.signature = nil
        led_cache.retry_at = now + 100
    end
    return buttons_ready
end

local function get_hold_on(widget)
    local hold_switch = effective_switch_setting(widget, "HoldSwitch")
    if hold_switch == 0 then
        return false
    end
    local switch_value = getSwitchValue(hold_switch)
    return switch_value and switch_value ~= 0 and switch_value ~= false
end

local function get_final_throttle_output()
    -- getValue("ch3") exposes the mixer channel source, which does not include
    -- Special Function channel overrides. getOutputValue(2) reads the final
    -- transmitted CH3 output shown by EdgeTX's Outputs page, including SF1's
    -- throttle-hold override. EdgeTX 2.12 provides this API; retain getValue as
    -- a compatibility fallback for older firmware.
    if type(getOutputValue) == "function" then
        local ok, value = pcall(getOutputValue, 2)
        if ok and type(value) == "number" then return value end
    end
    return getValue("ch3")
end

local function get_throttle_active()
    local throttle_value = get_final_throttle_output()

    if type(throttle_value) == "boolean" then
        return throttle_value
    end
    return type(throttle_value) == "number" and throttle_value > THROTTLE_ACTIVE_THRESHOLD
end

local function get_throttle_at_safe_minimum()
    local throttle_value = get_final_throttle_output()
    return type(throttle_value) == "number" and throttle_value <= THROTTLE_SAFE_MINIMUM,
        throttle_value
end

local function get_motor_state(widget)
    local hold_on = get_hold_on(widget)
    local throttle_active = get_throttle_active()
    return (not hold_on and throttle_active), hold_on, throttle_active
end

local function get_goosky_pose_mode()
    local channel_value = getValue("ch5")
    local attitude = type(channel_value) == "number" and channel_value > ATTITUDE_MODE_THRESHOLD
    if attitude then
        return "ATT", GREEN
    end
    return "3D", ORANGE
end

local function update_timer_reset(widget)
    local reset_switch = effective_switch_setting(widget, "TimerReset")
    if reset_switch == 0 then
        timer_reset_was_active = false
        return false, false
    end

    local switch_value = getSwitchValue(reset_switch)
    local reset_active = switch_value and switch_value ~= 0 and switch_value ~= false
    local reset_pressed = reset_active and not timer_reset_was_active
    if reset_active then
        power_max = 0
        if reset_pressed and model.resetTimer then
            model.resetTimer(0)
            model.resetTimer(1)
        end
    end
    timer_reset_was_active = reset_active
    return reset_active, reset_pressed
end

local function acknowledge_completed_flight(widget)
    -- RESET is also the explicit end-of-flight acknowledgement. Clearing the
    -- session history returns an intentionally powered-down receiver to the
    -- quiet bench state and prevents repeating offline haptics. The caller
    -- permits this only with throttle hold on and native TELE inactive.
    widget.receiver_ever_seen = false
    widget.battery_ever_seen = false
    widget.detected_chemistry = nil
    widget.stable_status_level = nil
    widget.stable_status_message = nil
    widget.status_recovery_level = nil
    widget.status_recovery_message = nil
    widget.status_recovery_started = nil
    widget.last_haptic_level = nil
    widget.next_status_haptic = nil
    power_max = 0
end

local function format_timer(seconds)
    if type(seconds) ~= "number" then
        return "--:--"
    end

    local sign = seconds < 0 and "-" or ""
    local absolute = math.abs(round_number(seconds))
    local hours = math.floor(absolute / 3600)
    local minutes = math.floor((absolute % 3600) / 60)
    local remaining_seconds = absolute % 60

    if hours > 0 then
        return string.format("%s%d:%02d:%02d", sign, hours, minutes, remaining_seconds)
    end
    return string.format("%s%02d:%02d", sign, minutes, remaining_seconds)
end

local function get_model_timer(index)
    if not model.getTimer then
        return nil
    end
    return model.getTimer(index)
end

local function optional_rssi_text(index)
    if not sensor_available(index) then return "---" end
    local value = read_sensor(index)
    -- ELRS receivers commonly expose the second antenna sensor even on
    -- single-antenna hardware. A constant zero is not a second failed link.
    if type(value) ~= "number" or value == 0 then return "---" end
    return string.format("%ddB", round_number(value))
end

local function rotor_rpm_text(profile)
    if not profile or profile.name ~= "S2 MAX" then return nil end
    local index = sensor_available(SENSOR.RPM) and SENSOR.RPM or SENSOR.GALT
    if not sensor_available(index) then return "---" end
    local value = read_sensor(index)
    if type(value) ~= "number" or value <= 0 then return "---" end
    return string.format("%d", round_number(value))
end

local function classify_link(rqly_percent, rqly_available, telemetry_active, motor_running, receiver_ever_seen)
    -- EdgeTX TELE is authoritative for whether the receiver stream exists.
    -- RQly may be absent simply because this new model has not run Discover
    -- New Sensors yet; that is unknown data, not an offline receiver.
    if not telemetry_active then
        if not receiver_ever_seen then return "neutral", "---" end
        if motor_running then return "critical", "LOST" end
        return "warning", "OFFLINE"
    elseif not rqly_available or rqly_percent <= 0 then
        return "neutral", "---"
    elseif rqly_percent < 50 then
        return "critical", "CRITICAL"
    elseif rqly_percent < 80 then
        return "warning", "WEAK"
    elseif rqly_percent < 95 then
        return "warning", "FAIR"
    end
    return "ok", "GOOD"
end

local function classify_telemetry_return(tqly_percent, available, receiver_online, receiver_ever_seen)
    if not receiver_online then
        if not receiver_ever_seen then return "neutral", "---" end
        return "warning", "OFFLINE"
    end
    if not available then return "neutral", "---" end
    if tqly_percent <= 0 then return "warning", "LOST" end
    if tqly_percent < 50 then return "warning", "POOR" end
    if tqly_percent < 80 then return "warning", "WEAK" end
    if tqly_percent < 95 then return "warning", "FAIR" end
    return "ok", "GOOD"
end

local function classify_battery(battery_voltage, battery_percent, available, motor_running, battery_ever_seen)
    if not available or battery_voltage <= 0 then
        if not battery_ever_seen then return "neutral", "---" end
        if motor_running then return "critical", "NO DATA" end
        return "warning", "NO DATA"
    elseif battery_percent <= 10 then
        return "critical", "CRITICAL"
    elseif battery_percent <= 20 then
        return "warning", "LOW"
    end
    return "ok", "GOOD"
end

local function model_match_is_enabled()
    local setting = elrs_state.settings["Model Match"]
    return setting and string.lower(clean_setting_text(setting.value)) == "on"
end

local function overall_dashboard_status(readings)
    if not readings.receiver_ever_seen then
        return "neutral", "WAITING FOR RECEIVER"
    end
    if readings.adc_filter_ok == false then
        return "warning", "SETUP: ADC FILTER MUST BE OFF"
    end
    if model_match_is_enabled() and elrs_state.model_mismatch then
        return "critical", "DANGER: MODEL MATCH MISMATCH"
    end
    if readings.link_level == "critical" then
        return "critical", "DANGER: ELRS LINK " .. readings.link_text
    end
    if readings.battery_level == "critical" then
        if readings.battery_text == "NO DATA" then
            return "critical", "DANGER: BATTERY TELEMETRY LOST"
        end
        return "critical", "LAND NOW: BATTERY CRITICAL"
    end
    if readings.motor_running and readings.timer1_countdown
        and type(readings.timer1_value) == "number" and readings.timer1_value <= 0 then
        return "critical", "LAND NOW: FLIGHT TIME LIMIT"
    end
    if readings.link_level == "warning" then
        if readings.link_text == "OFFLINE" then
            if readings.hold_on then
                return "warning", "RECEIVER OFFLINE - RESET TO END FLIGHT"
            end
            return "warning", "CAUTION: RECEIVER OFFLINE"
        end
        return "warning", "CAUTION: ELRS LINK " .. readings.link_text
    end
    if readings.battery_level == "warning" then
        if readings.battery_text == "NO DATA" then
            return "warning", "CAUTION: BATTERY DATA UNAVAILABLE"
        end
        return "warning", "CAUTION: BATTERY LOW"
    end
    if readings.telemetry_level == "warning" and readings.link_text ~= "OFFLINE" then
        return "warning", "CAUTION: TELEMETRY RETURN " .. readings.telemetry_text
    end
    if elrs_fix_required() then
        return "warning", "SETUP: ELRS SETTINGS NEED REPAIR"
    end
    if not readings.telemetry_sensors_ready then
        return "neutral", "DISCOVER TELEMETRY SENSORS"
    end
    if not elrs_state.device_found or not target_settings_complete() then
        -- ELRS setup interrogation is pre-link only. An incomplete/unknown
        -- check is never a flight warning and must not trigger LEDs/haptics.
        return readings.telemetry_active and "ok" or "neutral",
            readings.telemetry_active and "SYSTEM READY" or "ELRS PREFLIGHT PENDING"
    end
    return "ok", "SYSTEM READY"
end

local STATUS_RANK = { neutral = 0, ok = 1, warning = 2, critical = 3 }

local function stabilize_dashboard_status(widget, level, message)
    local now = getTime()
    if not widget.stable_status_level then
        widget.stable_status_level = level
        widget.stable_status_message = message
        return level, message
    end

    local current_rank = STATUS_RANK[widget.stable_status_level] or 0
    local requested_rank = STATUS_RANK[level] or 0
    if requested_rank >= current_rank then
        -- Escalation is immediate. Equal severity may replace the message with
        -- a newly higher-priority cause selected by overall_dashboard_status.
        widget.stable_status_level = level
        widget.stable_status_message = message
        widget.status_recovery_level = nil
        return level, message
    end

    -- Require two seconds of continuous improvement before clearing or
    -- downgrading an alert. This prevents link/battery telemetry jitter from
    -- making the lights and banner flicker between states.
    if widget.status_recovery_level ~= level then
        widget.status_recovery_level = level
        widget.status_recovery_message = message
        widget.status_recovery_started = now
    elseif now - (widget.status_recovery_started or now) >= 200 then
        widget.stable_status_level = level
        widget.stable_status_message = widget.status_recovery_message
        widget.status_recovery_level = nil
    end
    return widget.stable_status_level, widget.stable_status_message
end

local function update_status_haptic(widget, level)
    -- Haptics follow the same full Status Help mode as the gimbal LEDs. Only
    -- severity transitions trigger feedback so the fast widget refresh cannot
    -- create a continuous vibration.
    if (widget.options.StatusHelp or 1) ~= 1 or type(playHaptic) ~= "function" then
        widget.last_haptic_level = nil
        return
    end
    local now = getTime()
    local changed = widget.last_haptic_level ~= level
    if changed then widget.last_haptic_level = level end

    if level == "critical" and (changed or now >= (widget.next_status_haptic or 0)) then
        playHaptic(240, 100)
        playHaptic(240, 0)
        widget.next_status_haptic = now + 500
    elseif level == "warning" and (changed or now >= (widget.next_status_haptic or 0)) then
        playHaptic(120, 0)
        widget.next_status_haptic = now + 3000
    elseif level == "ok" or level == "neutral" then
        widget.next_status_haptic = nil
    end
end

local function get_model_bitmap(model_name, model_bitmap_name, wide)
    local layout_name = wide and "wide" or "compact"
    local image_name = string.match(tostring(model_bitmap_name or ""), "([^/\\]+)$") or ""
    local cache_key = tostring(model_name or "") .. "|" .. image_name
    if cached_model_name == cache_key and cached_layout == layout_name then
        return cached_model_bitmap or assets[layout_name].default
    end

    cached_model_name = cache_key
    cached_layout = layout_name
    cached_model_bitmap = nil

    -- GooskySetup stores the selected orange/blue/purple image in the native
    -- EdgeTX model bitmap field. Prefer the matching dashboard-sized asset,
    -- then fall back to the native /IMAGES model thumbnail.
    if image_name ~= "" then
        if wide then
            local stem, extension = string.match(image_name, "^(.*)(%.[^%.]+)$")
            if stem and extension then
                cached_model_bitmap = open_model_image(stem .. "_800" .. extension)
            end
        end
        if not cached_model_bitmap then
            cached_model_bitmap = open_model_image(image_name)
        end
    end

    -- Retain support for manually supplied widget-local images named after
    -- the EdgeTX model.
    if not cached_model_bitmap and wide then
        cached_model_bitmap = open_bitmap(model_name .. "_800.png")
    end
    if not cached_model_bitmap then
        cached_model_bitmap = open_bitmap(model_name .. ".png")
    end
    return cached_model_bitmap or assets[layout_name].default
end

local function current_elrs_mismatch_key()
    local rate = elrs_state.settings["Packet Rate"]
    local telem = elrs_state.settings["Telem Ratio"]
    local switch = elrs_state.settings["Switch Mode"]
    local power = elrs_state.settings["Max Power"]
    local antenna = elrs_state.settings["Antenna Mode"]
    local _, dynamic = get_dynamic_setting()
    if not rate or not telem or not switch or not power or not dynamic
        or not elrs_fix_required() then
        return nil
    end
    return tostring(rate.value) .. "|" .. tostring(telem.value) .. "|" .. tostring(switch.value)
        .. "|" .. tostring(power.value) .. "|" .. tostring(dynamic.value)
        .. "|" .. tostring(antenna and antenna.value or "-")
end

local function update_elrs_warning_dialog(widget, hold_on, throttle_active)
    local mismatch_key = current_elrs_mismatch_key()
    if not mismatch_key then
        widget.elrs_prompt_dismissed = nil
        if elrs_state.fix.stage == "idle" then widget.elrs_dialog = false end
        return
    end

    -- Once a mismatch dialog has opened, keep it latched. EdgeTX can expose a
    -- changing mixer source to Lua even while a Special Function overrides the
    -- transmitted CH3 output to -100. Re-evaluating that source every frame
    -- made stick movement incorrectly erase an already-visible warning.
    if widget.elrs_dialog then return end

    -- Hide the modal only while the motor-running condition is true. CH3 can
    -- remain above 20% on a flat helicopter throttle curve even while hold is
    -- active; that must not suppress the ELRS warning.
    if not hold_on and throttle_active then
        if elrs_state.fix.stage == "idle" then widget.elrs_dialog = false end
        return
    end
    if elrs_state.fix.stage == "idle" and widget.elrs_prompt_dismissed ~= mismatch_key then
        if not widget.elrs_dialog then
            widget.elrs_dialog_choice = 2
            widget.elrs_dialog_opened = getTime()
        end
        widget.elrs_dialog = true
    end
end

local function point_in_rect(x, y, rx, ry, rw, rh)
    return x and y and x >= rx and x <= rx + rw and y >= ry and y <= ry + rh
end

local function event_matches(event, candidate)
    return type(candidate) == "number" and event == candidate
end

local function touch_hits_rect(widget, touch_state, rx, ry, rw, rh)
    if not touch_state then return false end
    local x = touch_state.x or touch_state.startX
    local y = touch_state.y or touch_state.startY
    if point_in_rect(x, y, rx, ry, rw, rh) then return true end

    -- App Mode supplies full-screen coordinates while widget.zone can retain
    -- the original dashboard position. Also accept genuine zone-local input.
    if widget.zone and x and y then
        return point_in_rect(x - (widget.zone.x or 0), y - (widget.zone.y or 0), rx, ry, rw, rh)
    end
    return false
end

local function activate_elrs_dialog_choice(widget, choice, hold_on)
    widget.elrs_dialog_choice = choice

    local fix = elrs_state.fix
    if fix.stage == "complete" or fix.stage == "error" then
        widget.elrs_prompt_dismissed = current_elrs_mismatch_key()
        widget.elrs_dialog = false
        widget.elrs_dialog_message = ""
        elrs_state.fix = { stage = "idle", deadline = 0, message = "" }
        return
    elseif fix.stage ~= "idle" then
        return
    end

    if choice == 1 then
        local started, message = begin_elrs_fix(hold_on)
        widget.elrs_dialog_message = started and "" or message
    else
        widget.elrs_prompt_dismissed = current_elrs_mismatch_key()
        widget.elrs_dialog = false
        widget.elrs_dialog_message = ""
    end
end

local function handle_input(widget, event, touch_state, wide, hold_on)
    local touch_tap = event_matches(event, EVT_TOUCH_TAP)
    local touch_break = event_matches(event, EVT_TOUCH_BREAK)

    if not widget.elrs_dialog then
        -- App Mode owns touch input, so Lua cannot directly open EdgeTX's
        -- native Widget Settings menu. A long press exits to the dashboard.
        if touch_break and lcd.exitFullScreen then lcd.exitFullScreen() end
        return
    end

    -- Ignore the press/touch that EdgeTX used to enter App Mode. Without this
    -- short guard, the dialog can open and instantly activate its default NO
    -- choice on the same frame, making the warning appear to be missing.
    local dialog_age = getTime() - (widget.elrs_dialog_opened or 0)
    if dialog_age < 50 and (touch_tap or touch_break
        or event_matches(event, EVT_VIRTUAL_ENTER)
        or event_matches(event, EVT_ENTER_FIRST)
        or event_matches(event, EVT_ENTER_BREAK)) then
        return
    end

    if (elrs_state.fix.stage == "complete" or elrs_state.fix.stage == "error")
        and (touch_tap or touch_break) then
        activate_elrs_dialog_choice(widget, widget.elrs_dialog_choice or 2, hold_on)
        return
    end

    if event_matches(event, EVT_VIRTUAL_PREV)
        or event_matches(event, EVT_ROT_LEFT)
        or event_matches(event, EVT_MINUS_FIRST)
        or event_matches(event, EVT_MINUS_REPT) then
        widget.elrs_dialog_choice = 1
        return
    elseif event_matches(event, EVT_VIRTUAL_NEXT)
        or event_matches(event, EVT_ROT_RIGHT)
        or event_matches(event, EVT_PLUS_FIRST)
        or event_matches(event, EVT_PLUS_REPT) then
        widget.elrs_dialog_choice = 2
        return
    elseif event_matches(event, EVT_VIRTUAL_ENTER)
        or event_matches(event, EVT_ENTER_FIRST)
        or event_matches(event, EVT_ENTER_BREAK) then
        activate_elrs_dialog_choice(widget, widget.elrs_dialog_choice or 2, hold_on)
        return
    end

    if not touch_tap and not touch_break then return end

    local yes_x, no_x = wide and 245 or 95, wide and 425 or 275
    local button_y = wide and 326 or 230
    local button_w, button_h = wide and 130 or 110, wide and 46 or 40
    if touch_hits_rect(widget, touch_state, yes_x, button_y, button_w, button_h) then
        activate_elrs_dialog_choice(widget, 1, hold_on)
    elseif touch_hits_rect(widget, touch_state, no_x, button_y, button_w, button_h) then
        activate_elrs_dialog_choice(widget, 2, hold_on)
    end
end

local function draw_elrs_dialog_button(x, y, w, h, label, selected, base_color)
    local fill_color = selected and lcd.RGB(255, 190, 0) or base_color
    local text_color = selected and BLACK or WHITE
    lcd.drawFilledRectangle(x, y, w, h, fill_color)

    if selected then
        -- Bright outer halo, thick white boundary, and inward black keyline
        -- make the rotary selection unmistakable on both screen sizes.
        lcd.drawRectangle(x - 4, y - 4, w + 8, h + 8, YELLOW, 3)
        lcd.drawRectangle(x, y, w, h, WHITE, 3)
        lcd.drawRectangle(x + 5, y + 5, w - 10, h - 10, BLACK, 2)
    else
        lcd.drawRectangle(x, y, w, h, WHITE)
    end

    local button_text = selected and ("> " .. label .. " <") or label
    lcd.drawText(x + w / 2, y + h / 2, button_text, CENTER + VCENTER + BOLD + text_color)
end

local ELRS_DIALOG_ROWS = {
    { key = "rate", label = "RATE" },
    { key = "channels", label = "CHANNELS" },
    { key = "telemetry", label = "TELEMETRY" },
    { key = "power", label = "POWER" },
    { key = "dynamic", label = "DYNAMIC" }
}

local ELRS_ANTENNA_DIALOG_ROW = { key = "antenna", label = "ANTENNA" }

local function elrs_dialog_rows(show_antenna)
    local rows = {}
    for _, row in ipairs(ELRS_DIALOG_ROWS) do rows[#rows + 1] = row end
    if show_antenna then rows[#rows + 1] = ELRS_ANTENNA_DIALOG_ROW end
    return rows
end

local function elrs_dialog_value_matches(key, value)
    if value == nil or value == "?" then return nil end
    if key == "rate" then return elrs_rate_is_target(value) end
    if key == "channels" then return elrs_switch_is_target(value) end
    if key == "telemetry" then return elrs_telem_is_target(value) end
    if key == "power" then return elrs_power_is_target(value) end
    if key == "dynamic" then return elrs_dynamic_is_target(value) end
    if key == "antenna" then return elrs_antenna_is_target(value) end
    return false
end

local function elrs_dialog_value(value, key, wide)
    value = tostring(value or "?")
    if not wide and key == "rate" then
        value = string.gsub(value, "Hz", "")
        value = string.gsub(value, "%s+2%.4G", "")
    end
    return value
end

local function draw_elrs_settings_box(x, y, w, h, title, values, wide, recommended, rows)
    local border = recommended and lcd.RGB(0, 185, 70) or lcd.RGB(205, 205, 205)
    local horizontal_padding = wide and 16 or 12
    lcd.drawFilledRectangle(x, y, w, h, lcd.RGB(14, 17, 20))
    lcd.drawRectangle(x, y, w, h, border, wide and 2 or 1)
    lcd.drawText(x + w / 2, y + (wide and 18 or 13), title,
        CENTER + VCENTER + (wide and BOLD or SMLSIZE) + WHITE)
    local line_y = y + (wide and 37 or 27)
    lcd.drawLine(x + 8, line_y, x + w - 8, line_y, SOLID, border)
    -- Keep the fifth row clear of the bottom border. EdgeTX's SMLSIZE glyphs
    -- extend below their y anchor, so the former 23/17-pixel spacing left the
    -- DYNAMIC row touching the outline on both radio sizes.
    local six_rows = #rows > 5
    local first_row = line_y + (six_rows and (wide and 9 or 6) or (wide and 12 or 8))
    local row_step = six_rows and (wide and 18 or 14) or (wide and 20 or 15)
    for index, row in ipairs(rows) do
        local value = elrs_dialog_value(values[row.key], row.key, wide)
        local matches = elrs_dialog_value_matches(row.key, value)
        local value_color = recommended and GREEN
            or (matches == nil and YELLOW or (matches and GREEN or RED))
        local row_y = first_row + (index - 1) * row_step
        lcd.drawText(x + horizontal_padding, row_y, row.label, SMLSIZE + WHITE)
        lcd.drawText(x + w - horizontal_padding, row_y, value,
            RIGHT + SMLSIZE + value_color)
    end
end

local function draw_elrs_warning_dialog(widget, wide, screen_width, screen_height, square_color)
    local fix = elrs_state.fix
    local current = current_elrs_display_values()
    local original = fix.original or current
    local left_values = fix.stage == "idle" and current or original
    local right_values = fix.stage == "idle" and ELRS_RECOMMENDED or current
    local left_title = fix.stage == "idle" and "CURRENT SETTINGS" or "ORIGINAL SETTINGS"
    local right_title = fix.stage == "idle" and "RECOMMENDED" or
        (fix.stage == "complete" and "VERIFIED CURRENT" or "CURRENT READBACK")
    local title = fix.stage == "idle" and "ELRS SETTINGS MISMATCH"
        or (fix.stage == "complete" and "ELRS SETTINGS VERIFIED"
        or (fix.stage == "error" and "ELRS CHANGE NOT VERIFIED"
        or "UPDATING ELRS SETTINGS"))
    local frame_color = fix.stage == "complete" and GREEN
        or (fix.stage == "idle" or fix.stage == "error") and RED or YELLOW
    local show_antenna = current.antenna ~= nil or original.antenna ~= nil
    local dialog_rows = elrs_dialog_rows(show_antenna)
    local verified_count = show_antenna and 6 or 5

    if wide then
        lcd.drawFilledRectangle(70, 48, 660, 388, lcd.RGB(8, 12, 15))
        lcd.drawRectangle(70, 48, 660, 388, frame_color, 3)
        lcd.drawText(screen_width / 2, 76, title, CENTER + MIDSIZE + frame_color)
        draw_elrs_settings_box(92, 112, 292, 164, left_title, left_values, true, false,
            dialog_rows)
        draw_elrs_settings_box(416, 112, 292, 164, right_title, right_values, true,
            fix.stage == "idle" or fix.stage == "complete", dialog_rows)

        if fix.stage == "idle" then
            local warning = widget.elrs_dialog_message
            if warning == "" then
                if elrs_link_connected() then
                    warning = "POWER OFF HELICOPTER BEFORE SELECTING YES"
                elseif elrs_state.status_seen and elrs_state.armed then
                    warning = "SET CH5 TO 3D (-100) BEFORE SELECTING YES"
                else
                    warning = "Apply the recommended settings now?"
                end
            end
            lcd.drawText(screen_width / 2, 294, warning, CENTER + BOLD
                + (warning == "Apply the recommended settings now?" and YELLOW or RED))
            draw_elrs_dialog_button(245, 326, 130, 46, "YES", widget.elrs_dialog_choice == 1, lcd.RGB(0, 90, 25))
            draw_elrs_dialog_button(425, 326, 130, 46, "NO", widget.elrs_dialog_choice == 2, lcd.RGB(105, 0, 0))
            lcd.drawText(screen_width / 2, 398, "Touch a button, or turn wheel and press", CENTER + SMLSIZE + WHITE)
        elseif fix.stage == "complete" then
            lcd.drawText(screen_width / 2, 298,
                tostring(verified_count) .. " OF " .. tostring(verified_count) .. " SETTINGS MATCH",
                CENTER + BOLD + GREEN)
            lcd.drawText(screen_width / 2, 366, "Press wheel or tap to close", CENTER + BOLD + WHITE)
        elseif fix.stage == "error" then
            lcd.drawText(screen_width / 2, 292, fix.message, CENTER + BOLD + RED)
            lcd.drawText(screen_width / 2, 326, "Check the values above or use ExpressLRS Lua", CENTER + SMLSIZE + WHITE)
            lcd.drawText(screen_width / 2, 374, "Press wheel or tap to close", CENTER + BOLD + WHITE)
        else
            lcd.drawText(screen_width / 2, 296, fix.message, CENTER + BOLD + YELLOW)
            lcd.drawText(screen_width / 2, 338, "KEEP RECEIVER POWERED OFF", CENTER + BOLD + RED)
        end
    else
        lcd.drawFilledRectangle(15, 36, screen_width - 30, screen_height - 46, lcd.RGB(8, 12, 15))
        lcd.drawRectangle(15, 36, screen_width - 30, screen_height - 46, frame_color, 2)
        lcd.drawText(screen_width / 2, 55, title, CENTER + BOLD + frame_color)
        draw_elrs_settings_box(28, 78, 205, 122, left_title, left_values, false, false,
            dialog_rows)
        draw_elrs_settings_box(247, 78, 205, 122, right_title, right_values, false,
            fix.stage == "idle" or fix.stage == "complete", dialog_rows)
        if fix.stage == "idle" then
            local compact_warning = widget.elrs_dialog_message
            if compact_warning == "" then
                if elrs_link_connected() then
                    compact_warning = "Power RX off before YES"
                elseif elrs_state.status_seen and elrs_state.armed then
                    compact_warning = "Set CH5 to 3D before YES"
                else
                    compact_warning = "Apply recommended settings?"
                end
            end
            lcd.drawText(screen_width / 2, 210, compact_warning, CENTER + SMLSIZE + YELLOW)
            draw_elrs_dialog_button(95, 230, 110, 40, "YES", widget.elrs_dialog_choice == 1, lcd.RGB(0, 90, 25))
            draw_elrs_dialog_button(275, 230, 110, 40, "NO", widget.elrs_dialog_choice == 2, lcd.RGB(105, 0, 0))
        elseif fix.stage == "complete" then
            lcd.drawText(screen_width / 2, 216,
                tostring(verified_count) .. " OF " .. tostring(verified_count) .. " SETTINGS MATCH",
                CENTER + BOLD + GREEN)
            lcd.drawText(screen_width / 2, 270, "Press wheel or tap to close", CENTER + SMLSIZE + WHITE)
        elseif fix.stage == "error" then
            lcd.drawText(screen_width / 2, 212, fix.message, CENTER + SMLSIZE + RED)
            lcd.drawText(screen_width / 2, 244, "Check values or use ExpressLRS Lua", CENTER + SMLSIZE + WHITE)
            lcd.drawText(screen_width / 2, 278, "Press wheel or tap to close", CENTER + SMLSIZE + WHITE)
        else
            lcd.drawText(screen_width / 2, 214, fix.message, CENTER + SMLSIZE + YELLOW)
            lcd.drawText(screen_width / 2, 246, "KEEP RECEIVER OFF", CENTER + BOLD + RED)
        end
    end
end

local function fit_text(value, max_width, flags)
    local text = tostring(value or "")
    if not lcd.sizeText or lcd.sizeText(text, flags) <= max_width then
        return text
    end
    while #text > 1 and lcd.sizeText(text .. "...", flags) > max_width do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. "..."
end

local function draw_header(widget, wide, screen_width, square_color, value_color, tx_voltage, rqly_percent, model_name, pose_mode, pose_color, link_text, link_level)
    local layout_assets = wide and assets.wide or assets.compact
    if layout_assets.title then
        lcd.drawBitmap(layout_assets.title, 0, 0)
    else
        lcd.drawFilledRectangle(0, 0, screen_width, wide and 64 or 50, lcd.RGB(10, 18, 20))
    end

    local now = getDateTime()
    local time_str = string.format("%02d:%02d:%02d", now.hour, now.min, now.sec)
    get_bank_info(widget)
    local bank_color = get_bank_color(square_color)

    local tx_color = value_color
    if tx_voltage < 6.5 then
        tx_color = RED
    elseif tx_voltage <= 7.0 then
        tx_color = YELLOW
    end
    local help_on = status_help_enabled(widget)
    local link_color = help_on and status_color(link_level) or value_color
    local link_percent = link_level == "neutral" and "---"
        or string.format("%d%%", round_number(rqly_percent))
    local link_title = help_on and ("LINK " .. link_percent) or "RQly"
    local link_value = help_on and link_text or link_percent

    if wide then
        lcd.drawText(46, 8, "MODE", CENTER + SMLSIZE + square_color)
        lcd.drawText(46, 38, pose_mode, CENTER + VCENTER + BOLD + pose_color)

        lcd.drawText(112, 8, "BANK", CENTER + SMLSIZE + square_color)
        lcd.drawText(112, 38, tostring(bank_info.current), CENTER + VCENTER + BOLD + bank_color)

        lcd.drawText(238, 8, link_title, CENTER + SMLSIZE + square_color)
        if sensor_available(SENSOR.RQLY) then
            lcd.drawText(238, 35, link_value, CENTER + BOLD + link_color)
        else
            lcd.drawText(238, 35, help_on and link_text or "---", CENTER + BOLD + link_color)
        end
        draw_rqly_bars(284, 38, rqly_percent, WHITE, true)

        lcd.drawText(438, 24, fit_text(model_name, 185, BOLD), CENTER + VCENTER + BOLD + value_color)
        lcd.drawText(565, 22, "Tx", VCENTER + SMLSIZE + square_color)
        lcd.drawText(592, 22, string.format("%.1fV", tx_voltage), VCENTER + BOLD + tx_color)
        lcd.drawText(screen_width - 16, 22, time_str, RIGHT + VCENTER + BOLD + square_color)
    else
        -- 480x320 header: six measured groups with no shared text region.
        lcd.drawText(24, 5, "MODE", CENTER + SMLSIZE + square_color)
        lcd.drawText(24, 32, pose_mode, CENTER + VCENTER + BOLD + pose_color)

        lcd.drawText(70, 5, "BANK", CENTER + SMLSIZE + square_color)
        lcd.drawText(70, 32, tostring(bank_info.current), CENTER + VCENTER + BOLD + bank_color)

        lcd.drawText(119, 5, link_title, CENTER + SMLSIZE + square_color)
        lcd.drawText(119, 32, help_on and link_text or (sensor_available(SENSOR.RQLY) and link_value or "---"), CENTER + VCENTER + BOLD + link_color)
        draw_rqly_bars(148, 28, rqly_percent, WHITE, false)

        lcd.drawText(245, 25, fit_text(model_name, 118, SMLSIZE), CENTER + VCENTER + SMLSIZE + value_color)

        lcd.drawText(347, 5, "Tx", CENTER + SMLSIZE + square_color)
        lcd.drawText(347, 32, string.format("%.1fV", tx_voltage), CENTER + VCENTER + BOLD + tx_color)
        lcd.drawText(screen_width - 8, 31, time_str, RIGHT + VCENTER + BOLD + square_color)
    end
end

local function measured_text_height(text, font, fallback)
    if lcd.sizeText then
        local _, height = lcd.sizeText(text, font)
        if type(height) == "number" and height > 0 then
            return height
        end
    end
    return fallback
end

local function fit_cell_value(value, preferred_font, max_width)
    local text = tostring(value or "")
    local font = preferred_font or BOLD
    if max_width and lcd.sizeText and lcd.sizeText(text, font) > max_width then
        font = SMLSIZE
    end
    if max_width then text = fit_text(text, max_width, font) end
    return text, font
end

local function draw_stacked_cell(x, top, bottom, label, value, label_color, value_color, value_font, max_width)
    local label_font = SMLSIZE
    value_font = value_font or BOLD
    label = max_width and fit_text(label, max_width, label_font) or label
    value, value_font = fit_cell_value(value, value_font, max_width)
    local label_height = measured_text_height(label, label_font, 12)
    local value_height = measured_text_height(value, value_font, value_font == MIDSIZE and 32 or 20)
    local gap = 5
    local available = bottom - top
    local total = label_height + gap + value_height
    if total > available then
        gap = math.max(1, available - label_height - value_height)
        total = label_height + gap + value_height
    end
    local start_y = top + math.max(0, (available - total) / 2)
    local label_y = math.floor(start_y + label_height / 2 + 0.5)
    local value_y = math.floor(start_y + label_height + gap + value_height / 2 + 0.5)

    lcd.drawText(x, label_y, label, CENTER + VCENTER + label_font + label_color)
    lcd.drawText(x, value_y, value, CENTER + VCENTER + value_font + value_color)
end

local function draw_band_title(x, top, bottom, text, color)
    lcd.drawText(x, math.floor((top + bottom) / 2 + 0.5), text, CENTER + VCENTER + SMLSIZE + color)
end

local function draw_inline_cell(left, right, top, bottom, label, value, label_color, value_color)
    local center_y = math.floor((top + bottom) / 2 + 0.5)
    local label_text = tostring(label or "")
    local label_width = lcd.sizeText and lcd.sizeText(label_text, SMLSIZE) or (#label_text * 6)
    local value_width = math.max(18, right - left - 18 - label_width)
    local value_text, value_font = fit_cell_value(value, BOLD, value_width)
    lcd.drawText(left + 6, center_y, label_text, VCENTER + SMLSIZE + label_color)
    lcd.drawText(right - 6, center_y, value_text, RIGHT + VCENTER + value_font + value_color)
end

local function timer_font(value)
    local font = MIDSIZE
    if lcd.sizeText then
        local width = lcd.sizeText(value, MIDSIZE)
        if width > 190 then
            font = BOLD
        end
    end
    return font
end

local function draw_wide(square_color, value_color, readings)
    local battery_color = readings.status_help and status_color(readings.battery_level) or value_color
    local link_color = readings.status_help and status_color(readings.link_level) or value_color
    local telemetry_color = readings.status_help and status_color(readings.telemetry_level) or value_color
    local receiver_color = readings.status_help and status_color(readings.receiver_level) or value_color
    local match_color = readings.status_help and status_color(readings.match_level) or value_color
    local system_color = readings.status_help and status_color(readings.overall_level) or value_color
    local rss2_color = readings.rss2 == "---" and square_color or link_color
    local panel_top = readings.elrs_alert and 80 or 64
    local panel_header_bottom = panel_top + 38
    draw_rounded_rectangle(18, panel_top, 310, 412 - panel_top, 12, square_color)
    draw_rounded_rectangle(345, panel_top, 210, 412 - panel_top, 12, square_color)
    draw_rounded_rectangle(572, panel_top, 210, 412 - panel_top, 12, square_color)

    -- Three bounded panels. Labels use the small font and values are centered
    -- in fixed cells so no telemetry string can collide with its neighbor.
    draw_band_title(173, panel_top + 1, panel_header_bottom, "Goosky " .. readings.profile.name, square_color)
    lcd.drawFilledRectangle(28, panel_header_bottom, 290, 1, square_color)
    if readings.model_bitmap then
        lcd.drawBitmap(readings.model_bitmap, 33, panel_top + 43)
    end
    lcd.drawFilledRectangle(28, 294, 290, 1, square_color)
    lcd.drawFilledRectangle(173, 294, 1, 117, square_color)
    lcd.drawFilledRectangle(28, 353, 290, 1, square_color)
    if readings.status_help then
        draw_stacked_cell(100, 295, 353, "CONTROL LINK", readings.link_text, square_color, link_color, BOLD)
        draw_stacked_cell(246, 295, 353,
            readings.rpm and "ROTOR RPM" or "TELEMETRY",
            readings.rpm or readings.telemetry_text,
            square_color, readings.rpm and value_color or telemetry_color, BOLD)
        draw_stacked_cell(100, 354, 411, "RADIO POWER", readings.tpwr, square_color, value_color, BOLD)
        draw_stacked_cell(246, 354, 411, "SYSTEM", readings.system_text, square_color, system_color, BOLD)
    else
        draw_stacked_cell(100, 295, 353, "RX SNR", readings.rsnr, square_color, value_color, BOLD)
        draw_stacked_cell(246, 295, 353,
            readings.rpm and "ROTOR RPM" or "TX SNR",
            readings.rpm or readings.tsnr, square_color, value_color, BOLD)
        draw_stacked_cell(100, 354, 411, "TX POWER", readings.tpwr, square_color, value_color, BOLD)
        draw_stacked_cell(246, 354, 411, "RF MODE / ANT", readings.mode_antenna, square_color, value_color, BOLD)
    end

    draw_band_title(450, panel_top + 1, panel_header_bottom, "FLIGHT BATTERY", square_color)
    lcd.drawFilledRectangle(355, panel_header_bottom, 190, 1, square_color)
    draw_flight_battery_gauge(450, readings.elrs_alert and 176 or 160, 55, readings.capacity_value, readings.battery_percent_value, readings.battery_voltage, battery_color, readings.battery_available)
    lcd.drawFilledRectangle(355, 234, 190, 1, square_color)
    lcd.drawFilledRectangle(355, 323, 190, 1, square_color)
    draw_stacked_cell(450, 235, 323, "FLIGHT TIME", readings.flight_time, square_color, value_color, timer_font(readings.flight_time))
    draw_stacked_cell(450, 324, 411, "COUNTDOWN", readings.timer1, square_color, value_color, timer_font(readings.timer1))

    draw_band_title(677, panel_top + 1, panel_header_bottom, "ELRS LINK", square_color)
    lcd.drawFilledRectangle(582, panel_header_bottom, 190, 1, square_color)
    lcd.drawFilledRectangle(677, panel_header_bottom, 1, 411 - panel_header_bottom, square_color)
    lcd.drawFilledRectangle(582, 265, 190, 1, square_color)
    if readings.status_help then
        local status_label = readings.match_label == "MODEL MATCH" and "MATCH" or "STATUS"
        draw_stacked_cell(625, panel_header_bottom + 1, 265, "SIGNAL", readings.link_text, square_color, link_color, BOLD)
        draw_stacked_cell(730, panel_header_bottom + 1, 265, "QUALITY", readings.link_quality_text, square_color, link_color, BOLD)
        draw_stacked_cell(625, 266, 411, "TELEM", readings.telemetry_text, square_color, telemetry_color, BOLD)
        draw_stacked_cell(730, 266, 411, status_label, readings.match_text, square_color, match_color, BOLD)
    else
        draw_stacked_cell(625, panel_header_bottom + 1, 265, "1RSS", readings.rss1, square_color, link_color, BOLD)
        draw_stacked_cell(730, panel_header_bottom + 1, 265, "2RSS", readings.rss2, square_color, rss2_color, BOLD)
        draw_stacked_cell(625, 266, 411, "TRSS", readings.trss, square_color, link_color, BOLD)
        draw_stacked_cell(730, 266, 411, "TQly", readings.tqly, square_color, link_color, BOLD)
    end

    lcd.drawFilledRectangle(18, 428, 764, 1, square_color)
    lcd.drawFilledRectangle(200, 436, 1, 38, square_color)
    lcd.drawFilledRectangle(372, 436, 1, 38, square_color)
    lcd.drawFilledRectangle(580, 436, 1, 38, square_color)

    local throttle_text
    local throttle_color
    if not readings.hold_configured then
        throttle_text = "HOLD NOT SET"
        throttle_color = YELLOW
    elseif readings.hold_on then
        throttle_text = "HOLD ON"
        throttle_color = RED
    elseif readings.throttle_active then
        throttle_text = "THR ACTIVE"
        throttle_color = GREEN
    else
        throttle_text = "THR IDLE"
        throttle_color = YELLOW
    end
    draw_stacked_cell(109, 429, 479, "CURRENT", readings.current, square_color, value_color, BOLD)
    draw_stacked_cell(286, 429, 479, "POWER", readings.power, square_color, value_color, BOLD)
    draw_stacked_cell(476, 429, 479, "MAX POWER", readings.max_power, square_color, value_color, BOLD)
    draw_stacked_cell(681, 429, 479, "THROTTLE", throttle_text, square_color, throttle_color, BOLD)
end

local function draw_compact(square_color, value_color, readings)
    local battery_color = readings.status_help and status_color(readings.battery_level) or value_color
    local link_color = readings.status_help and status_color(readings.link_level) or value_color
    local telemetry_color = readings.status_help and status_color(readings.telemetry_level) or value_color
    local match_color = readings.status_help and status_color(readings.match_level) or value_color
    local system_color = readings.status_help and status_color(readings.overall_level) or value_color
    local rss2_color = readings.rss2 == "---" and square_color or link_color
    -- Dedicated 480x320 layout. It retains the same information hierarchy as
    -- the 800x480 dashboard instead of scaling the larger coordinates.
    local panel_top = readings.elrs_alert and 72 or 54
    local panel_header_bottom = panel_top + 23
    draw_rounded_rectangle(2, panel_top, 198, 274 - panel_top, 8, square_color)
    draw_rounded_rectangle(204, panel_top, 134, 274 - panel_top, 8, square_color)
    draw_rounded_rectangle(342, panel_top, 136, 274 - panel_top, 8, square_color)

    -- Aircraft and local RF telemetry.
    draw_band_title(101, panel_top + 1, panel_header_bottom, "Goosky " .. readings.profile.name, square_color)
    lcd.drawFilledRectangle(6, panel_header_bottom, 190, 1, square_color)
    if readings.model_bitmap then
        lcd.drawBitmap(readings.model_bitmap, 5, panel_top + 25)
    end
    lcd.drawFilledRectangle(6, 212, 190, 1, square_color)
    lcd.drawFilledRectangle(101, 213, 1, 60, square_color)
    lcd.drawFilledRectangle(6, 244, 190, 1, square_color)
    if readings.status_help then
        draw_inline_cell(6, 101, 213, 244, "LINK", readings.link_text, square_color, link_color)
        draw_inline_cell(102, 196, 213, 244,
            readings.rpm and "RPM" or "TEL",
            readings.rpm or readings.telemetry_text,
            square_color, readings.rpm and value_color or telemetry_color)
        draw_inline_cell(6, 101, 245, 273, "PWR", readings.tpwr, square_color, value_color)
        draw_inline_cell(102, 196, 245, 273, "SYS", readings.system_text, square_color, system_color)
    else
        draw_inline_cell(6, 101, 213, 244, "RX", readings.rsnr, square_color, value_color)
        draw_inline_cell(102, 196, 213, 244,
            readings.rpm and "RPM" or "TX",
            readings.rpm or readings.tsnr, square_color, value_color)
        draw_inline_cell(6, 101, 245, 273, "PWR", readings.tpwr, square_color, value_color)
        draw_inline_cell(102, 196, 245, 273, "RF", readings.mode_antenna, square_color, value_color)
    end

    -- Combined percentage, voltage, corrected consumption, and both timers.
    draw_band_title(271, panel_top + 1, panel_header_bottom, "FLIGHT BATTERY", square_color)
    lcd.drawFilledRectangle(208, panel_header_bottom, 126, 1, square_color)
    draw_flight_battery_gauge(271, panel_top + 73, 43, readings.capacity_value, readings.battery_percent_value, readings.battery_voltage, battery_color, readings.battery_available)
    lcd.drawFilledRectangle(208, 184, 126, 1, square_color)
    lcd.drawFilledRectangle(208, 229, 126, 1, square_color)
    draw_inline_cell(208, 334, 185, 229, "FLT", readings.flight_time, square_color, value_color)
    draw_inline_cell(208, 334, 230, 273, "T1", readings.timer1, square_color, value_color)

    -- Dedicated ELRS link grid.
    draw_band_title(410, panel_top + 1, panel_header_bottom, "ELRS LINK", square_color)
    lcd.drawFilledRectangle(346, panel_header_bottom, 128, 1, square_color)
    lcd.drawFilledRectangle(410, panel_header_bottom + 1, 1, 273 - panel_header_bottom, square_color)
    lcd.drawFilledRectangle(346, 184, 128, 1, square_color)
    if readings.status_help then
        draw_stacked_cell(378, panel_header_bottom + 1, 184, "SIGNAL", readings.link_text, square_color, link_color, BOLD, 56)
        draw_stacked_cell(442, panel_header_bottom + 1, 184, "QUALITY", readings.link_quality_text, square_color, link_color, BOLD, 56)
        draw_stacked_cell(378, 185, 273, "TELEM", readings.telemetry_text, square_color, telemetry_color, BOLD, 56)
        local compact_match_label = readings.match_label == "MODEL MATCH" and "MATCH" or "STATUS"
        draw_stacked_cell(442, 185, 273, compact_match_label, readings.match_text, square_color, match_color, BOLD, 56)
    else
        draw_stacked_cell(378, 96, 184, "1RSS", readings.rss1, square_color, link_color, BOLD, 56)
        draw_stacked_cell(442, 96, 184, "2RSS", readings.rss2, square_color, rss2_color, BOLD, 56)
        draw_stacked_cell(378, 185, 273, "TRSS", readings.trss, square_color, link_color, BOLD, 56)
        draw_stacked_cell(442, 185, 273, "TQly", readings.tqly, square_color, link_color, BOLD, 56)
    end

    -- Four equal footer columns.
    lcd.drawFilledRectangle(2, 279, 476, 1, square_color)
    lcd.drawFilledRectangle(120, 284, 1, 34, square_color)
    lcd.drawFilledRectangle(240, 284, 1, 34, square_color)
    lcd.drawFilledRectangle(360, 284, 1, 34, square_color)
    draw_stacked_cell(60, 280, 319, "CURRENT", readings.current, square_color, value_color, BOLD, 108)
    draw_stacked_cell(180, 280, 319, "POWER", readings.power, square_color, value_color, BOLD, 108)
    draw_stacked_cell(300, 280, 319, "MAX POWER", readings.max_power, square_color, value_color, BOLD, 108)

    local throttle_text
    local throttle_color
    if not readings.hold_configured then
        throttle_text = "HOLD NOT SET"
        throttle_color = YELLOW
    elseif readings.hold_on then
        throttle_text = "HOLD ON"
        throttle_color = RED
    elseif readings.throttle_active then
        throttle_text = "THR ACTIVE"
        throttle_color = GREEN
    else
        throttle_text = "THR IDLE"
        throttle_color = YELLOW
    end
    draw_stacked_cell(420, 280, 319, "THROTTLE", throttle_text, square_color, throttle_color, BOLD, 108)
end

local function draw_overall_alert(wide, screen_width, readings)
    if not readings.status_help or readings.overall_level == "ok"
        or readings.overall_level == "neutral" then return end

    local y = wide and 82 or 74
    local height = wide and 32 or 20
    local margin = wide and 20 or 4
    local fill = readings.overall_level == "critical" and lcd.RGB(150, 0, 0) or lcd.RGB(210, 145, 0)
    local text_color = readings.overall_level == "critical" and WHITE or BLACK
    local font = wide and BOLD or SMLSIZE
    local message = fit_text(readings.overall_message, screen_width - margin * 2 - 12, font)
    lcd.drawFilledRectangle(margin, y, screen_width - margin * 2, height, fill)
    lcd.drawRectangle(margin, y, screen_width - margin * 2, height, WHITE)
    lcd.drawText(screen_width / 2, y + height / 2, message, CENTER + VCENTER + font + text_color)
end

local function draw_simulation_marker(wide)
    if not simulation then return end
    local scenario = type(simulation.getScenarioName) == "function"
        and simulation.getScenarioName(getTime()) or "ACTIVE"
    local text_value = "SIM: " .. tostring(scenario)
    local width = wide and 190 or 132
    local height = wide and 18 or 14
    local y = wide and 462 or 306
    lcd.drawFilledRectangle(0, y, width, height, lcd.RGB(105, 0, 105))
    lcd.drawText(width / 2, y + height / 2, fit_text(text_value, width - 8, SMLSIZE), CENTER + VCENTER + SMLSIZE + WHITE)
end

local function get_widget_zone(widget)
    if type(widget) ~= "table" then return nil end
    local zone = rawget(widget, "zone")
    if type(zone) ~= "table" then return nil end
    return zone
end

local function draw_app_mode_required(widget)
    -- EdgeTX only gives a widget key/touch focus in Full Screen "App mode".
    -- There is no Lua API that can rewrite the model's Display layout or enter
    -- App mode on the user's behalf, so fail visibly instead of drawing the
    -- full-screen dashboard into a smaller widget zone.
    local zone = get_widget_zone(widget)
    local width = math.max(1, tonumber(zone and rawget(zone, "w")) or tonumber(LCD_W) or 480)
    local height = math.max(1, tonumber(zone and rawget(zone, "h")) or tonumber(LCD_H) or 320)
    local center_x = width / 2
    local title_y = math.max(12, math.floor(height * 0.28))
    local line_1_y = math.max(title_y + 24, math.floor(height * 0.52))
    local line_2_y = math.max(line_1_y + 18, math.floor(height * 0.70))

    lcd.drawFilledRectangle(0, 0, width, height, BLACK)
    lcd.drawRectangle(1, 1, math.max(1, width - 2), math.max(1, height - 2), YELLOW)
    lcd.drawText(center_x, title_y,
        fit_text("APP MODE REQUIRED", width - 12, BOLD),
        CENTER + VCENTER + BOLD + YELLOW)
    lcd.drawText(center_x, line_1_y,
        fit_text("Open the widget menu", width - 12, SMLSIZE),
        CENTER + VCENTER + SMLSIZE + WHITE)
    lcd.drawText(center_x, line_2_y,
        fit_text("Select App mode", width - 12, SMLSIZE),
        CENTER + VCENTER + SMLSIZE + GREEN)
end

local function has_app_mode_surface(widget, event)
    -- A numeric event is the normal EdgeTX indication that the widget owns
    -- App/Full Screen input. Some TX15 builds, however, pass nil while the
    -- full-screen widget is idle. EdgeTX still expands the widget zone when
    -- entering App Mode, so accept a full or near-full LCD-sized surface too.
    if event ~= nil then return true end

    local zone = get_widget_zone(widget)
    local zone_width = tonumber(zone and rawget(zone, "w")) or 0
    local zone_height = tonumber(zone and rawget(zone, "h")) or 0
    local lcd_width = tonumber(LCD_W) or zone_width
    local lcd_height = tonumber(LCD_H) or zone_height
    if lcd_width <= 0 or lcd_height <= 0 then return false end

    -- Allow for EdgeTX decorations that can reserve a narrow strip while
    -- rejecting ordinary half-screen and grid dashboard zones.
    return zone_width >= lcd_width * 0.90
        and zone_height >= lcd_height * 0.80
end

local telemetry_switch_id = nil
local function native_telemetry_active()
    if telemetry_switch_id == nil then
        telemetry_switch_id = 0
        if type(getSwitchIndex) == "function" then
            for _, name in ipairs({ "TELE", "Telemetry", "TELEM" }) do
                local id = getSwitchIndex(name)
                if id and id ~= 0 then
                    telemetry_switch_id = id
                    break
                end
            end
        end
    end
    if telemetry_switch_id ~= 0 and type(getSwitchValue) == "function" then
        local ok, active = pcall(getSwitchValue, telemetry_switch_id)
        if ok then return active and active ~= 0 and active ~= false end
    end
    -- Compatibility fallback for radios that do not expose the named TELE
    -- condition to Lua. Native TELE remains authoritative when available.
    return sensor_available(SENSOR.RQLY) and read_sensor(SENSOR.RQLY) > 0
end

local function draw_brand_splash(wide, screen_width, screen_height)
    local splash = wide and assets.wide.splash or assets.compact.splash
    if splash then
        lcd.drawBitmap(splash, 0, 0)
        return
    end
    lcd.drawFilledRectangle(0, 0, screen_width, screen_height, BLACK)
    lcd.drawText(screen_width / 2, screen_height * 0.40,
        "NERC Goosky FlightDeck", CENTER + MIDSIZE + WHITE)
    lcd.drawText(screen_width / 2, screen_height * 0.56,
        "Telemetry & Flight Status", CENTER + BOLD + WHITE)
end

local function refresh(widget, event, touch_state)
    if not has_app_mode_surface(widget, event) then
        draw_app_mode_required(widget)
        return
    end

    if widget.splash_pending then
        widget.splash_pending = false
        widget.splash_until = getTime() + 300
    end

    local screen_width = LCD_W or widget.zone.w
    local screen_height = LCD_H or widget.zone.h
    local wide = screen_width >= 700 and screen_height >= 400

    if getTime() - last_sensor_scan >= 500 then
        scan_telemetry_fields()
    end

    -- The 800x480 dashboard is designed around a fixed black background. This
    -- also keeps the native EdgeTX widget settings within its ten-option limit.
    lcd.setColor(CUSTOM_COLOR, widget.options.BackgroundColor or BLACK)
    local bg_color = lcd.getColor(CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR, widget.options.SquareColor)
    local square_color = lcd.getColor(CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR, widget.options.ValueColor)
    local value_color = lcd.getColor(CUSTOM_COLOR)

    lcd.drawFilledRectangle(0, 0, screen_width, screen_height, bg_color)

    local model_info = model.getInfo()
    local model_name = (model_info and model_info.name) or "MODEL"
    local adc_filter_ok = enforce_adc_filter_off(widget, model_info)
    load_auto_switches(widget, model_info)
    save_model_setup_options(widget, model_info)
    local profile = resolve_profile(widget, model_name)
    local motor_running, hold_on, throttle_active = get_motor_state(widget)
    local telemetry_active = native_telemetry_active()
    local hold_configured = effective_switch_setting(widget, "HoldSwitch") ~= 0
    local throttle_at_minimum, throttle_output = get_throttle_at_safe_minimum()
    -- ELRS configuration reads are a bounded, receiver-off preflight action.
    -- Require every gate independently: a configured HOLD switch in its active
    -- position, CH3 truly at -100%, no native TELE, no link/signal indication,
    -- and no receiver link previously established in this model session.
    local receiver_off_preflight = not telemetry_active
        and not elrs_link_connected() and widget.receiver_ever_seen ~= true
    local safe_elrs_preflight = hold_configured and hold_on
        and throttle_at_minimum
        and (simulation ~= nil or receiver_off_preflight)

    -- Never fail silently before discovery. Report the exact safety gate that
    -- is stopping CRSF traffic while the receiver has not been seen. This is
    -- especially important because missing switch configuration used to be
    -- rendered as HOLD ON even though the scanner correctly rejected it.
    elrs_state.gate_error = nil
    if simulation == nil and receiver_off_preflight
        and not elrs_state.device_found and not elrs_state.scan_complete then
        if not hold_configured then
            elrs_state.gate_error = "HOLD NOT CONFIGURED"
        elseif not hold_on then
            elrs_state.gate_error = "THROTTLE HOLD OFF"
        elseif not throttle_at_minimum then
            if type(throttle_output) == "number" then
                local scaled = throttle_output * 100 / 1024
                local percent = scaled >= 0 and math.floor(scaled + 0.5)
                    or math.ceil(scaled - 0.5)
                elrs_state.gate_error = "CH3 OUTPUT " .. tostring(percent)
                    .. "% - NEEDS -100%"
            else
                elrs_state.gate_error = "CH3 OUTPUT UNAVAILABLE"
            end
        end
    end

    -- The initial scan is deliberately one-shot. If the pilot leaves the
    -- dashboard for the ELRS tool and returns, background() requests exactly
    -- one fresh bounded scan so externally changed settings are not hidden by
    -- the old scan_complete cache. Never re-arm after a receiver was online.
    if widget.elrs_recheck_requested then
        if safe_elrs_preflight and elrs_state.fix.stage == "idle"
            and not widget.elrs_dialog then
            reset_elrs_state()
            widget.elrs_prompt_dismissed = nil
            widget.elrs_dialog_message = ""
        end
        widget.elrs_recheck_requested = false
    end
    poll_elrs_settings(safe_elrs_preflight)
    process_elrs_fix(safe_elrs_preflight)
    local pose_mode, pose_color = get_goosky_pose_mode()
    update_elrs_warning_dialog(widget, hold_on, throttle_active)
    handle_input(widget, event, touch_state, wide, hold_on)
    local reset_active, reset_pressed = update_timer_reset(widget)
    if reset_active then power_max = 0 end
    local rqly_percent = read_sensor(SENSOR.RQLY)
    local tx_voltage = getValue("tx-voltage") or 0
    if type(tx_voltage) ~= "number" then
        tx_voltage = 0
    end

    local battery_voltage = read_sensor(SENSOR.RXBT)
    local battery_available = sensor_available(SENSOR.RXBT) and battery_voltage > 0
    local battery_chemistry = get_battery_chemistry(widget, battery_voltage, profile)
    local capacity_available = sensor_available(SENSOR.CAPA)
    local capacity_value = get_corrected_consumption(widget, read_sensor(SENSOR.CAPA))
    local pack_capacity = get_pack_capacity(widget, profile)
    local battery_percent_value = get_battery_percent(
        widget, battery_voltage, profile, battery_chemistry,
        capacity_value, capacity_available, pack_capacity
    )
    local current_value = read_sensor(SENSOR.CURR)
    local power_value = battery_voltage * current_value
    power_max = math.max(power_max, math.min(math.floor(power_value), 99999))

    local power_string = power_value >= 1000 and string.format("%.1fkW", power_value / 1000) or string.format("%.0fW", power_value)
    local max_power_string = power_max >= 1000 and string.format("%.1fkW", power_max / 1000) or string.format("%dW", power_max)

    local timer1 = get_model_timer(0)
    local timer2 = get_model_timer(1)
    local timer1_value = timer1 and timer1.value or nil
    local timer2_value = timer2 and timer2.value or nil
    local readings = {
        profile = profile,
        model_name = model_name,
        model_bitmap = get_model_bitmap(model_name, model_info and model_info.bitmap, wide),
        motor_running = motor_running,
        hold_on = hold_on,
        hold_configured = hold_configured,
        throttle_active = throttle_active,
        telemetry_active = telemetry_active,
        battery_voltage = battery_voltage,
        battery_available = battery_available,
        battery_chemistry = battery_chemistry,
        battery_max_voltage = get_battery_max_voltage(profile, battery_chemistry),
        battery_percent_value = battery_percent_value,
        capacity_value = capacity_value,
        pack_capacity = pack_capacity,
        current = sensor_decimal_text(SENSOR.CURR, 1, "A"),
        power = power_string,
        max_power = max_power_string,
        flight_time = format_timer(timer2_value),
        timer1 = format_timer(timer1_value),
        timer1_value = timer1_value,
        timer1_countdown = timer1 and type(timer1.start) == "number" and timer1.start > 0,
        rsnr = sensor_integer_text(SENSOR.RSNR, "dB"),
        tsnr = sensor_integer_text(SENSOR.TSNR, "dB"),
        tpwr = sensor_integer_text(SENSOR.TPWR, "mW"),
        rss1 = optional_rssi_text(SENSOR.RSS1),
        rss2 = optional_rssi_text(SENSOR.RSS2),
        trss = sensor_integer_text(SENSOR.TRSS, "dB"),
        tqly = sensor_integer_text(SENSOR.TQLY, "%"),
        rpm = rotor_rpm_text(profile),
        mode_antenna = sensor_integer_text(SENSOR.RFMD, "") .. " / " .. sensor_integer_text(SENSOR.ANT, ""),
        status_help = status_help_enabled(widget),
        adc_filter_ok = adc_filter_ok
    }

    local receiver_online = telemetry_active
    if widget.receiver_session_model ~= model_name then
        widget.receiver_session_model = model_name
        widget.receiver_ever_seen = false
        widget.battery_ever_seen = false
    end
    if reset_pressed and hold_on and not receiver_online then
        acknowledge_completed_flight(widget)
    end
    if receiver_online then widget.receiver_ever_seen = true end
    if battery_available then widget.battery_ever_seen = true end
    readings.receiver_ever_seen = widget.receiver_ever_seen == true
    readings.battery_ever_seen = widget.battery_ever_seen == true
    readings.telemetry_sensors_ready = sensor_available(SENSOR.RQLY)
        and sensor_available(SENSOR.RXBT)
    readings.link_level, readings.link_text = classify_link(
        rqly_percent, sensor_available(SENSOR.RQLY), telemetry_active, motor_running,
        readings.receiver_ever_seen
    )
    local tqly_percent = read_sensor(SENSOR.TQLY)
    readings.telemetry_level, readings.telemetry_text = classify_telemetry_return(
        tqly_percent, sensor_available(SENSOR.TQLY), receiver_online,
        readings.receiver_ever_seen
    )
    readings.link_quality_text = receiver_online
        and string.format("%d%%", round_number(rqly_percent)) or "---"
    readings.receiver_text = receiver_online and "ONLINE"
        or (readings.receiver_ever_seen and "OFFLINE" or "---")
    readings.receiver_level = receiver_online and "ok"
        or (readings.receiver_ever_seen and "warning" or "neutral")
    readings.battery_level, readings.battery_text = classify_battery(
        battery_voltage, battery_percent_value, battery_available, motor_running,
        readings.battery_ever_seen
    )
    if not readings.receiver_ever_seen and not battery_available then
        readings.battery_level, readings.battery_text = "neutral", "---"
    end
    local raw_level, raw_message = overall_dashboard_status(readings)
    readings.overall_level, readings.overall_message = stabilize_dashboard_status(
        widget, raw_level, raw_message
    )
    readings.system_text = readings.overall_level == "critical" and "DANGER"
        or (readings.overall_level == "warning" and "CHECK"
        or (readings.overall_level == "neutral"
            and (readings.telemetry_active and not readings.telemetry_sensors_ready and "DISCOVER" or "---")
            or "READY"))
    if model_match_is_enabled() then
        readings.match_label = "MODEL MATCH"
        if elrs_state.model_mismatch then
            readings.match_text = "MISMATCH"
            readings.match_level = "critical"
        elseif receiver_online then
            readings.match_text = "OK"
            readings.match_level = "ok"
        elseif not readings.receiver_ever_seen then
            readings.match_text = "---"
            readings.match_level = "neutral"
        else
            readings.match_text = "CHECK"
            readings.match_level = "warning"
        end
    else
        readings.match_label = "ELRS SETUP"
        if not elrs_state.device_found or not target_settings_complete() then
            readings.match_text = "---"
            readings.match_level = "neutral"
        elseif elrs_fix_required() then
            readings.match_text = "FIX"
            readings.match_level = "warning"
        else
            readings.match_text = "READY"
            readings.match_level = "ok"
        end
    end

    local elrs_hud = make_elrs_hud()
    -- The ELRS bar is exception-only. Correct settings, Model Match Off, link
    -- waiting, and scan progress are already represented elsewhere and do not
    -- justify a permanent status row.
    readings.elrs_alert = elrs_hud.level == "error"

    -- Branding is presentation only. All telemetry, ELRS preflight, alarms,
    -- LEDs, haptics and input handling above continue to run while it is
    -- visible. Any receiver link, warning, or ELRS dialog cancels it at once.
    local splash_active = widget.splash_until and getTime() < widget.splash_until
        and not telemetry_active and not widget.elrs_dialog
        and not readings.elrs_alert
        and (readings.overall_level == "neutral" or readings.overall_level == "ok")
    if splash_active then
        update_splash_leds()
    else
        update_status_leds(widget, readings.overall_level,
            battery_available, battery_percent_value)
    end
    update_status_haptic(widget, readings.overall_level)

    if splash_active then
        draw_brand_splash(wide, screen_width, screen_height)
        return
    end
    widget.splash_until = 0

    draw_header(
        widget, wide, screen_width, square_color, value_color, tx_voltage,
        rqly_percent, model_name, pose_mode, pose_color,
        readings.link_text, readings.link_level
    )
    if readings.elrs_alert then
        draw_elrs_hud(wide, screen_width, elrs_hud)
    end

    if wide then
        draw_wide(square_color, value_color, readings)
    else
        draw_compact(square_color, value_color, readings)
    end
    draw_overall_alert(wide, screen_width, readings)
    draw_simulation_marker(wide)

    if widget.elrs_dialog then
        draw_elrs_warning_dialog(widget, wide, screen_width, screen_height, square_color)
    end
end

return {
    name = NAME,
    options = options,
    create = create,
    update = update,
    refresh = refresh,
    background = background
}

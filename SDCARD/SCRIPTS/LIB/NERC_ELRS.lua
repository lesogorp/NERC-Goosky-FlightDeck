-- NERC shared ExpressLRS settings engine
-- EdgeTX 2.12 / ExpressLRS 3.x transport and verified parameter repair.
-- UI-agnostic: used by the Goosky FlightDeck widget and native model wizard.

local M = {}

local CRSF_BROADCAST = 0x00
local CRSF_RADIO = 0xEA
local CRSF_ELRS_LUA = 0xEF
local CRSF_ELRS_TX = 0xEE
local DISCOVERY_WINDOW = 1200
local DISCOVERY_INTERVAL = 100

local PARAMETER_NAMES = {
    "Packet Rate", "Telem Ratio", "Switch Mode", "Model Match",
    "Max Power", "Dynamic", "Dynamic Power", "Antenna Mode"
}

local RECOMMENDED = {
    rate = "333Hz Full",
    channels = "8ch",
    telemetry = "1:32",
    modelMatch = "On",
    power = "100mW",
    dynamic = "Off",
    antenna = "Switch"
}

local function clean(value)
    value = value or "?"
    value = string.match(value, "^%s*(.-)%s*$") or value
    local before = string.match(value, "^(.-)%s+%(%-")
    return before or value
end

local function rate_ok(value)
    local lower = string.lower(clean(value))
    return string.find(lower, "333", 1, true) ~= nil
        and string.find(lower, "full", 1, true) ~= nil
end

local function switch_ok(value)
    local lower = string.lower(clean(value))
    return lower == "8ch" or string.match(lower, "^8ch[%s%-]") ~= nil
end

local function telem_ok(value) return clean(value) == "1:32" end
local function model_match_ok(value) return string.lower(clean(value)) == "on" end
local function dynamic_ok(value) return string.lower(clean(value)) == "off" end
local function antenna_ok(value) return string.lower(clean(value)) == "switch" end
local function power_ok(value)
    return tonumber(string.match(clean(value), "%d+")) == 100
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

function M.new(options)
    options = options or {}
    local self = {}
    local simulation = options.simulation
    local now_fn = options.getTime or getTime

    local function crsf_push(command, data)
        if simulation and type(simulation.push) == "function" then
            return simulation.push(command, data, now_fn())
        end
        if type(crossfireTelemetryPush) == "function" then
            return crossfireTelemetryPush(command, data)
        end
        return false
    end

    local function crsf_submit(command, data)
        if simulation and type(simulation.push) == "function" then
            simulation.push(command, data, now_fn())
            return true
        end
        if type(crossfireTelemetryPush) ~= "function" then return false end
        return pcall(crossfireTelemetryPush, command, data)
    end

    local function crsf_pop()
        if simulation and type(simulation.pop) == "function" then
            return simulation.pop(now_fn())
        end
        if type(crossfireTelemetryPop) == "function" then
            return crossfireTelemetryPop()
        end
        return nil
    end

    local state = {}

    local function reset()
        state.device_id = CRSF_ELRS_TX
        state.handset_id = CRSF_RADIO
        state.device_found = false
        state.device_name = ""
        state.fields_count = 0
        state.queue = {}
        state.queue_pos = 1
        state.current = nil
        state.initial_scan = false
        state.settings = {}
        state.field_ids = {}
        state.next_ping = 0
        state.discovery_deadline = 0
        state.next_status = 0
        state.next_refresh = 0
        state.ping_attempts = 0
        state.status_requested = false
        state.status_deadline = 0
        state.refresh_attempts = 0
        state.scan_complete = false
        state.status_seen = false
        state.connected = false
        state.armed = false
        state.model_mismatch = false
        state.transport_error = nil
        state.gate_error = nil
        state.supported = simulation ~= nil
            or (type(crossfireTelemetryPush) == "function"
                and type(crossfireTelemetryPop) == "function")
        state.fix = { stage = "idle", deadline = 0, message = "" }
    end

    local function queue_fields(ids, initial_scan)
        state.queue = ids
        state.queue_pos = 1
        state.current = nil
        state.initial_scan = initial_scan or false
    end

    local function dynamic_setting()
        if state.settings["Dynamic"] then return "Dynamic", state.settings["Dynamic"] end
        if state.settings["Dynamic Power"] then return "Dynamic Power", state.settings["Dynamic Power"] end
        return nil, nil
    end

    local function target_complete()
        for _, name in ipairs({"Packet Rate","Telem Ratio","Switch Mode","Model Match","Max Power"}) do
            if not state.settings[name] then return false end
        end
        return state.settings["Dynamic"] ~= nil or state.settings["Dynamic Power"] ~= nil
    end

    local function missing_text()
        local missing = {}
        for _, name in ipairs({"Packet Rate","Telem Ratio","Switch Mode","Model Match","Max Power"}) do
            if not state.settings[name] then missing[#missing + 1] = name end
        end
        if not state.settings["Dynamic"] and not state.settings["Dynamic Power"] then
            missing[#missing + 1] = "Dynamic"
        end
        return table.concat(missing, ",")
    end

    local function parse_device(data)
        if data[2] ~= state.device_id then return end
        local device_name, offset = read_cstring(data, 3)
        local field_count = data[offset + 12] or 0
        state.device_found = true
        state.device_name = device_name or "ELRS TX"
        state.handset_id = CRSF_ELRS_LUA
        state.transport_error = nil
        if field_count <= 0 or field_count == state.fields_count then return end
        state.fields_count = field_count
        local ids = {}
        for id = 1, field_count do ids[#ids + 1] = id end
        queue_fields(ids, true)
    end

    local function parse_parameter_payload(field_id_value, payload)
        if #payload < 4 then return end
        local offset = 2
        local field_type = bit32.band(payload[offset] or 0, 0x7F)
        offset = offset + 1
        local name
        name, offset = read_cstring(payload, offset)
        if field_type ~= 9 then return end
        local raw_options
        raw_options, offset = read_cstring(payload, offset)
        local values = split_options(raw_options)
        local selected_index = payload[offset] or 0
        local unit = read_cstring(payload, offset + 4)
        for _, target_name in ipairs(PARAMETER_NAMES) do
            if name == target_name then
                state.settings[name] = {
                    value = values[selected_index + 1] or "?",
                    unit = unit or "",
                    index = selected_index,
                    values = values
                }
                state.field_ids[name] = field_id_value
                break
            end
        end
    end

    local function finish_parameter()
        local current = state.current
        if current then parse_parameter_payload(current.id, current.payload) end
        state.current = nil
    end

    local function parse_parameter_frame(data)
        local current = state.current
        if not current or data[2] ~= state.device_id or data[3] ~= current.id then return end
        for i = 5, #data do current.payload[#current.payload + 1] = data[i] end
        local chunks_remaining = data[4] or 0
        current.attempts = 0
        if chunks_remaining > 0 then
            current.chunk = current.chunk + 1
            current.deadline = 0
        else
            finish_parameter()
        end
    end

    local function parse_status(data)
        if data[2] ~= state.device_id then return end
        local flags = data[6] or 0
        state.status_seen = true
        state.connected = bit32.btest(flags, 0x01)
        state.armed = bit32.btest(flags, 0x02)
        state.model_mismatch = bit32.btest(flags, 0x04)
    end

    local function start_next(now)
        if state.current or state.queue_pos > #state.queue then return end
        local id = state.queue[state.queue_pos]
        state.queue_pos = state.queue_pos + 1
        state.current = {id=id, chunk=0, payload={}, deadline=now, attempts=0}
    end

    local function refresh_targets(now)
        local ids = {}
        for _, name in ipairs(PARAMETER_NAMES) do
            if state.field_ids[name] then ids[#ids + 1] = state.field_ids[name] end
        end
        if #ids > 0 then
            queue_fields(ids, false)
        elseif state.fields_count > 0 then
            for id = 1, state.fields_count do ids[#ids + 1] = id end
            queue_fields(ids, true)
        end
        state.next_refresh = now + 500
    end

    local function reads_idle()
        return not state.current and state.queue_pos > #state.queue
    end

    local function poll(safe_preflight)
        if not state.supported or not safe_preflight then return end
        local fix_active = state.fix.stage ~= "idle"
            and state.fix.stage ~= "complete" and state.fix.stage ~= "error"
        if state.scan_complete and not fix_active then return end

        local command, data
        repeat
            command, data = crsf_pop()
            if command == 0x29 and data then parse_device(data)
            elseif command == 0x2B and data then parse_parameter_frame(data)
            elseif command == 0x2E and data then parse_status(data) end
        until command == nil

        local now = now_fn()
        if state.discovery_deadline == 0 then state.discovery_deadline = now + DISCOVERY_WINDOW end
        local sent = false
        if not state.device_found and now >= state.discovery_deadline then
            state.scan_complete = true
            state.transport_error = "NO ELRS TX MODULE RESPONSE"
        elseif not state.device_found and now >= state.next_ping then
            crsf_submit(0x28, {CRSF_BROADCAST, CRSF_RADIO})
            state.ping_attempts = state.ping_attempts + 1
            state.next_ping = now + DISCOVERY_INTERVAL
            sent = true
        end

        if state.device_found and not fix_active and not state.status_requested
            and now >= state.next_status then
            local submitted = crsf_submit(0x2D, {
                state.device_id, state.handset_id, 0x00, 0x00
            })
            if submitted then
                state.status_requested = true
                state.status_deadline = now + 100
            end
            state.next_status = now + 100
            sent = submitted
        end

        if state.device_found and not state.current and state.queue_pos > #state.queue then
            if state.initial_scan then
                state.initial_scan = false
                if target_complete() and (state.status_seen or now >= state.status_deadline) then
                    state.scan_complete = true
                else
                    state.next_refresh = now + 50
                end
            elseif target_complete() and (state.status_seen or now >= state.status_deadline) then
                state.scan_complete = true
            elseif state.refresh_attempts < 1 and now >= state.next_refresh then
                state.refresh_attempts = state.refresh_attempts + 1
                refresh_targets(now)
            elseif state.refresh_attempts >= 1 and now >= state.next_refresh then
                state.scan_complete = true
                if not target_complete() then
                    state.transport_error = "ELRS READ INCOMPLETE: " .. missing_text()
                end
            end
        end

        start_next(now)
        if not sent and state.current and now >= state.current.deadline then
            if (state.current.attempts or 0) >= 3 then
                state.current = nil
                return
            end
            crsf_submit(0x2C, {
                state.device_id, state.handset_id,
                state.current.id, state.current.chunk
            })
            state.current.attempts = (state.current.attempts or 0) + 1
            state.current.deadline = now + 50
        end
    end

    local function find_target(name, matcher)
        local setting = state.settings[name]
        if not setting or not setting.values then return nil end
        for index, value in ipairs(setting.values) do
            if matcher(value) then return index - 1 end
        end
        return nil
    end

    local function queue_readback(names)
        local ids = {}
        for _, name in ipairs(names) do
            local id = state.field_ids[name]
            if id then ids[#ids + 1] = id end
        end
        if #ids == 0 then return false end
        queue_fields(ids, false)
        return true
    end

    local function write_choice(name, value)
        local field = state.field_ids[name]
        if not field or value == nil then return false end
        return crsf_push(0x2D, {state.device_id, state.handset_id, field, value})
    end

    local function set_fix(stage, message)
        state.fix.stage = stage
        state.fix.message = message
    end

    local function display_values()
        local _, dyn = dynamic_setting()
        local p = state.settings["Max Power"]
        local power = p and clean(p.value) or "?"
        if p and p.unit ~= "" and not string.find(string.lower(power), "mw", 1, true) then
            power = power .. p.unit
        end
        return {
            rate = state.settings["Packet Rate"] and clean(state.settings["Packet Rate"].value) or "?",
            channels = state.settings["Switch Mode"] and clean(state.settings["Switch Mode"].value) or "?",
            telemetry = state.settings["Telem Ratio"] and clean(state.settings["Telem Ratio"].value) or "?",
            modelMatch = state.settings["Model Match"] and clean(state.settings["Model Match"].value) or "?",
            power = power,
            dynamic = dyn and clean(dyn.value) or "?",
            antenna = state.settings["Antenna Mode"] and clean(state.settings["Antenna Mode"].value) or nil
        }
    end

    local function mismatch_list()
        local current = display_values()
        local list = {}
        if current.rate ~= "?" and not rate_ok(current.rate) then list[#list+1] = "Packet Rate" end
        if current.channels ~= "?" and not switch_ok(current.channels) then list[#list+1] = "Switch Mode" end
        if current.telemetry ~= "?" and not telem_ok(current.telemetry) then list[#list+1] = "Telem Ratio" end
        if current.modelMatch ~= "?" and not model_match_ok(current.modelMatch) then list[#list+1] = "Model Match" end
        if current.power ~= "?" and not power_ok(current.power) then list[#list+1] = "Max Power" end
        if current.dynamic ~= "?" and not dynamic_ok(current.dynamic) then list[#list+1] = "Dynamic Power" end
        if current.antenna and not antenna_ok(current.antenna) then list[#list+1] = "Antenna Mode" end
        return list
    end

    local function begin_fix(gates)
        gates = gates or {}
        if not gates.holdOn then return false, "ENABLE THROTTLE HOLD FIRST" end
        if state.connected or (type(gates.linkConnected) == "function" and gates.linkConnected()) then
            return false, "POWER OFF HELICOPTER FIRST"
        end
        if state.status_seen and state.armed then return false, "SET CH5 TO 3D (-100) FIRST" end
        local now = now_fn()
        state.fix = {
            stage="set_rate", deadline=now+4500, next_action=now,
            write_retries=0, message="APPLYING SETTINGS",
            original=display_values()
        }
        state.next_refresh = state.fix.deadline + 100
        return true
    end

    local function retry(fix, now, msg)
        fix.write_retries = (fix.write_retries or 0) + 1
        fix.next_action = now + 10
        fix.message = msg .. " - CRSF BUSY, RETRYING"
    end

    local function accepted(fix) fix.write_retries = 0 end

    local function process_fix(safe_preflight)
        local fix = state.fix
        if fix.stage == "idle" or fix.stage == "complete" or fix.stage == "error" then return end
        if not safe_preflight then set_fix("error","PRECHECK CHANGED - CHANGE CANCELLED"); return end
        local now = now_fn()
        if now > fix.deadline then set_fix("error","CHANGE NOT VERIFIED - USE ELRS LUA"); return end
        if state.connected then set_fix("error","RECEIVER CONNECTED - CHANGE CANCELLED"); return end

        local queues = {
            queue_rate={names={"Packet Rate","Switch Mode"}, wait="wait_rate", err="ELRS PARAMETER IDS NOT AVAILABLE"},
            queue_switch={names={"Switch Mode"}, wait="wait_switch", err="SWITCH MODE ID NOT AVAILABLE"},
            queue_telem={names={"Telem Ratio"}, wait="wait_telem", err="TELEMETRY RATIO ID NOT AVAILABLE"},
            queue_match={names={"Model Match"}, wait="wait_match", err="MODEL MATCH ID NOT AVAILABLE"},
            queue_power={names={"Max Power"}, wait="wait_power", err="MAX POWER ID NOT AVAILABLE"},
            queue_antenna={names={"Antenna Mode"}, wait="wait_antenna", err="ANTENNA MODE ID NOT AVAILABLE"}
        }
        if fix.stage == "queue_dynamic" then
            if now < fix.next_action or not reads_idle() then return end
            local name = dynamic_setting(); name = name or fix.dynamic_name
            if not name or not queue_readback({name}) then set_fix("error","DYNAMIC POWER ID NOT AVAILABLE")
            else fix.stage="wait_dynamic" end
            return
        end
        local q = queues[fix.stage]
        if q then
            if now < fix.next_action or not reads_idle() then return end
            if not queue_readback(q.names) then set_fix("error",q.err) else fix.stage=q.wait end
            return
        end
        if not reads_idle() or (fix.next_action and now < fix.next_action) then return end

        local function set_choice(stage_name, setting_name, matcher, next_stage, queue_stage, unavailable, message, clear_extra)
            if fix.stage ~= stage_name then return false end
            local setting = state.settings[setting_name]
            if setting and matcher(setting.value) then fix.stage = next_stage; return true end
            local target = find_target(setting_name, matcher)
            if target == nil then set_fix("error", unavailable)
            elseif not write_choice(setting_name, target) then retry(fix, now, message)
            else
                accepted(fix)
                state.settings[setting_name] = nil
                if clear_extra then state.settings[clear_extra] = nil end
                fix.stage = queue_stage
                fix.next_action = now + 100
                fix.message = message
            end
            return true
        end

        if set_choice("set_rate","Packet Rate",rate_ok,"set_switch","queue_rate","333HZ FULL IS NOT AVAILABLE","SETTING 333HZ FULL","Switch Mode") then return end
        if set_choice("set_switch","Switch Mode",switch_ok,"set_telem","queue_switch","8CH IS NOT AVAILABLE","SETTING 8CH FULL RES") then return end
        if set_choice("set_telem","Telem Ratio",telem_ok,"set_match","queue_telem","TELEMETRY 1:32 IS NOT AVAILABLE","SETTING TELEMETRY 1:32") then return end
        if set_choice("set_match","Model Match",model_match_ok,"set_power","queue_match","MODEL MATCH ON IS NOT AVAILABLE","ENABLING MODEL MATCH") then return end
        if set_choice("set_power","Max Power",power_ok,"set_dynamic","queue_power","100mW IS NOT AVAILABLE","SETTING MAX POWER 100mW") then return end

        local waits = {
            wait_rate={name="Packet Rate",match=rate_ok,next="set_switch",err="333HZ FULL CHANGE REJECTED",msg="SETTING 8CH FULL RES"},
            wait_switch={name="Switch Mode",match=switch_ok,next="set_telem",err="8CH CHANGE REJECTED",msg="SETTING TELEMETRY 1:32"},
            wait_telem={name="Telem Ratio",match=telem_ok,next="set_match",err="TELEMETRY 1:32 CHANGE REJECTED",msg="ENABLING MODEL MATCH"},
            wait_match={name="Model Match",match=model_match_ok,next="set_power",err="MODEL MATCH CHANGE REJECTED",msg="SETTING FIXED 100mW"},
            wait_power={name="Max Power",match=power_ok,next="set_dynamic",err="100mW CHANGE REJECTED",msg="DISABLING DYNAMIC POWER"}
        }
        local w = waits[fix.stage]
        if w then
            local setting = state.settings[w.name]
            if not setting then return end
            if w.match(setting.value) then fix.stage=w.next; fix.message=w.msg else set_fix("error",w.err) end
            return
        end

        if fix.stage == "set_dynamic" then
            local name, setting = dynamic_setting()
            if setting and dynamic_ok(setting.value) then
                if state.settings["Antenna Mode"] then fix.stage="set_antenna"; fix.message="SETTING ANTENNA SWITCH"
                else set_fix("complete","ALL SETTINGS VERIFIED") end
                return
            end
            if not name then set_fix("error","DYNAMIC POWER SETTING NOT FOUND"); return end
            local target = find_target(name, dynamic_ok)
            if target == nil then set_fix("error","DYNAMIC POWER OFF IS NOT AVAILABLE")
            elseif not write_choice(name,target) then retry(fix,now,"DISABLING DYNAMIC POWER")
            else
                accepted(fix); fix.dynamic_name=name; state.settings[name]=nil
                fix.stage="queue_dynamic"; fix.next_action=now+100; fix.message="DISABLING DYNAMIC POWER"
            end
            return
        elseif fix.stage == "wait_dynamic" then
            local _, setting = dynamic_setting()
            if not setting then return end
            if dynamic_ok(setting.value) then
                if state.settings["Antenna Mode"] then fix.stage="set_antenna"; fix.message="SETTING ANTENNA SWITCH"
                else set_fix("complete","ALL SETTINGS VERIFIED") end
            else set_fix("error","DYNAMIC POWER OFF CHANGE REJECTED") end
            return
        end

        if set_choice("set_antenna","Antenna Mode",antenna_ok,"complete","queue_antenna","ANTENNA SWITCH IS NOT AVAILABLE","SETTING ANTENNA SWITCH") then
            if fix.stage == "complete" then set_fix("complete","ALL SETTINGS VERIFIED") end
            return
        end
        if fix.stage == "wait_antenna" then
            local setting = state.settings["Antenna Mode"]
            if not setting then return end
            if antenna_ok(setting.value) then set_fix("complete","ALL SETTINGS VERIFIED")
            else set_fix("error","ANTENNA SWITCH CHANGE REJECTED") end
        end
    end

    function self.reset() reset() end
    function self.update(safe_preflight)
        poll(safe_preflight)
        process_fix(safe_preflight)
    end
    function self.beginFix(gates) return begin_fix(gates) end
    function self.getState() return state end
    function self.getCurrent() return display_values() end
    function self.getRecommended() return RECOMMENDED end
    function self.getMismatches() return mismatch_list() end
    function self.fixRequired() return #mismatch_list() > 0 end
    function self.scanComplete() return state.scan_complete end
    function self.supported() return state.supported end
    function self.setGateError(value) state.gate_error = value end

    reset()
    return self
end

M.RECOMMENDED = RECOMMENDED
return M

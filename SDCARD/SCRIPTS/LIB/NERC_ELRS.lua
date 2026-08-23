-- NERC shared ExpressLRS settings engine
-- EdgeTX 2.12 / ExpressLRS 3.x transport and verified parameter repair.
-- UI-agnostic and profile-driven. RF policy comes from NERC_RF_PROFILES.lua.

local M = {}

local CRSF_BROADCAST = 0x00
local CRSF_RADIO = 0xEA
local CRSF_ELRS_LUA = 0xEF
local CRSF_ELRS_TX = 0xEE
local DISCOVERY_WINDOW = 1200
local DISCOVERY_INTERVAL = 100
local READBACK_RETRY_LIMIT = 2
local READBACK_RETRY_DELAY = 100
local RESCAN_RETRY_LIMIT = 2
local RESCAN_DELAY = 100

local REQUIREMENT_ORDER = {
    "packetRate", "switchMode", "telemetry", "modelMatch",
    "maxPower", "dynamicPower", "antennaMode"
}

local function clean(value)
    value = value or "?"
    value = string.match(value, "^%s*(.-)%s*$") or value
    local before = string.match(value, "^(.-)%s+%(%-")
    return before or value
end

local function parameter_label(parameter)
    if type(parameter) == "table" then return table.concat(parameter, "/") end
    return tostring(parameter or "?")
end

local MATCHERS = {
    exact = function(value, target) return clean(value) == clean(target) end,
    case_insensitive = function(value, target)
        return string.lower(clean(value)) == string.lower(clean(target))
    end,
    ["333_full"] = function(value)
        local lower = string.lower(clean(value))
        return string.find(lower, "333", 1, true) ~= nil
            and string.find(lower, "full", 1, true) ~= nil
    end,
    ["8ch_full"] = function(value)
        local lower = string.lower(clean(value))
        return lower == "8ch" or string.match(lower, "^8ch[%s%-]") ~= nil
    end,
    numeric_100 = function(value)
        return tonumber(string.match(clean(value), "%d+")) == 100
    end,
}

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

local function copy_requirement(req)
    local out = {}
    for k, v in pairs(req or {}) do out[k] = v end
    return out
end

local function normalize_profile(profile)
    if type(profile) ~= "table" or type(profile.requirements) ~= "table" then
        return nil, "INVALID RF PROFILE"
    end
    local normalized = {
        id = profile.id or "UNKNOWN",
        label = profile.label or profile.id or "RF Profile",
        requirements = {},
        ordered = {},
    }
    for _, key in ipairs(REQUIREMENT_ORDER) do
        local req = profile.requirements[key]
        if req then
            local item = copy_requirement(req)
            item.key = key
            item.policy = item.policy or "required"
            item.matcher = item.matcher or "exact"
            normalized.requirements[key] = item
            normalized.ordered[#normalized.ordered + 1] = item
        end
    end
    if #normalized.ordered == 0 then return nil, "RF PROFILE HAS NO REQUIREMENTS" end
    return normalized
end

function M.new(options)
    options = options or {}
    local self = {}
    local simulation = options.simulation
    local now_fn = options.getTime or getTime
    local profile, profile_error = normalize_profile(options.profile)

    local parameter_names = {}
    local parameter_seen = {}
    if profile then
        for _, req in ipairs(profile.ordered) do
            local names = type(req.parameter) == "table" and req.parameter or { req.parameter }
            for _, name in ipairs(names) do
                if name and not parameter_seen[name] then
                    parameter_seen[name] = true
                    parameter_names[#parameter_names + 1] = name
                end
            end
        end
    end

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
        if type(crossfireTelemetryPop) == "function" then return crossfireTelemetryPop() end
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
        state.refresh_attempts = 0
        state.status_requested = false
        state.status_deadline = 0
        state.scan_complete = false
        state.status_seen = false
        state.connected = false
        state.armed = false
        state.model_mismatch = false
        state.transport_error = profile_error
        state.gate_error = nil
        state.supported = profile ~= nil and (simulation ~= nil
            or (type(crossfireTelemetryPush) == "function" and type(crossfireTelemetryPop) == "function"))
        state.fix = { stage = "idle", deadline = 0, message = "" }
    end

    local function queue_fields(ids, initial_scan)
        state.queue = ids
        state.queue_pos = 1
        state.current = nil
        state.initial_scan = initial_scan or false
    end

    local function setting_for(req)
        local names = type(req.parameter) == "table" and req.parameter or { req.parameter }
        for _, name in ipairs(names) do
            if state.settings[name] then return name, state.settings[name] end
        end
        return nil, nil
    end

    local function matcher_for(req)
        return MATCHERS[req.matcher] or MATCHERS.exact
    end

    local function requirement_matches(req, value)
        return matcher_for(req)(value, req.target)
    end

    local function target_complete()
        if not profile then return false end
        for _, req in ipairs(profile.ordered) do
            local _, setting = setting_for(req)
            if not setting and req.policy ~= "if-supported" then return false end
        end
        return true
    end

    local function missing_text()
        local missing = {}
        if profile then
            for _, req in ipairs(profile.ordered) do
                local _, setting = setting_for(req)
                if not setting and req.policy ~= "if-supported" then
                    missing[#missing + 1] = parameter_label(req.parameter)
                end
            end
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
        if parameter_seen[name] then
            state.settings[name] = {
                value = values[selected_index + 1] or "?",
                unit = unit or "",
                index = selected_index,
                values = values,
            }
            state.field_ids[name] = field_id_value
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
        state.current = { id=id, chunk=0, payload={}, deadline=now, attempts=0 }
    end

    local function refresh_targets(now)
        local ids = {}
        for _, name in ipairs(parameter_names) do
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

    local function queue_full_rescan()
        if state.fields_count <= 0 then return false end
        state.settings = {}
        state.field_ids = {}
        state.transport_error = nil
        local ids = {}
        for id = 1, state.fields_count do ids[#ids + 1] = id end
        queue_fields(ids, false)
        return true
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
            crsf_submit(0x28, { CRSF_BROADCAST, CRSF_RADIO })
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

        -- Initial discovery owns scan_complete / ELRS READ INCOMPLETE. Repair
        -- rescans are intentionally handled by process_fix() so a partial
        -- transient rescan cannot abort the remaining repair sequence.
        if not fix_active and state.device_found and not state.current and state.queue_pos > #state.queue then
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

    local function find_target(name, req)
        local setting = state.settings[name]
        if not setting or not setting.values then return nil end
        for index, value in ipairs(setting.values) do
            if requirement_matches(req, value) then return index - 1 end
        end
        return nil
    end

    local function queue_readback(name)
        local id = state.field_ids[name]
        if not id then return false end
        queue_fields({ id }, false)
        return true
    end

    local function write_choice(name, value)
        local field = state.field_ids[name]
        if not field or value == nil then return false end
        return crsf_push(0x2D, { state.device_id, state.handset_id, field, value })
    end

    local function display_values()
        local values = {}
        if not profile then return values end
        for _, req in ipairs(profile.ordered) do
            local name, setting = setting_for(req)
            local value = setting and clean(setting.value) or "?"
            if setting and setting.unit and setting.unit ~= ""
                and req.key == "maxPower"
                and not string.find(string.lower(value), "mw", 1, true) then
                value = value .. setting.unit
            end
            values[req.key] = value
            values[req.key .. "Parameter"] = name
        end
        return values
    end

    local function mismatch_list()
        local list = {}
        if not profile then return list end
        for _, req in ipairs(profile.ordered) do
            local name, setting = setting_for(req)
            if setting then
                if not requirement_matches(req, setting.value) then
                    list[#list + 1] = {
                        key=req.key, parameter=name, current=clean(setting.value),
                        target=req.display or req.target, policy=req.policy,
                    }
                end
            elseif state.scan_complete and req.policy ~= "if-supported" then
                list[#list + 1] = {
                    key=req.key, parameter=parameter_label(req.parameter), current="NOT FOUND",
                    target=req.display or req.target, policy=req.policy, missing=true,
                }
            end
        end
        return list
    end

    local function recommended_values()
        local values = {}
        if profile then
            for _, req in ipairs(profile.ordered) do
                values[req.key] = req.display or req.target
            end
        end
        return values
    end

    local function next_fix_index(start)
        if not profile then return nil end
        for index = start or 1, #profile.ordered do
            local req = profile.ordered[index]
            local _, setting = setting_for(req)
            if not setting then
                if req.policy ~= "if-supported" then return index end
            elseif not requirement_matches(req, setting.value) then
                return index
            end
        end
        return nil
    end

    local function set_fix(stage, message)
        state.fix.stage = stage
        state.fix.message = message
    end

    local function begin_fix(gates)
        gates = gates or {}
        if not gates.holdOn then return false, "ENABLE THROTTLE HOLD FIRST" end
        if state.connected or (type(gates.linkConnected) == "function" and gates.linkConnected()) then
            return false, "POWER OFF HELICOPTER FIRST"
        end
        if not state.scan_complete then return false, "ELRS SCAN NOT COMPLETE" end
        if state.transport_error then return false, state.transport_error end
        local index = next_fix_index(1)
        if not index then return false, "NO ELRS SETTINGS NEED CHANGES" end
        local now = now_fn()
        state.transport_error = nil
        state.fix = {
            stage="set", index=index, deadline=now+6000,
            next_action=now, write_retries=0, readback_retries=0, rescan_retries=0,
            message="APPLYING SETTINGS", original=display_values(),
        }
        return true
    end

    local function process_fix(safe_preflight)
        local fix = state.fix
        if fix.stage == "idle" or fix.stage == "complete" or fix.stage == "error" then return end
        if not safe_preflight then set_fix("error", "PRECHECK CHANGED - CHANGE CANCELLED"); return end
        local now = now_fn()
        if now > fix.deadline then set_fix("error", "CHANGE NOT VERIFIED - USE ELRS LUA"); return end
        if state.connected then set_fix("error", "RECEIVER CONNECTED - CHANGE CANCELLED"); return end
        if not reads_idle() or now < (fix.next_action or 0) then return end

        if fix.stage == "wait_rescan" then
            fix.stage = "set"
            fix.index = next_fix_index(1)
            fix.next_action = now + 25
            if not fix.index then set_fix("complete", "ALL SETTINGS VERIFIED") end
            return
        end

        local req = profile and profile.ordered[fix.index]
        if not req then set_fix("complete", "ALL SETTINGS VERIFIED"); return end
        local name, setting = setting_for(req)
        if not setting then
            if req.policy == "if-supported" then
                local next_index = next_fix_index(fix.index + 1)
                if next_index then fix.index = next_index else set_fix("complete", "ALL SETTINGS VERIFIED") end
            elseif (fix.rescan_retries or 0) < RESCAN_RETRY_LIMIT and queue_full_rescan() then
                fix.rescan_retries = (fix.rescan_retries or 0) + 1
                fix.stage = "wait_rescan"
                fix.next_action = now + RESCAN_DELAY
                fix.message = "REFRESHING ELRS SETTINGS"
            else
                set_fix("error", "REQUIRED ELRS SETTING NOT FOUND: " .. parameter_label(req.parameter))
            end
            return
        end

        if fix.stage == "set" then
            if requirement_matches(req, setting.value) then
                local next_index = next_fix_index(fix.index + 1)
                if next_index then
                    fix.index = next_index
                    fix.readback_retries = 0
                else
                    set_fix("complete", "ALL SETTINGS VERIFIED")
                end
                return
            end
            local target = find_target(name, req)
            if target == nil then
                set_fix("error", tostring(req.display or req.target) .. " IS NOT AVAILABLE")
            elseif not write_choice(name, target) then
                fix.write_retries = (fix.write_retries or 0) + 1
                fix.next_action = now + 10
                fix.message = "SETTING " .. tostring(req.display or req.target) .. " - CRSF BUSY"
            else
                fix.write_retries = 0
                fix.readback_retries = 0
                state.settings[name] = nil
                fix.parameter = name
                fix.stage = "queue_readback"
                fix.next_action = now + 100
                fix.message = "SETTING " .. tostring(req.display or req.target)
            end
            return
        end

        if fix.stage == "queue_readback" then
            if not queue_readback(fix.parameter) then
                if (fix.rescan_retries or 0) < RESCAN_RETRY_LIMIT and queue_full_rescan() then
                    fix.rescan_retries = (fix.rescan_retries or 0) + 1
                    fix.stage = "wait_rescan"
                    fix.next_action = now + RESCAN_DELAY
                    fix.message = "REFRESHING ELRS SETTINGS"
                else
                    set_fix("error", "ELRS PARAMETER ID NOT AVAILABLE")
                end
            else
                fix.stage = "wait_readback"
            end
            return
        end

        if fix.stage == "wait_readback" then
            local _, readback = setting_for(req)
            if not readback then return end
            if not requirement_matches(req, readback.value) then
                if (fix.readback_retries or 0) < READBACK_RETRY_LIMIT then
                    fix.readback_retries = (fix.readback_retries or 0) + 1
                    state.settings[fix.parameter] = nil
                    fix.stage = "queue_readback"
                    fix.next_action = now + READBACK_RETRY_DELAY
                    fix.message = "VERIFYING " .. tostring(req.display or req.target)
                    return
                end
                set_fix("error", tostring(req.display or req.target) .. " CHANGE REJECTED")
                return
            end
            fix.readback_retries = 0
            fix.rescan_retries = 0
            if queue_full_rescan() then
                fix.stage = "wait_rescan"
                fix.next_action = now + RESCAN_DELAY
                fix.message = "REFRESHING ELRS SETTINGS"
            else
                local next_index = next_fix_index(1)
                if next_index then
                    fix.index = next_index
                    fix.stage = "set"
                    fix.next_action = now + 25
                else
                    set_fix("complete", "ALL SETTINGS VERIFIED")
                end
            end
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
    function self.getRecommended() return recommended_values() end
    function self.getMismatches() return mismatch_list() end
    function self.fixRequired() return #mismatch_list() > 0 end
    function self.scanComplete() return state.scan_complete end
    function self.supported() return state.supported end
    function self.getProfile() return profile end
    function self.setGateError(value) state.gate_error = value end

    reset()
    return self
end

return M
-- Companion-only telemetry and ExpressLRS simulator for NERC_GSkyFD.
-- Do not copy this file to a flight radio. The VS Code simulator task places
-- it beside main.lua only inside the selected Companion simulator SD folder.

local simulator = { is_goosky_simulator = true }

-- Set to nil for the automatic cycle, or use one of the names below to hold a
-- scenario indefinitely while adjusting the layout.
local FORCED_SCENARIO = nil
local SCENARIO_SECONDS = 10
local scenarios = {
    "READY",
    "BATTERY LOW",
    "BATTERY CRITICAL",
    "LINK WEAK",
    "LINK CRITICAL",
    "TELEMETRY LOST",
    "MODEL MISMATCH",
    "ELRS SETUP BAD",
    "LIHV PACK"
}

local function scenario_index(now)
    if FORCED_SCENARIO then
        for index, name in ipairs(scenarios) do
            if name == FORCED_SCENARIO then return index end
        end
    end
    local ticks_per_scenario = SCENARIO_SECONDS * 100
    return (math.floor((now or 0) / ticks_per_scenario) % #scenarios) + 1
end

local function scenario_name(now)
    return scenarios[scenario_index(now)]
end

function simulator.getScenarioName(now)
    return scenario_name(now)
end

function simulator.getBatteryChemistry(now)
    return scenario_name(now) == "LIHV PACK" and "lihv" or "lipo"
end

local base = {
    ["1RSS"] = -52,
    ["2RSS"] = 0,
    ["RQly"] = 100,
    ["RSNR"] = 9,
    ["ANT"] = 0,
    ["RFMD"] = 8,
    ["TPWR"] = 100,
    ["TRSS"] = -48,
    ["TQly"] = 100,
    ["TSNR"] = 8,
    ["RxBt"] = 12.30,
    ["Curr"] = 4.2,
    ["Capa"] = 175,
    ["Bat%"] = 78
}

function simulator.getSensor(name, now)
    local value = base[name] or 0
    local scenario = scenario_name(now)

    if scenario == "BATTERY LOW" then
        if name == "RxBt" then value = 11.10 end
        if name == "Capa" then value = 620 end
        if name == "Bat%" then value = 17 end
    elseif scenario == "BATTERY CRITICAL" then
        if name == "RxBt" then value = 10.55 end
        if name == "Capa" then value = 710 end
        if name == "Bat%" then value = 6 end
    elseif scenario == "LINK WEAK" then
        if name == "RQly" then value = 70 end
        if name == "1RSS" then value = -98 end
        if name == "RSNR" then value = -5 end
    elseif scenario == "LINK CRITICAL" then
        if name == "RQly" then value = 25 end
        if name == "1RSS" then value = -112 end
        if name == "RSNR" then value = -12 end
    elseif scenario == "TELEMETRY LOST" then
        if name == "TQly" then value = 0 end
        if name == "TRSS" then value = 0 end
        if name == "TSNR" then value = 0 end
    elseif scenario == "LIHV PACK" then
        if name == "RxBt" then value = 13.00 end
        if name == "Capa" then value = 80 end
        if name == "Bat%" then value = 96 end
    end
    return value
end

local queue = {}
local parameters = {
    { "Packet Rate", "50Hz;333Hz Full (-105dBm)", 1, "" },
    { "Telem Ratio", "Std;Off;1:128;1:64;1:32", 4, "" },
    { "Switch Mode", "8ch;16ch Rate/2;12ch Mixed", 0, "" },
    { "Model Match", "Off;On", 1, " (ID: 07)" },
    { "Max Power", "10;25;50;100;250", 3, "mW" },
    { "Dynamic", "Off;Dyn;AUX9;AUX10;AUX11;AUX12", 0, "" }
}
local last_parameter_scenario = nil

local function push_string(target, value)
    for index = 1, #value do
        target[#target + 1] = string.byte(value, index)
    end
    target[#target + 1] = 0
end

local function apply_parameter_scenario(now)
    local name = scenario_name(now)
    if last_parameter_scenario == name then return end
    last_parameter_scenario = name

    if name == "ELRS SETUP BAD" then
        parameters[1][3] = 0 -- 50Hz
        parameters[2][3] = 0 -- Standard telemetry ratio
        parameters[3][3] = 2 -- 12ch Mixed
        parameters[5][3] = 1 -- 25mW
        parameters[6][3] = 1 -- Dynamic power on
    else
        parameters[1][3] = 1
        parameters[2][3] = 4
        parameters[3][3] = 0
        parameters[5][3] = 3
        parameters[6][3] = 0
    end
end

local function queue_parameter(field_id, handset_id)
    local parameter = parameters[field_id]
    local data = { handset_id or 0xEF, 0xEE, field_id, 0, 0, 9 }
    push_string(data, parameter[1])
    push_string(data, parameter[2])
    data[#data + 1] = parameter[3]
    data[#data + 1] = 0
    data[#data + 1] = 0
    data[#data + 1] = 0
    push_string(data, parameter[4])
    queue[#queue + 1] = { 0x2B, data }
end

function simulator.push(command, data, now)
    apply_parameter_scenario(now)
    if command == 0x28 then
        local info = { 0xEA, 0xEE }
        push_string(info, "SIM ELRS TX")
        info[#info + 1] = 0x45
        info[#info + 1] = 0x4C
        info[#info + 1] = 0x52
        info[#info + 1] = 0x53
        for _ = 1, 8 do info[#info + 1] = 0 end
        info[#info + 1] = #parameters
        queue[#queue + 1] = { 0x29, info }
    elseif command == 0x2C then
        queue_parameter(data[3], data[2])
    elseif command == 0x2D then
        if data[3] == 0 then
            local flags = scenario_name(now) == "MODEL MISMATCH" and 5 or 1
            queue[#queue + 1] = { 0x2E, { data[2], 0xEE, 0, 0, 0, flags } }
        else
            local parameter = parameters[data[3]]
            if not parameter then return false end
            parameter[3] = data[4]
            if data[3] == 1 and data[4] == 1 then
                parameters[3][2] = "8ch;16ch Rate/2;12ch Mixed"
            end
        end
    end
    return true
end

function simulator.pop()
    if #queue == 0 then return nil end
    local frame = table.remove(queue, 1)
    return frame[1], frame[2]
end

return simulator

-- Companion-only ExpressLRS module simulator for NERC development.
-- This file is injected into /SCRIPTS/LIB/NERC_ELRS_SIM.lua by the VS Code
-- simulator task. It is never part of the flight-radio SDCARD payload.
--
-- ELRS module state is intentionally independent from the FlightDeck telemetry
-- sensor simulator. Change SCENARIO here when a specific ELRS condition needs
-- to be exercised in Companion.

local simulator = { is_nerc_elrs_simulator = true }

local SCENARIO = "READY"
-- Supported scenarios:
-- READY               receiver off, all ELRS settings correct
-- SETTINGS BAD        receiver off, several ELRS settings require repair
-- MODEL MISMATCH      receiver off, ELRS model-mismatch status bit set
-- RECEIVER CONNECTED  receiver connected; writes must be blocked
-- ARMED               receiver connected + armed; writes must be blocked

local queue = {}
local parameters = {
    { "Packet Rate",  "50Hz;333Hz Full (-105dBm)",             1, "" },
    { "Telem Ratio",  "Std;Off;1:128;1:64;1:32",              4, "" },
    { "Switch Mode",  "8ch;16ch Rate/2;12ch Mixed",           0, "" },
    { "Model Match",  "Off;On",                               1, " (ID: 07)" },
    { "Max Power",    "10;25;50;100;250",                    3, "mW" },
    { "Dynamic",      "Off;Dyn;AUX9;AUX10;AUX11;AUX12",      0, "" },
    { "Antenna Mode", "Switch;ANT1;ANT2;Gemini",              0, "" },
}

local defaults = { 1, 4, 0, 1, 3, 0, 0 }
local lastScenario = nil

local function push_string(target, value)
    for index = 1, #value do
        target[#target + 1] = string.byte(value, index)
    end
    target[#target + 1] = 0
end

local function applyScenario()
    if lastScenario == SCENARIO then return end
    lastScenario = SCENARIO

    for index = 1, #parameters do
        parameters[index][3] = defaults[index]
    end

    if SCENARIO == "SETTINGS BAD" then
        parameters[1][3] = 0 -- 50Hz
        parameters[2][3] = 0 -- Standard telemetry ratio
        parameters[3][3] = 2 -- 12ch Mixed
        parameters[4][3] = 0 -- Model Match off
        parameters[5][3] = 1 -- 25mW
        parameters[6][3] = 1 -- Dynamic power on
        parameters[7][3] = 3 -- Gemini
    end
end

local function statusFlags()
    if SCENARIO == "MODEL MISMATCH" then return 0x04 end
    if SCENARIO == "RECEIVER CONNECTED" then return 0x01 end
    if SCENARIO == "ARMED" then return 0x03 end
    return 0x00
end

local function queueParameter(fieldId, handsetId)
    local parameter = parameters[fieldId]
    if not parameter then return end

    local data = { handsetId or 0xEF, 0xEE, fieldId, 0, 0, 9 }
    push_string(data, parameter[1])
    push_string(data, parameter[2])
    data[#data + 1] = parameter[3]
    data[#data + 1] = 0
    data[#data + 1] = 0
    data[#data + 1] = 0
    push_string(data, parameter[4])
    queue[#queue + 1] = { 0x2B, data }
end

function simulator.getScenarioName()
    return SCENARIO
end

function simulator.setScenario(name)
    SCENARIO = tostring(name or "READY")
    lastScenario = nil
    queue = {}
end

function simulator.push(command, data)
    applyScenario()

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
        queueParameter(data[3], data[2])
    elseif command == 0x2D then
        if data[3] == 0 then
            queue[#queue + 1] = { 0x2E, { data[2], 0xEE, 0, 0, 0, statusFlags() } }
        else
            local parameter = parameters[data[3]]
            if not parameter then return false end
            parameter[3] = data[4]
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

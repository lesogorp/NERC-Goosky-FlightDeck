-- Companion-only FlightDeck telemetry sensor simulator.
-- Do not copy this file to a flight radio. The VS Code simulator task places
-- it beside main.lua only inside the selected Companion simulator SD folder.
--
-- ELRS module emulation lives separately in /SCRIPTS/LIB/NERC_ELRS_SIM.lua so
-- dashboard telemetry scenarios never change ELRS connection/armed/settings
-- state used by the model wizard.

local simulator = {
    is_goosky_simulator = true,
    is_goosky_telemetry_simulator = true,
}

-- Set to nil for the automatic cycle, or use one of the names below to hold a
-- dashboard telemetry scenario indefinitely while adjusting the layout.
local FORCED_SCENARIO = nil
local SCENARIO_SECONDS = 10
local scenarios = {
    "READY",
    "BATTERY LOW",
    "BATTERY CRITICAL",
    "LINK WEAK",
    "LINK CRITICAL",
    "TELEMETRY LOST",
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

-- Temporary compatibility adapter for the current FlightDeck ELRS monitor.
-- The actual ELRS simulator data/state is maintained in a separate module so
-- these calls cannot inherit or react to the telemetry scenario above.
local elrsBackend = nil
local elrsBackendLoaded = false

local function getElrsBackend()
    if elrsBackendLoaded then return elrsBackend end
    elrsBackendLoaded = true
    if type(loadScript) ~= "function" then return nil end
    local okLoader, loader = pcall(loadScript, "/SCRIPTS/LIB/NERC_ELRS_SIM.lua")
    if not okLoader or type(loader) ~= "function" then return nil end
    local okBackend, backend = pcall(loader)
    if okBackend and type(backend) == "table" and backend.is_nerc_elrs_simulator then
        elrsBackend = backend
    end
    return elrsBackend
end

function simulator.push(command, data, now)
    local backend = getElrsBackend()
    if backend and type(backend.push) == "function" then
        return backend.push(command, data, now)
    end
    return false
end

function simulator.pop(now)
    local backend = getElrsBackend()
    if backend and type(backend.pop) == "function" then
        return backend.pop(now)
    end
    return nil
end

return simulator

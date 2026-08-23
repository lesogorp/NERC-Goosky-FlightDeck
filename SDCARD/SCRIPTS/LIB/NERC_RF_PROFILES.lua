-- NERC RF profile registry
-- Maps aircraft / flight-controller families to RF policy without putting
-- aircraft-specific requirements inside the ELRS transport engine.
--
-- Only hardware-verified profiles are enabled. Future aircraft/controllers can
-- be registered here once their RF requirements are proven on hardware.

local M = {}

local profiles = {
    GOOSKY_SIMPLE_ELRS = {
        id = "GOOSKY_SIMPLE_ELRS",
        label = "Goosky Simplified ELRS FC",
        protocol = "ELRS",
        enabled = true,
        hardwareVerified = true,
        controller = "Goosky simplified ELRS flight controller",
        aircraft = {
            { make = "Goosky", model = "S1 V2" },
            { make = "Goosky", model = "S2 MAX" },
        },
        requirements = {
            packetRate = {
                parameter = "Packet Rate",
                target = "333Hz Full",
                policy = "required",
                matcher = "333_full",
            },
            switchMode = {
                parameter = "Switch Mode",
                target = "8ch",
                display = "8ch Full Resolution",
                policy = "required",
                matcher = "8ch_full",
            },
            telemetry = {
                parameter = "Telem Ratio",
                target = "1:32",
                policy = "required",
                matcher = "exact",
            },
            modelMatch = {
                parameter = "Model Match",
                target = "On",
                policy = "required",
                matcher = "case_insensitive",
            },
            maxPower = {
                parameter = "Max Power",
                target = "100mW",
                policy = "recommended",
                matcher = "numeric_100",
            },
            dynamicPower = {
                parameter = { "Dynamic", "Dynamic Power" },
                target = "Off",
                policy = "recommended",
                matcher = "case_insensitive",
            },
            antennaMode = {
                parameter = "Antenna Mode",
                target = "Switch",
                policy = "if-supported",
                matcher = "case_insensitive",
            },
        },
    },

    -- Reserved profile IDs. They intentionally contain no RF policy yet; do
    -- not infer settings from product names or controller families without a
    -- hardware-verified configuration.
    OMP_OFS3_ELRS = {
        id = "OMP_OFS3_ELRS",
        label = "OMP OFS3 ELRS",
        protocol = "ELRS",
        enabled = false,
        hardwareVerified = false,
        controller = "OFS3",
        aircraft = {},
        requirements = {},
    },
    OMP_OFS3_PLUS_ELRS = {
        id = "OMP_OFS3_PLUS_ELRS",
        label = "OMP OFS3+ ELRS",
        protocol = "ELRS",
        enabled = false,
        hardwareVerified = false,
        controller = "OFS3+",
        aircraft = {},
        requirements = {},
    },
}

local aircraft_index = {}

local function normalize(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    value = string.gsub(value, "%s+", " ")
    return value
end

local function aircraft_key(make, model)
    return normalize(make) .. "|" .. normalize(model)
end

for id, profile in pairs(profiles) do
    for _, aircraft in ipairs(profile.aircraft or {}) do
        aircraft_index[aircraft_key(aircraft.make, aircraft.model)] = id
    end
end

function M.get(id)
    return profiles[id]
end

function M.forAircraft(make, model)
    local id = aircraft_index[aircraft_key(make, model)]
    if not id then return nil end
    return profiles[id]
end

function M.isUsable(profile)
    return type(profile) == "table"
        and profile.enabled == true
        and profile.hardwareVerified == true
        and profile.protocol == "ELRS"
        and type(profile.requirements) == "table"
        and next(profile.requirements) ~= nil
end

function M.requireForAircraft(make, model)
    local profile = M.forAircraft(make, model)
    if not profile then
        return nil, "NO RF PROFILE FOR " .. tostring(make or "") .. " " .. tostring(model or "")
    end
    if not M.isUsable(profile) then
        return nil, "RF PROFILE NOT VERIFIED: " .. tostring(profile.id or "UNKNOWN")
    end
    return profile
end

function M.all()
    return profiles
end

return M

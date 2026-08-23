-- NERC profile-driven ExpressLRS session facade
-- Keeps aircraft/controller RF policy separate from the shared CRSF transport.

local CORE_PATH = "/SCRIPTS/LIB/NERC_ELRS.lua"

local M = {}

local CURRENT_KEYS = {
    packetRate = "rate",
    switchMode = "channels",
    telemetry = "telemetry",
    modelMatch = "modelMatch",
    maxPower = "power",
    dynamicPower = "dynamic",
    antennaMode = "antenna",
}

local function clean(value)
    value = tostring(value or "?")
    value = string.match(value, "^%s*(.-)%s*$") or value
    local before = string.match(value, "^(.-)%s+%(%-")
    return before or value
end

local function matcher_ok(matcher, value, target)
    local v = clean(value)
    local t = clean(target)
    local lower = string.lower(v)

    if matcher == "333_full" then
        return string.find(lower, "333", 1, true) ~= nil
            and string.find(lower, "full", 1, true) ~= nil
    elseif matcher == "8ch_full" then
        return lower == "8ch" or string.match(lower, "^8ch[%s%-]") ~= nil
    elseif matcher == "case_insensitive" then
        return lower == string.lower(t)
    elseif matcher == "numeric_100" then
        return tonumber(string.match(v, "%d+")) == 100
    end
    return v == t
end

local function display_target(requirement)
    return requirement.display or requirement.target or "?"
end

function M.new(profile, options)
    if type(profile) ~= "table" or type(profile.requirements) ~= "table" then
        return nil, "INVALID RF PROFILE"
    end

    local loader = loadScript(CORE_PATH)
    if type(loader) ~= "function" then return nil, "CANNOT LOAD NERC_ELRS.LUA" end
    local factory = loader()
    loader = nil
    if type(factory) ~= "table" or type(factory.new) ~= "function" then
        return nil, "INVALID ELRS CORE"
    end

    local core = factory.new(options or {})
    local self = {}

    local function mismatches()
        local current = core.getCurrent()
        local list = {}
        for key, requirement in pairs(profile.requirements) do
            local currentKey = CURRENT_KEYS[key]
            local value = currentKey and current[currentKey] or nil
            local policy = requirement.policy or "required"

            if policy == "if-supported" and (value == nil or value == "?") then
                -- Optional capability absent on this transmitter/module.
            elseif value == nil or value == "?" then
                list[#list + 1] = {
                    key = key,
                    parameter = requirement.parameter,
                    current = "?",
                    target = display_target(requirement),
                    policy = policy,
                    reason = "unread",
                }
            elseif not matcher_ok(requirement.matcher, value, requirement.target) then
                list[#list + 1] = {
                    key = key,
                    parameter = requirement.parameter,
                    current = value,
                    target = display_target(requirement),
                    policy = policy,
                    reason = "mismatch",
                }
            end
        end
        table.sort(list, function(a,b) return tostring(a.key) < tostring(b.key) end)
        return list
    end

    function self.reset() core.reset() end
    function self.update(safePreflight) core.update(safePreflight) end
    function self.scanComplete() return core.scanComplete() end
    function self.supported() return core.supported() end
    function self.getState() return core.getState() end
    function self.getCurrent() return core.getCurrent() end
    function self.getProfile() return profile end
    function self.getMismatches() return mismatches() end
    function self.fixRequired() return #mismatches() > 0 end

    function self.getRecommended()
        local result = {}
        for key, requirement in pairs(profile.requirements) do
            result[key] = display_target(requirement)
        end
        return result
    end

    function self.beginFix(gates)
        -- The current core repair sequence is hardware-proven for GOOSKY_V2_FC.
        -- Other RF profiles may be compared immediately, but writes remain
        -- disabled until their repair sequence is hardware-verified.
        if profile.id ~= "GOOSKY_V2_FC" then
            return false, "RF PROFILE REPAIR NOT VERIFIED: " .. tostring(profile.id or "UNKNOWN")
        end
        return core.beginFix(gates)
    end

    return self
end

return M

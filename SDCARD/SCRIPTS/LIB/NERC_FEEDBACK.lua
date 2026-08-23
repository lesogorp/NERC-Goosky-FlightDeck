-- NERC radio-wide feedback preferences.
-- Shared by FlightDeck, model wizards and the NERC Feedback tool.

local M = {}

local CONFIG_PATH = "/SCRIPTS/TOOLS/NERC_Feedback.cfg"

local DEFAULTS = {
    leds = true,
    gimbalBrightness = 100,
    switchBrightness = 100,
    haptic = true,
}

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return math.floor(value + 0.5)
end

local function bool_value(value, fallback)
    if value == nil then return fallback end
    local text = string.lower(tostring(value))
    if text == "1" or text == "true" or text == "on" or text == "yes" then return true end
    if text == "0" or text == "false" or text == "off" or text == "no" then return false end
    return fallback
end

local function copy_defaults()
    return {
        leds = DEFAULTS.leds,
        gimbalBrightness = DEFAULTS.gimbalBrightness,
        switchBrightness = DEFAULTS.switchBrightness,
        haptic = DEFAULTS.haptic,
    }
end

function M.normalize(settings)
    settings = settings or {}
    return {
        leds = bool_value(settings.leds, DEFAULTS.leds),
        gimbalBrightness = clamp(settings.gimbalBrightness, 0, 100),
        switchBrightness = clamp(settings.switchBrightness, 0, 100),
        haptic = bool_value(settings.haptic, DEFAULTS.haptic),
    }
end

function M.defaults()
    return copy_defaults()
end

function M.load()
    local settings = copy_defaults()
    local file = io and io.open and io.open(CONFIG_PATH, "r") or nil
    if not file then return settings end

    local contents = io.read(file, 1024) or ""
    io.close(file)
    for line in string.gmatch(contents, "[^\r\n]+") do
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        if key == "leds" then settings.leds = value
        elseif key == "gimbalBrightness" then settings.gimbalBrightness = value
        elseif key == "switchBrightness" then settings.switchBrightness = value
        elseif key == "haptic" then settings.haptic = value end
    end
    return M.normalize(settings)
end

function M.save(settings)
    settings = M.normalize(settings)
    local file = io and io.open and io.open(CONFIG_PATH, "w") or nil
    if not file then return false, "Cannot save NERC feedback settings" end

    local contents = table.concat({
        "version=1",
        "leds=" .. (settings.leds and "1" or "0"),
        "gimbalBrightness=" .. tostring(settings.gimbalBrightness),
        "switchBrightness=" .. tostring(settings.switchBrightness),
        "haptic=" .. (settings.haptic and "1" or "0"),
        ""
    }, "\n")
    io.write(file, contents)
    io.close(file)
    return true
end

function M.scale(value, brightness)
    value = clamp(value, 0, 255)
    brightness = clamp(brightness, 0, 100)
    return math.floor((value * brightness / 100) + 0.5)
end

function M.signature(settings)
    settings = M.normalize(settings)
    return table.concat({
        settings.leds and "1" or "0",
        tostring(settings.gimbalBrightness),
        tostring(settings.switchBrightness),
        settings.haptic and "1" or "0"
    }, ":")
end

function M.path()
    return CONFIG_PATH
end

return M

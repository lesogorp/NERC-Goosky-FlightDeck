-- NERC Goosky BNF Wizard v1 - EdgeTX 2.12 color radios
-- Native LVGL wizard port of the proven GooskySetup model writer.
-- ELRS setting check/fix is intentionally OUTSIDE this initial wizard port.

local STOCK_WIZARD_DIR = "/TEMPLATES/1.Wizard/lib"
local wizard = loadScript(STOCK_WIZARD_DIR .. "/wizard-ui.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local AUTO_CFG_PREFIX = "/SCRIPTS/TOOLS/NERC_GSkyFD_"
local LEGACY_AUTO_CFG_PREFIX = "/WIDGETS/NERC_GSkyFD/auto_"

local page = 1
local pages = {}
local applyResult = nil
local applyError = nil

-- All listed aircraft use the same Goosky CH1-CH6 control contract.
-- Only S1 V2 and S2 MAX currently have verified throttle/model defaults from
-- the existing GooskySetup proof of concept. The wizard will not guess the
-- throttle/governor setup for the other models.
local models = {
    { name = "S1 V1", telemetry = false, rf = "SBUS", profileReady = false },
    { name = "S1 V2", telemetry = true, rf = "CRSF / ELRS", profileReady = true, imagePrefix = "GKS1" },
    { name = "S2 Legend V1", telemetry = false, rf = "SBUS / CRSF (FW)", profileReady = false },
    { name = "S2 MAX", telemetry = true, rf = "CRSF / ELRS", profileReady = true, imagePrefix = "GKS2" },
    { name = "RS4 Venom", telemetry = false, rf = "SBUS", profileReady = false },
}

local colors = {
    { name = "Orange", suffix = "OR" },
    { name = "Blue", suffix = "BL" },
    { name = "Purple", suffix = "PU" },
}

local switchNames = { "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH" }
local switchPositions = {}
local switchPositionData = {}
for _, name in ipairs(switchNames) do
    for _, position in ipairs({ "up", "mid", "down" }) do
        switchPositions[#switchPositions + 1] = name .. " " .. string.upper(position)
        switchPositionData[#switchPositionData + 1] = { name = name, position = position }
    end
end

local timerValues = {}
local timerSeconds = {}
for seconds = 30, 1200, 30 do
    timerSeconds[#timerSeconds + 1] = seconds
    timerValues[#timerValues + 1] = string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local fields = {
    model = 2, -- S1 V2
    color = 1,
    timer = 10, -- 5:00
    att = 1,
    bank = 1,
    hold = 16, -- SF UP
    reset = 7, -- SC UP
}

local function selectedModel()
    return models[fields.model]
end

local function clean(value)
    return string.gsub(tostring(value or ""), "[\r\n]", "")
end

local function fieldId(name)
    local info = getFieldInfo and getFieldInfo(name)
    if not info or info.id == nil then error("Missing EdgeTX source: " .. name) end
    return info.id
end

local function sourceIndex(name)
    local index = type(getSourceIndex) == "function" and getSourceIndex(name) or 0
    if index and index ~= 0 then return index end
    return fieldId(string.lower(name))
end

local function switchPosition(name, position)
    if type(getSwitchIndex) ~= "function" then error("getSwitchIndex unavailable") end
    local suffix = position == "up" and "\194\130"
        or (position == "mid" and "-" or "\194\131")
    local index = getSwitchIndex(name .. suffix)
    if not index or index == 0 then error("Cannot resolve " .. name .. " " .. position) end
    return index
end

local function selectedPosition(index)
    local item = switchPositionData[index]
    if not item then error("Invalid switch selection") end
    return item.name, item.position
end

local function clearChannel(channel)
    if model.deleteMixes then
        model.deleteMixes(channel)
        return
    end
    if not model.getMixesCount or not model.deleteMix then error("Mix delete API unavailable") end
    for line = model.getMixesCount(channel) - 1, 0, -1 do model.deleteMix(channel, line) end
end

local TRIM_MODE_NONE = 31
local FLIGHT_MODE_COUNT = 9

local function disableAllTrims()
    if not model or type(model.setFlightMode) ~= "function"
        or type(model.getFlightMode) ~= "function" then
        error("This EdgeTX build cannot disable the trim keys")
    end

    local trimValues = { 0, 0, 0, 0, 0, 0 }
    local trimModes = {
        TRIM_MODE_NONE, TRIM_MODE_NONE, TRIM_MODE_NONE,
        TRIM_MODE_NONE, TRIM_MODE_NONE, TRIM_MODE_NONE
    }

    for flightMode = 0, FLIGHT_MODE_COUNT - 1 do
        local result = model.setFlightMode(flightMode, {
            trimsValues = trimValues,
            trimsModes = trimModes
        })
        if result ~= 0 then error("Cannot disable trims in flight mode " .. tostring(flightMode)) end
    end

    for flightMode = 0, FLIGHT_MODE_COUNT - 1 do
        local info = model.getFlightMode(flightMode)
        if type(info) ~= "table" or type(info.trimsModes) ~= "table" or #info.trimsModes == 0 then
            error("Cannot verify trims in flight mode " .. tostring(flightMode))
        end
        for _, mode in ipairs(info.trimsModes) do
            if tonumber(mode) ~= TRIM_MODE_NONE then
                error("Trim keys remain enabled in flight mode " .. tostring(flightMode))
            end
        end
    end
end

local function disableFunctionSwitchWarnings()
    if not model or type(model.setSwitchWarning) ~= "function" then return false end
    for index = 1, 6 do
        local ok = pcall(model.setSwitchWarning, "SW" .. tostring(index), 0)
        if not ok then return false end
    end
    return true
end

local function modelConfigKey(info)
    local raw = type(info) == "table" and (info.filename or info.name) or "model"
    local key = string.lower(clean(raw))
    key = string.gsub(key, "[^%w_-]", "_")
    if key == "" then key = "model" end
    return key
end

local function saveDashboardSwitches(info, bankName, holdSwitch, resetSwitch)
    local content = table.concat({
        "version=1",
        "bank_source=" .. tostring(sourceIndex(bankName) or 0),
        "bank_name=" .. clean(bankName),
        "hold_switch=" .. tostring(holdSwitch or 0),
        "reset_switch=" .. tostring(resetSwitch or 0),
        ""
    }, "\n")

    local paths = {
        AUTO_CFG_PREFIX .. modelConfigKey(info) .. ".cfg",
        AUTO_CFG_PREFIX .. modelConfigKey({ name = info and info.name or "model" }) .. ".cfg",
        LEGACY_AUTO_CFG_PREFIX .. modelConfigKey(info) .. ".cfg",
        LEGACY_AUTO_CFG_PREFIX .. modelConfigKey({ name = info and info.name or "model" }) .. ".cfg",
    }

    local written = {}
    for _, path in ipairs(paths) do
        if not written[path] then
            local file = io and io.open and io.open(path, "w") or nil
            if not file then error("Cannot save dashboard switch settings: " .. path) end
            io.write(file, content)
            io.close(file)
            written[path] = true
        end
    end
end

local function telemetrySwitch()
    for _, name in ipairs({ "TELE", "Telemetry", "TELEM" }) do
        local candidate = getSwitchIndex(name)
        if candidate and candidate ~= 0 then return candidate end
    end
    return 0
end

local function applyVerifiedModel()
    local selected = selectedModel()
    if not selected.profileReady then
        error(selected.name .. " throttle/model defaults are not yet verified")
    end

    local attName, attPosition = selectedPosition(fields.att)
    local holdName, holdPosition = selectedPosition(fields.hold)
    local resetName, resetPosition = selectedPosition(fields.reset)
    local bankName = switchNames[fields.bank]

    local poseSwitch = switchPosition(attName, attPosition)
    local holdSwitch = switchPosition(holdName, holdPosition)
    local resetSwitch = switchPosition(resetName, resetPosition)
    local bankUp = switchPosition(bankName, "up")
    local bankMid = switchPosition(bankName, "mid")
    local bankDown = switchPosition(bankName, "down")

    local logicalTimer = getSwitchIndex("L01") or getSwitchIndex("L1")
    if not logicalTimer or logicalTimer == 0 then error("Cannot resolve logical switch L01") end
    local logicalFlight = logicalTimer + 1

    local srcAil = fieldId("ail")
    local srcEle = fieldId("ele")
    local srcThr = fieldId("thr")
    local srcRud = fieldId("rud")
    local srcMax = fieldId("max")
    local srcCh3 = fieldId("ch3")
    local srcS1 = sourceIndex("S1")
    local srcS2 = sourceIndex("S2")

    local alwaysOn = getSwitchIndex("ON")
    if not alwaysOn or alwaysOn == 0 then error("Cannot resolve ON switch") end

    local telemetryOn = telemetrySwitch()
    if telemetryOn == 0 then error("Cannot resolve EdgeTX TELE switch") end
    if type(FUNC_LOGS) ~= "number" then error("This EdgeTX build does not expose SD Logs") end
    if type(FUNC_PLAY_TRACK) ~= "number" then error("This EdgeTX build does not expose Play Track") end

    for channel = 0, 5 do clearChannel(channel) end

    -- Exact S1 V2 / S2 MAX throttle curves currently proven in GooskySetup.
    assert(model.setCurve(0, { name = "THR1", y = { -100, 25, 25, 25, 25 } }) == 0)
    assert(model.setCurve(1, { name = "THR2", y = { 35, 35, 35, 35, 35 } }) == 0)
    assert(model.setCurve(2, { name = "THR3", y = { 45, 45, 45, 45, 45 } }) == 0)

    model.insertMix(0, 0, { source = srcAil, name = "Aileron", weight = 100, carryTrim = false })
    model.insertMix(1, 0, { source = srcEle, name = "Elevator", weight = 100, carryTrim = false })
    model.insertMix(2, 0, { source = srcThr, name = "Bank 1", weight = 100, carryTrim = false, curveType = 3, curveValue = 1 })
    model.insertMix(2, 1, { source = srcThr, name = "Bank 2", weight = 100, carryTrim = false, switch = bankMid, multiplex = 2, curveType = 3, curveValue = 2 })
    model.insertMix(2, 2, { source = srcThr, name = "Bank 3", weight = 100, carryTrim = false, switch = bankDown, multiplex = 2, curveType = 3, curveValue = 3 })
    model.insertMix(3, 0, { source = srcRud, name = "Rudder", weight = 100, carryTrim = false })
    model.insertMix(4, 0, { source = srcMax, name = "3D", weight = -100, carryTrim = false })
    model.insertMix(4, 1, { source = srcMax, name = "ATT", weight = 100, carryTrim = false, switch = poseSwitch, multiplex = 2 })
    model.insertMix(5, 0, { source = srcThr, name = "Collective", weight = 100, carryTrim = false })

    disableAllTrims()

    for channel, name in ipairs({ "AIL", "ELE", "MOTOR", "RUD", "POSE", "PITCH" }) do
        model.setOutput(channel - 1, { name = name })
    end

    -- L01: commanded motor throttle >20% while HOLD is released.
    -- L02: L01 plus live telemetry. This preserves current GooskySetup timer
    -- semantics for the two telemetry-capable verified models.
    model.setLogicalSwitch(0, {
        func = LS_FUNC_VPOS,
        v1 = srcCh3,
        v2 = 20,
        ["and"] = -holdSwitch,
        delay = 0,
        duration = 0
    })
    model.setLogicalSwitch(1, {
        func = LS_FUNC_AND,
        v1 = logicalTimer,
        v2 = telemetryOn,
        ["and"] = 0,
        delay = 0,
        duration = 0
    })

    local seconds = timerSeconds[fields.timer]
    model.setTimer(0, {
        mode = logicalFlight,
        start = seconds,
        value = seconds,
        countdownBeep = 2,
        minuteBeep = false,
        persistent = 0,
        name = "LIMIT"
    })
    model.setTimer(1, {
        mode = logicalFlight,
        start = 0,
        value = 0,
        countdownBeep = 0,
        minuteBeep = false,
        persistent = 0,
        name = "FLIGHT"
    })

    model.setCustomFunction(0, {
        switch = holdSwitch,
        func = FUNC_OVERRIDE_CHANNEL,
        param = 2,
        value = -100,
        mode = 0,
        active = 1
    })

    model.setCustomFunction(1, { switch = resetSwitch, func = FUNC_RESET, param = 0, value = 0, mode = 0, active = 1 })
    model.setCustomFunction(2, { switch = resetSwitch, func = FUNC_RESET, param = 0, value = 1, mode = 0, active = 1 })
    model.setCustomFunction(3, { switch = alwaysOn, func = FUNC_BACKLIGHT, param = 0, value = srcS1, mode = 0, active = 1 })
    model.setCustomFunction(4, { switch = alwaysOn, func = FUNC_VOLUME, param = 0, value = srcS2, mode = 0, active = 1 })
    model.setCustomFunction(5, { switch = telemetryOn, func = FUNC_LOGS, param = 10, value = 0, mode = 0, active = 1 })

    local function setVoiceAlert(index, switch, track)
        model.setCustomFunction(index, {
            switch = switch,
            func = FUNC_PLAY_TRACK,
            name = track,
            repetition = -1,
            active = 1
        })
    end

    setVoiceAlert(6, holdSwitch, "thrhld")
    setVoiceAlert(7, -holdSwitch, "thract")
    setVoiceAlert(8, bankUp, "bank-1")
    setVoiceAlert(9, bankMid, "bank-2")
    setVoiceAlert(10, bankDown, "bank-3")
    setVoiceAlert(11, -poseSwitch, "3d-mod")
    setVoiceAlert(12, poseSwitch, "sxrstb")
    setVoiceAlert(13, resetSwitch, "timrs1")

    -- Existing proven EdgeTX module setup for the native ELRS S1 V2/S2 MAX.
    -- This only selects CRSF/8ch; ExpressLRS packet rate, telemetry ratio,
    -- power and dynamic-power check/fix are deliberately NOT part of wizard v1.
    model.setModule(0, { Type = 5, firstChannel = 0, channelsCount = 8 })

    local color = colors[fields.color]
    local info = model.getInfo()
    info.name = selected.name .. " " .. color.name
    if selected.imagePrefix then info.bitmap = selected.imagePrefix .. color.suffix .. ".png" end
    info.jitterFilter = 1 -- per-model ADC filter override OFF
    model.setInfo(info)

    disableFunctionSwitchWarnings()
    saveDashboardSwitches(info, bankName, holdSwitch, resetSwitch)
end

local function selectPage(step)
    local nextPage = page + step
    if nextPage < 1 or nextPage > #pages then return end
    page = nextPage
    pages[page]()
end

local function choiceRow(title, values, getFn, setFn)
    return wizard.settings({
        title = title,
        children = {
            {
                type = "choice",
                values = values,
                get = getFn,
                set = setFn,
            },
        },
    })
end

local function textBlock(text, color)
    return {
        type = "label",
        w = lvgl.PERCENT_SIZE + 100,
        color = color,
        text = text,
    }
end

local function modelPage()
    lvgl.clear()
    local modelNames = {}
    local colorNames = {}
    for _, item in ipairs(models) do modelNames[#modelNames + 1] = item.name end
    for _, item in ipairs(colors) do colorNames[#colorNames + 1] = item.name end

    local children1 = {
        choiceRow("Goosky model", modelNames,
            function() return fields.model end,
            function(value) fields.model = value end),
        choiceRow("Color", colorNames,
            function() return fields.color end,
            function(value) fields.color = value end),
        choiceRow("Timer 1 limit", timerValues,
            function() return fields.timer end,
            function(value) fields.timer = value end),
    }

    local children2 = {
        textBlock("Supported list: S1 V1, S1 V2, S2 Legend V1, S2 MAX, RS4 Venom."),
        textBlock("S1 V2 and S2 MAX currently have verified model-write profiles."),
        textBlock("ELRS settings check/fix is outside Wizard v1."),
    }

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Model",
        hasPrevious = false,
        hasNext = true,
        nextFunc = function() selectPage(1) end,
        children1 = children1,
        children2 = children2,
    }))
end

local function switchesPage()
    lvgl.clear()

    local children1 = {
        choiceRow("ATT switch / position", switchPositions,
            function() return fields.att end,
            function(value) fields.att = value end),
        choiceRow("BANK switch", switchNames,
            function() return fields.bank end,
            function(value) fields.bank = value end),
        choiceRow("HOLD switch / position", switchPositions,
            function() return fields.hold end,
            function(value) fields.hold = value end),
        choiceRow("Timer reset / position", switchPositions,
            function() return fields.reset end,
            function(value) fields.reset = value end),
    }

    local children2 = {
        textBlock("Wizard v1 starts with standard EdgeTX choices."),
        textBlock("Switch-movement auto-detection from GooskySetup is the next parity step."),
    }

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Switches",
        hasPrevious = true,
        hasNext = true,
        previousFunc = function() selectPage(-1) end,
        nextFunc = function() selectPage(1) end,
        children1 = children1,
        children2 = children2,
    }))
end

local function summaryPage()
    lvgl.clear()
    local selected = selectedModel()

    local rows = {
        wizard.summaryLine("Model", nil, selected.name),
        wizard.summaryLine("Color", nil, colors[fields.color].name),
        wizard.summaryLine("RF interface", nil, selected.rf),
        wizard.summaryLine("Telemetry", nil, selected.telemetry and "Supported" or "Not available"),
        wizard.summaryLine("ATT", nil, switchPositions[fields.att]),
        wizard.summaryLine("BANK", nil, switchNames[fields.bank]),
        wizard.summaryLine("HOLD", nil, switchPositions[fields.hold]),
        wizard.summaryLine("RESET", nil, switchPositions[fields.reset]),
        wizard.summaryLine("Timer", nil, timerValues[fields.timer]),
    }

    local children2
    if selected.profileReady then
        children2 = {
            textBlock("NEXT WILL MODIFY THE CURRENT MODEL."),
            textBlock("Writes CH1-CH6, curves, L01-L02, timers and special functions."),
            textBlock("MOTOR MUST BE DISCONNECTED."),
        }
    else
        children2 = {
            textBlock("Channel layout is known."),
            textBlock("Throttle/model defaults are not yet verified, so this build will NOT modify the model."),
        }
    end

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Review",
        hasPrevious = true,
        hasNext = true,
        previousFunc = function() selectPage(-1) end,
        nextFunc = function() selectPage(1) end,
        children1 = rows,
        children2 = children2,
    }))
end

local function resultPage()
    local selected = selectedModel()

    if selected.profileReady and applyResult == nil then
        local ok, err = pcall(applyVerifiedModel)
        if ok then
            applyResult = true
        else
            applyResult = false
            applyError = tostring(err)
        end
    elseif not selected.profileReady then
        applyResult = nil
        applyError = nil
    end

    lvgl.clear()

    local children1 = {}
    local children2 = {}

    if not selected.profileReady then
        children1 = {
            textBlock(selected.name .. " selected."),
            textBlock("No model changes were made."),
        }
        children2 = {
            textBlock("Shared CH1-CH6 layout is recorded."),
            textBlock("Model-specific throttle/governor defaults must be verified before enabling writes."),
        }
    elseif applyResult then
        children1 = {
            textBlock("Model configuration applied successfully."),
            textBlock(selected.name .. " / " .. colors[fields.color].name),
            textBlock("ELRS settings were NOT checked or changed."),
        }
        children2 = {
            textBlock("Manual step: MDL > Customizable Switches > set SW1-SW6 Type to NONE."),
            textBlock("Then connect the helicopter and discover telemetry sensors."),
            textBlock("Review outputs before flight. Motor must remain disconnected during bench checks."),
        }
    else
        children1 = {
            textBlock("MODEL SETUP FAILED"),
            textBlock(clean(applyError or "Unknown error")),
        }
        children2 = {
            textBlock("The model may be partially changed."),
            textBlock("Review all mixes, outputs and safety functions before use."),
        }
    end

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = selected.profileReady and "Result" or "Profile Pending",
        hasPrevious = false,
        hasNext = false,
        children1 = children1,
        children2 = children2,
    }))
end

local function init()
    applyResult = nil
    applyError = nil
    pages = {
        modelPage,
        switchesPage,
        summaryPage,
        resultPage,
    }
    page = 1
    pages[page]()
end

local function run(event, touchState)
    if event == EVT_VIRTUAL_PREV_PAGE and page > 1 and page < #pages then
        killEvents(event)
        selectPage(-1)
    elseif event == EVT_VIRTUAL_NEXT_PAGE and page < #pages then
        killEvents(event)
        selectPage(1)
    end

    if wizard.exitWizard() == true then return 2 end
    return 0
end

return {
    init = init,
    run = run,
}

-- NERC Goosky BNF Wizard apply backend
-- EdgeTX 2.12 color radios
-- Programs only the hardware-verified S1 V2 and S2 MAX profiles.
-- Intentionally contains no ELRS packet-rate, telemetry-ratio, power,
-- dynamic-power, antenna-mode validation or auto-fix logic.

local AUTO_CFG_PREFIX = "/SCRIPTS/TOOLS/NERC_GSkyFD_"
local LEGACY_AUTO_CFG_PREFIX = "/WIDGETS/NERC_GSkyFD/auto_"
local TRIM_MODE_NONE = 31
local FLIGHT_MODE_COUNT = 9

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

local function inputSource(index)
    local name = "I" .. tostring(index)
    local source = type(getSourceIndex) == "function" and getSourceIndex(name) or 0
    if source and source ~= 0 then return source end
    local info = getFieldInfo and (getFieldInfo(name) or getFieldInfo(string.lower(name)))
    if info and info.id ~= nil then return info.id end
    error("Cannot resolve EdgeTX input " .. name)
end

local function switchPosition(name, position)
    if type(getSwitchIndex) ~= "function" then error("getSwitchIndex unavailable") end
    local suffix = position == "up" and "\194\130"
        or (position == "mid" and "-" or "\194\131")
    local index = getSwitchIndex(name .. suffix)
    if not index or index == 0 then error("Cannot resolve " .. name .. " " .. position) end
    return index
end

local function modelConfigKey(info)
    local raw = type(info) == "table" and (info.filename or info.name) or "model"
    local key = string.lower(clean(raw))
    key = string.gsub(key, "[^%w_-]", "_")
    if key == "" then key = "model" end
    return key
end

local function writeFile(path, content)
    local file = io and io.open and io.open(path, "w") or nil
    if not file then error("Cannot save dashboard switch settings") end
    io.write(file, content)
    io.close(file)
end

local function saveDashboardSwitches(info, bankSource, bankName, holdSwitch, resetSwitch)
    local content = table.concat({
        "version=1",
        "bank_source=" .. tostring(bankSource or 0),
        "bank_name=" .. clean(bankName),
        "hold_switch=" .. tostring(holdSwitch or 0),
        "reset_switch=" .. tostring(resetSwitch or 0),
        ""
    }, "\n")

    local fileKey = modelConfigKey(info)
    local nameKey = modelConfigKey({ name = info and info.name or "model" })
    local path = AUTO_CFG_PREFIX .. fileKey .. ".cfg"
    local namePath = AUTO_CFG_PREFIX .. nameKey .. ".cfg"
    local legacyPath = LEGACY_AUTO_CFG_PREFIX .. fileKey .. ".cfg"
    local legacyNamePath = LEGACY_AUTO_CFG_PREFIX .. nameKey .. ".cfg"

    writeFile(path, content)
    if namePath ~= path then writeFile(namePath, content) end
    writeFile(legacyPath, content)
    if legacyNamePath ~= legacyPath then writeFile(legacyNamePath, content) end
end

local function clearChannel(channel)
    if model.deleteMixes then
        model.deleteMixes(channel)
        return
    end
    if not model.getMixesCount or not model.deleteMix then error("Mix delete API unavailable") end
    for line = model.getMixesCount(channel) - 1, 0, -1 do model.deleteMix(channel, line) end
end

local function disableFunctionSwitchWarnings()
    if not model or type(model.setSwitchWarning) ~= "function" then return end
    for index = 1, 6 do pcall(model.setSwitchWarning, "SW" .. tostring(index), 0) end
end

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

local function findTelemetrySwitch()
    for _, name in ipairs({ "TELE", "Telemetry", "TELEM" }) do
        local candidate = getSwitchIndex(name)
        if candidate and candidate ~= 0 then return candidate end
    end
    error("Cannot resolve the EdgeTX TELE switch")
end

local function imageName(modelName, color)
    local prefix = modelName == "S1 V2" and "GKS1" or "GKS2"
    local code = color == "Orange" and "OR" or (color == "Blue" and "BL" or "PU")
    return prefix .. code .. ".png"
end

local function apply(payload)
    if type(payload) ~= "table" then error("Missing wizard configuration") end
    if payload.modelName ~= "S1 V2" and payload.modelName ~= "S2 MAX" then
        error("Selected model profile is not yet verified")
    end
    if not payload.receiverId or payload.receiverId < 1 or payload.receiverId > 63 then
        error("Invalid Receiver ID")
    end
    if not payload.atti or not payload.bank or not payload.hold or not payload.reset then
        error("Switch assignments are incomplete")
    end

    local bankName = clean(payload.bank.name)
    local bankSource = sourceIndex(bankName)
    local bankUp = switchPosition(bankName, "up")
    local bankMid = switchPosition(bankName, "mid")
    local bankDown = switchPosition(bankName, "down")
    local poseSwitch = switchPosition(payload.atti.name, payload.atti.position)
    local holdSwitch = switchPosition(payload.hold.name, payload.hold.position)
    local resetSwitch = switchPosition(payload.reset.name, payload.reset.position)

    local logicalTimer = getSwitchIndex("L01") or getSwitchIndex("L1")
    if not logicalTimer or logicalTimer == 0 then error("Cannot resolve logical switch L01") end
    local logicalFlight = logicalTimer + 1

    if not model or type(model.defaultInputs) ~= "function" then
        error("This EdgeTX build cannot create default inputs")
    end
    model.defaultInputs()

    local srcAil = inputSource(1)
    local srcEle = inputSource(2)
    local srcThr = inputSource(3)
    local srcRud = inputSource(4)
    local srcMax = fieldId("max")
    local srcCh3 = fieldId("ch3")
    local srcS1 = sourceIndex("S1")
    local srcS2 = sourceIndex("S2")
    local alwaysOn = getSwitchIndex("ON")
    if not alwaysOn or alwaysOn == 0 then error("Cannot resolve the ON switch") end
    local telemetryOn = findTelemetrySwitch()

    if type(FUNC_LOGS) ~= "number" then error("This EdgeTX build does not expose SD Logs") end
    if type(FUNC_PLAY_TRACK) ~= "number" then error("This EdgeTX build does not expose Play Track") end

    for channel = 0, 5 do clearChannel(channel) end

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

    model.setLogicalSwitch(0, {
        func = LS_FUNC_VPOS, v1 = srcCh3, v2 = 20,
        ["and"] = 0, delay = 0, duration = 0
    })
    model.setLogicalSwitch(1, {
        func = LS_FUNC_AND, v1 = logicalTimer, v2 = telemetryOn,
        ["and"] = -holdSwitch, delay = 0, duration = 0
    })

    local seconds = tonumber(payload.timerSeconds) or 300
    model.setTimer(0, {
        mode = logicalFlight, start = seconds, value = seconds,
        countdownBeep = 2, minuteBeep = false, persistent = 0, name = "LIMIT"
    })
    model.setTimer(1, {
        mode = logicalFlight, start = 0, value = 0,
        countdownBeep = 0, minuteBeep = false, persistent = 0, name = "FLIGHT"
    })

    model.setCustomFunction(0, {
        switch = holdSwitch, func = FUNC_OVERRIDE_CHANNEL,
        param = 2, value = -100, mode = 0, active = 1
    })
    model.setCustomFunction(1, { switch = resetSwitch, func = FUNC_RESET, param = 0, value = 0, mode = 0, active = 1 })
    model.setCustomFunction(2, { switch = resetSwitch, func = FUNC_RESET, param = 0, value = 1, mode = 0, active = 1 })
    model.setCustomFunction(3, { switch = alwaysOn, func = FUNC_BACKLIGHT, param = 0, value = srcS1, mode = 0, active = 1 })
    model.setCustomFunction(4, { switch = alwaysOn, func = FUNC_VOLUME, param = 0, value = srcS2, mode = 0, active = 1 })
    model.setCustomFunction(5, { switch = telemetryOn, func = FUNC_LOGS, param = 10, value = 0, mode = 0, active = 1 })

    local function voice(index, sw, track)
        model.setCustomFunction(index, {
            switch = sw, func = FUNC_PLAY_TRACK, name = track,
            repetition = -1, active = 1
        })
    end
    voice(6, holdSwitch, "thrhld")
    voice(7, -holdSwitch, "thract")
    voice(8, bankUp, "bank-1")
    voice(9, bankMid, "bank-2")
    voice(10, bankDown, "bank-3")
    voice(11, -poseSwitch, "3d-mod")
    voice(12, poseSwitch, "sxrstb")
    voice(13, resetSwitch, "timrs1")

    model.setModule(0, {
        Type = 5,
        modelId = payload.receiverId,
        firstChannel = 0,
        channelsCount = 8
    })

    local info = model.getInfo()
    info.name = payload.modelName .. " " .. payload.color
    info.bitmap = imageName(payload.modelName, payload.color)
    info.jitterFilter = 1
    model.setInfo(info)

    disableFunctionSwitchWarnings()
    saveDashboardSwitches(info, bankSource, bankName, holdSwitch, resetSwitch)
    return true
end

return apply

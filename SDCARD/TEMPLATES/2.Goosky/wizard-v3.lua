-- NERC Goosky BNF Wizard v1 diagnostic build
-- EdgeTX 2.12 color radios
-- Switch capture and Receiver ID allocation are enabled.
-- No ELRS check/fix and no model writes yet.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local IMAGE_DIR = "/IMAGES/"
local MODELS_DIR = "/MODELS"
local wizard = loadScript(RUN_DIR .. "/wizard-ui.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local MAX_RECEIVER_ID = 63
local TARGET_MODULE_INDEX = 0
local TARGET_RF_TYPE = "TYPE_CROSSFIRE"
local TARGET_RF_SUBTYPE = "0"
local SWITCH_SETTLE_TICKS = 20       -- getTime() is 10 ms/tick => 200 ms
local MOMENTARY_RETURN_TICKS = 8     -- 80 ms after spring return

local page = 1
local pages = {}

local models = { "S1 V1", "S1 V2", "S2 Legend V1", "S2 MAX", "RS4 Venom" }
local standardColors = { "Orange", "Blue", "Purple" }
local rs4VenomColors = { "Orange", "Green" }
local timers = { "3:00", "3:30", "4:00", "4:30", "5:00", "5:30", "6:00" }

local receiverIdModels = {
    ["S1 V2"] = true,
    ["S2 MAX"] = true,
}

local state = {
    model = 2,
    color = 1,
    timer = 5,
    switches = {
        atti = nil,
        bank = nil,
        hold = nil,
        reset = nil,
    },
    capture = {
        active = nil,
        sources = {},
        snapshot = {},
        initial = {},
        candidateName = nil,
        candidatePosition = nil,
        candidateSince = 0,
        lastNonInitial = nil,
        returnedToInitial = false,
    },
    receiver = {
        id = nil,
        status = "not-scanned",
        scannedModels = 0,
        matchingModels = 0,
        usedIds = 0,
    },
}

local switchRows = {
    { key = "atti",  label = "ATTI" },
    { key = "bank",  label = "BANK" },
    { key = "hold",  label = "THROTTLE HOLD" },
    { key = "reset", label = "TIMER RESET" },
}

local function currentColors()
    if models[state.model] == "RS4 Venom" then return rs4VenomColors end
    return standardColors
end

local function colorCode(color)
    if color == "Orange" then return "OR" end
    if color == "Blue" then return "BL" end
    if color == "Purple" then return "PU" end
    if color == "Green" then return "GR" end
    return nil
end

local function previewImagePath()
    local modelName = models[state.model]
    local code = colorCode(currentColors()[state.color])
    local prefix = nil

    if modelName == "S1 V2" then
        prefix = "GKS1"
    elseif modelName == "S2 MAX" then
        prefix = "GKS2"
    end

    if not prefix or not code then return nil end

    local suffix = wizard.isLargeLCD() and "_800.png" or ".png"
    local path = IMAGE_DIR .. prefix .. code .. suffix
    if type(fstat) == "function" and not fstat(path) then return nil end
    return path
end

local function choiceRow(title, values, getter, setter)
    return wizard.settings({
        title = title,
        children = {
            {
                type = "choice",
                values = values,
                get = getter,
                set = setter,
            },
        },
    })
end

local function label(text)
    return {
        type = "label",
        w = lvgl.PERCENT_SIZE + 100,
        color = wizard.textColor(),
        font = wizard.metrics().fieldFont,
        text = text,
    }
end

local function scanDiagnosticLabel()
    return label(
        "Scan " .. tostring(state.receiver.scannedModels)
        .. " / CRSF " .. tostring(state.receiver.matchingModels)
        .. " / IDs " .. tostring(state.receiver.usedIds)
    )
end

local function previewChildren(includeDiagnostic)
    local children = {}
    local path = previewImagePath()

    if path then
        if wizard.isLargeLCD() then
            children[#children + 1] = wizard.image({
                file = path,
                visibleFunc = function() return true end,
            })
        else
            -- Explicit compact image box for the 480x320 class. The normal
            -- Goosky assets are 180-ish pixels wide and fit this column.
            children[#children + 1] = {
                type = "image",
                w = 170,
                h = 154,
                file = path,
                visible = function() return true end,
            }
        end
    else
        children[#children + 1] = label("Model preview")
        children[#children + 1] = label("Matching image not installed yet.")
    end

    if includeDiagnostic then
        children[#children + 1] = scanDiagnosticLabel()
    end
    return children
end

local function sourceExists(name)
    if type(getFieldInfo) ~= "function" then return false end
    local info = getFieldInfo(string.lower(name))
    return info and info.id ~= nil
end

local function readPhysicalSwitch(name)
    if type(getValue) ~= "function" then return nil end
    local value = getValue(string.lower(name))
    if type(value) ~= "number" then return nil end
    return value
end

local function positionFromValue(value)
    if value < -512 then return "up" end
    if value > 512 then return "down" end
    return "mid"
end

local function positionDisplay(position)
    if position == "up" then return "UP" end
    if position == "down" then return "DOWN" end
    return "MID"
end

local function resetCaptureCandidate()
    state.capture.candidateName = nil
    state.capture.candidatePosition = nil
    state.capture.candidateSince = 0
    state.capture.lastNonInitial = nil
    state.capture.returnedToInitial = false
end

local function buildSwitchSources()
    state.capture.sources = {}
    for _, name in ipairs({ "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "SI", "SJ" }) do
        if sourceExists(name) then
            state.capture.sources[#state.capture.sources + 1] = name
        end
    end

    if #state.capture.sources == 0 then
        state.capture.sources = { "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH" }
    end
end

local function snapshotSwitches()
    state.capture.snapshot = {}
    state.capture.initial = {}
    resetCaptureCandidate()

    for _, name in ipairs(state.capture.sources) do
        local value = readPhysicalSwitch(name)
        state.capture.snapshot[name] = value
        if value ~= nil then
            state.capture.initial[name] = positionFromValue(value)
        end
    end
end

local function assignmentDisplay(key)
    if state.capture.active == key then return "MOVE SWITCH..." end

    local assignment = state.switches[key]
    if not assignment then return "TAP TO ASSIGN" end
    if key == "bank" then return assignment.name end
    return assignment.name .. " " .. positionDisplay(assignment.position)
end

local function allSwitchesAssigned()
    return state.switches.atti ~= nil
        and state.switches.bank ~= nil
        and state.switches.hold ~= nil
        and state.switches.reset ~= nil
end

local function receiverIdRequired()
    return receiverIdModels[models[state.model]] == true
end

local function readWholeFile(path)
    if not io or type(io.open) ~= "function" or type(io.read) ~= "function" then
        return nil
    end

    local f = io.open(path, "r")
    if not f then return nil end

    local text = nil
    local stat = type(fstat) == "function" and fstat(path) or nil
    if stat and stat.size and stat.size > 0 then
        text = io.read(f, stat.size)
    else
        local parts = {}
        while true do
            local chunk = io.read(f, 512)
            if not chunk or #chunk == 0 then break end
            parts[#parts + 1] = chunk
        end
        text = table.concat(parts)
    end

    io.close(f)
    return text
end

local function cleanYamlScalar(value)
    if not value then return nil end
    value = string.match(value, "^%s*(.-)%s*$") or value
    value = string.gsub(value, '^"(.*)"$', "%1")
    value = string.gsub(value, "^'(.*)'$", "%1")
    return value
end

-- Parse only the two YAML structures EdgeTX uses for Receiver-ID uniqueness:
-- header.modelId[0].val and moduleData[0].{type,subType}.
local function scanRfIdentityFromFile(path)
    local text = readWholeFile(path)
    if not text then return false, nil end

    local result = {
        modelId = nil,
        rfType = nil,
        rfSubType = TARGET_RF_SUBTYPE,
    }

    local section = nil
    local sectionIndent = -1
    local inSlot = false
    local slotIndent = -1

    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
        line = string.gsub(line, "\r$", "")
        local indentText, body = string.match(line, "^(%s*)(.*)$")
        indentText = indentText or ""
        body = body or ""
        local indent = #indentText
        local trimmed = string.match(body, "^%s*(.-)%s*$") or body

        if trimmed ~= "" then
            if section and indent <= sectionIndent then
                section = nil
                inSlot = false
            elseif section and inSlot and indent <= slotIndent then
                inSlot = false
            end

            if not section then
                if trimmed == "modelId:" then
                    section = "modelId"
                    sectionIndent = indent
                    inSlot = false
                elseif trimmed == "moduleData:" then
                    section = "moduleData"
                    sectionIndent = indent
                    inSlot = false
                end
            elseif not inSlot then
                local slot = string.match(trimmed, "^(%d+):$")
                if slot and indent > sectionIndent and tonumber(slot) == TARGET_MODULE_INDEX then
                    inSlot = true
                    slotIndent = indent
                end
            elseif section == "modelId" then
                local value = string.match(trimmed, "^val:%s*(%d+)")
                if value then
                    local id = tonumber(value)
                    if id and id >= 0 and id <= MAX_RECEIVER_ID then
                        result.modelId = id
                    end
                end
            elseif section == "moduleData" then
                local rfType = string.match(trimmed, "^type:%s*(.-)%s*$")
                if rfType then
                    result.rfType = cleanYamlScalar(rfType)
                end
                local rfSubType = string.match(trimmed, "^subType:%s*(.-)%s*$")
                if rfSubType then
                    result.rfSubType = cleanYamlScalar(rfSubType) or TARGET_RF_SUBTYPE
                end
            end
        end
    end

    return true, result
end

local function sameRfIdentity(identity)
    if not identity then return false end
    if identity.rfType ~= TARGET_RF_TYPE then return false end
    return tostring(identity.rfSubType or TARGET_RF_SUBTYPE) == TARGET_RF_SUBTYPE
end

local function allocateReceiverId()
    state.receiver.id = nil
    state.receiver.scannedModels = 0
    state.receiver.matchingModels = 0
    state.receiver.usedIds = 0

    if type(dir) ~= "function" then
        state.receiver.status = "scan-error"
        return
    end

    local currentFilename = ""
    if model and type(model.getInfo) == "function" then
        local info = model.getInfo()
        if info and type(info.filename) == "string" then
            currentFilename = string.match(info.filename, "([^/\\]+)$") or info.filename
        end
    end

    local used = {}
    local scanOk = true

    -- Use the explicit iterator pattern used by EdgeTX's own SD-card Lua.
    local nextFile = dir(MODELS_DIR)
    if type(nextFile) ~= "function" then
        state.receiver.status = "scan-error"
        return
    end

    local filename = nextFile()
    while filename do
        if type(filename) == "string"
            and string.match(string.lower(filename), "%.yml$")
            and filename ~= currentFilename then
            local ok, identity = scanRfIdentityFromFile(MODELS_DIR .. "/" .. filename)
            if ok then
                state.receiver.scannedModels = state.receiver.scannedModels + 1
                if sameRfIdentity(identity) then
                    state.receiver.matchingModels = state.receiver.matchingModels + 1
                    if identity.modelId ~= nil then
                        used[identity.modelId] = true
                    end
                end
            else
                scanOk = false
            end
        end
        filename = nextFile()
    end

    if not scanOk then
        state.receiver.status = "scan-error"
        return
    end

    for id = 0, MAX_RECEIVER_ID do
        if used[id] then state.receiver.usedIds = state.receiver.usedIds + 1 end
    end

    for id = 0, MAX_RECEIVER_ID do
        if not used[id] then
            state.receiver.id = id
            state.receiver.status = "ok"
            return
        end
    end

    state.receiver.status = "full"
end

local function receiverIdDisplay()
    if not receiverIdRequired() then return "N/A" end
    if state.receiver.status == "ok" and state.receiver.id ~= nil then
        return tostring(state.receiver.id) .. " AUTO"
    end
    if state.receiver.status == "full" then return "NONE FREE" end
    return "SCAN ERROR"
end

local function receiverIdReady()
    return (not receiverIdRequired())
        or (state.receiver.status == "ok" and state.receiver.id ~= nil)
end

local function selectPage(step)
    local target = page + step
    if target < 1 or target > #pages then return end
    state.capture.active = nil
    resetCaptureCandidate()
    page = target
    pages[page]()
end

local function modelPage()
    lvgl.clear()
    local colors = currentColors()

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Model Setup",
        hasPrevious = false,
        hasNext = true,
        nextLabel = "NEXT  >",
        nextFunc = function() selectPage(1) end,
        children1 = {
            choiceRow("Goosky model", models,
                function() return state.model end,
                function(value)
                    if state.model ~= value then
                        state.model = value
                        state.color = 1
                        modelPage()
                    end
                end),
            choiceRow("Color", colors,
                function() return state.color end,
                function(value) state.color = value end),
            choiceRow("Flight timer", timers,
                function() return state.timer end,
                function(value) state.timer = value end),
        },
        children2 = {
            label("Select the helicopter, color and flight timer."),
            label("Switches are assigned on the next page."),
            label("No model programming occurs in this test build."),
        },
    }))
end

local function switchCaptureRow(row)
    local metrics = wizard.metrics()
    local rowH = metrics.large and 58 or 42
    local captureH = metrics.large and 50 or 36
    local captureW = math.floor(LCD_W * (metrics.large and 0.60 or 0.62))
    local active = state.capture.active == row.key

    return {
        type = "rectangle",
        w = lvgl.PERCENT_SIZE + 100,
        h = rowH,
        thickness = 0,
        flexPad = 0,
        flexFlow = lvgl.FLOW_ROW,
        align = LEFT | VCENTER,
        children = {
            {
                type = "rectangle",
                w = lvgl.PERCENT_SIZE + 34,
                h = rowH,
                thickness = 0,
                align = LEFT | VCENTER,
                children = {
                    {
                        type = "label",
                        x = metrics.large and 18 or 10,
                        w = lvgl.PERCENT_SIZE + 92,
                        color = wizard.textColor(),
                        text = row.label,
                    },
                },
            },
            {
                type = "rectangle",
                w = lvgl.PERCENT_SIZE + 66,
                h = rowH,
                thickness = 0,
                align = LEFT | VCENTER,
                children = {
                    {
                        type = "button",
                        x = 0,
                        y = math.floor((rowH - captureH) / 2),
                        w = captureW,
                        h = captureH,
                        text = assignmentDisplay(row.key),
                        color = active and ORANGE or DARKGREY,
                        textColor = active and BLACK or WHITE,
                        cornerRadius = metrics.large and 12 or 8,
                        press = function()
                            state.capture.active = row.key
                            snapshotSwitches()
                            switchPage()
                        end,
                    },
                },
            },
        },
    }
end

function switchPage()
    lvgl.clear()

    local children = {}
    for _, row in ipairs(switchRows) do
        children[#children + 1] = switchCaptureRow(row)
    end
    children[#children + 1] = label("Tap a box, move the switch, then let it settle.")

    lvgl.build(wizard.fullPage({
        title = TITLE,
        subtitle = "Switch Assignment",
        hasPrevious = true,
        hasNext = allSwitchesAssigned() and state.capture.active == nil,
        previousLabel = "<  BACK",
        nextLabel = "NEXT  >",
        previousFunc = function() selectPage(-1) end,
        nextFunc = function() selectPage(1) end,
        children = children,
    }))
end

local function finishSwitchCapture(position)
    local key = state.capture.active
    local name = state.capture.candidateName
    if not key or not name or not position then return end

    state.switches[key] = {
        name = name,
        position = position,
    }
    state.capture.active = nil
    resetCaptureCandidate()
    switchPage()
end

local function captureMovedSwitch()
    local key = state.capture.active
    if not key then return end

    local now = type(getTime) == "function" and getTime() or 0

    -- First detect which physical switch started moving. Once chosen, ignore
    -- every other switch until this assignment completes.
    if not state.capture.candidateName then
        for _, name in ipairs(state.capture.sources) do
            local current = readPhysicalSwitch(name)
            local initialPosition = state.capture.initial[name]
            if current ~= nil and initialPosition ~= nil then
                local currentPosition = positionFromValue(current)
                if currentPosition ~= initialPosition then
                    state.capture.candidateName = name
                    state.capture.candidatePosition = currentPosition
                    state.capture.candidateSince = now
                    state.capture.lastNonInitial = currentPosition
                    state.capture.returnedToInitial = false
                    break
                end
            end
        end
        return
    end

    local name = state.capture.candidateName
    local current = readPhysicalSwitch(name)
    if current == nil then return end

    local currentPosition = positionFromValue(current)
    local initialPosition = state.capture.initial[name]

    if currentPosition ~= state.capture.candidatePosition then
        state.capture.candidatePosition = currentPosition
        state.capture.candidateSince = now

        if currentPosition == initialPosition and state.capture.lastNonInitial ~= nil then
            -- Spring-return/momentary switch: remember the actuated position
            -- and wait briefly after return before accepting it.
            state.capture.returnedToInitial = true
        else
            state.capture.returnedToInitial = false
            if currentPosition ~= initialPosition then
                state.capture.lastNonInitial = currentPosition
            end
        end
        return
    end

    local stableTicks = now - state.capture.candidateSince
    if state.capture.returnedToInitial then
        if stableTicks >= MOMENTARY_RETURN_TICKS then
            finishSwitchCapture(state.capture.lastNonInitial)
        end
    elseif stableTicks >= SWITCH_SETTLE_TICKS then
        finishSwitchCapture(currentPosition)
    end
end

local function reviewPage()
    lvgl.clear()
    local colors = currentColors()

    allocateReceiverId()

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Review / Confirm",
        hasPrevious = true,
        hasNext = receiverIdReady(),
        previousLabel = "<  BACK",
        nextLabel = "CONFIRM",
        previousFunc = function() selectPage(-1) end,
        nextFunc = function() selectPage(1) end,
        children1 = {
            wizard.summaryLine("Model", nil, models[state.model]),
            wizard.summaryLine("Color", nil, colors[state.color]),
            wizard.summaryLine("Receiver ID", nil, receiverIdDisplay()),
            wizard.summaryLine("Timer", nil, timers[state.timer]),
            wizard.summaryLine("ATTI", nil, assignmentDisplay("atti")),
            wizard.summaryLine("BANK", nil, assignmentDisplay("bank")),
            wizard.summaryLine("HOLD", nil, assignmentDisplay("hold")),
            wizard.summaryLine("RESET", nil, assignmentDisplay("reset")),
        },
        children2 = previewChildren(true),
    }))
end

local function completePage()
    lvgl.clear()
    local colors = currentColors()

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Confirmed",
        hasPrevious = true,
        hasNext = false,
        previousLabel = "<  BACK",
        previousFunc = function() selectPage(-1) end,
        children1 = {
            wizard.summaryLine("Model", nil, models[state.model]),
            wizard.summaryLine("Color", nil, colors[state.color]),
            wizard.summaryLine("Receiver ID", nil, receiverIdDisplay()),
            wizard.summaryLine("ATTI", nil, assignmentDisplay("atti")),
            wizard.summaryLine("BANK", nil, assignmentDisplay("bank")),
            wizard.summaryLine("HOLD", nil, assignmentDisplay("hold")),
            wizard.summaryLine("RESET", nil, assignmentDisplay("reset")),
            label("Diagnostic build only. Hold [RTN] to exit."),
        },
        children2 = previewChildren(true),
    }))
end

local function init()
    buildSwitchSources()
    allocateReceiverId()
    pages = { modelPage, switchPage, reviewPage, completePage }
    page = 1
    pages[page]()
end

local function run(event, touchState)
    if page == 2 and state.capture.active ~= nil then
        captureMovedSwitch()
    end

    if event == EVT_VIRTUAL_PREV_PAGE and page > 1 then
        killEvents(event)
        selectPage(-1)
    elseif event == EVT_VIRTUAL_NEXT_PAGE and page < #pages then
        if page ~= 2 or allSwitchesAssigned() then
            killEvents(event)
            selectPage(1)
        end
    end

    if wizard.exitWizard() then return 2 end
    return 0
end

return {
    init = init,
    run = run,
}

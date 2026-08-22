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
local page = 1
local pages = {}

local models = { "S1 V1", "S1 V2", "S2 Legend V1", "S2 MAX", "RS4 Venom" }
local standardColors = { "Orange", "Blue", "Purple" }
local rs4VenomColors = { "Orange", "Green" }
local timers = { "3:00", "3:30", "4:00", "4:30", "5:00", "5:30", "6:00" }

-- Receiver ID is currently applicable only to the two verified native
-- CRSF/ELRS profiles. The remaining aircraft stay selectable for UI testing,
-- but their backend profiles are intentionally not enabled yet.
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
    },
    receiver = {
        id = nil,
        status = "not-scanned",
        scannedModels = 0,
    },
}

local switchRows = {
    { key = "atti",  label = "ATTI" },
    { key = "bank",  label = "BANK" },
    { key = "hold",  label = "THROTTLE HOLD" },
    { key = "reset", label = "TIMER RESET" },
}

local function currentColors()
    if models[state.model] == "RS4 Venom" then
        return rs4VenomColors
    end
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
    local colors = currentColors()
    local code = colorCode(colors[state.color])
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

local function previewChildren()
    local path = previewImagePath()
    if path then
        return {
            wizard.image({
                file = path,
                visibleFunc = function() return true end,
            }),
        }
    end

    return {
        label("Model preview"),
        label("Matching image not installed yet."),
    }
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
    for _, name in ipairs(state.capture.sources) do
        state.capture.snapshot[name] = readPhysicalSwitch(name)
    end
end

local function assignmentDisplay(key)
    if state.capture.active == key then
        return "MOVE SWITCH..."
    end

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

-- EdgeTX 2.12 stores receiver numbers under:
-- header:
--   modelId:
--     0:
--       val: <id>
--     1:
--       val: <id>
-- Scan only that YAML block so unrelated "val" fields are ignored.
local function scanModelIdsFromFile(path, used)
    if not io or type(io.open) ~= "function" or type(io.read) ~= "function" then
        return false
    end

    local f = io.open(path, "r")
    if not f then return false end

    local buffer = ""
    local inModelId = false
    local modelIdIndent = 0

    local function processLine(line)
        line = string.gsub(line, "\r$", "")
        local indentText, body = string.match(line, "^(%s*)(.*)$")
        indentText = indentText or ""
        body = body or ""
        local indent = #indentText
        local trimmed = string.match(body, "^%s*(.-)%s*$") or body

        if inModelId then
            if trimmed ~= "" and indent <= modelIdIndent then
                inModelId = false
            else
                local value = string.match(trimmed, "^val:%s*(%d+)")
                if value then
                    local id = tonumber(value)
                    if id and id >= 0 and id <= MAX_RECEIVER_ID then
                        used[id] = true
                    end
                end
            end
        end

        if not inModelId and trimmed == "modelId:" then
            inModelId = true
            modelIdIndent = indent
        end
    end

    while true do
        local chunk = io.read(f, 512)
        if not chunk or #chunk == 0 then break end
        buffer = buffer .. chunk

        while true do
            local pos = string.find(buffer, "\n", 1, true)
            if not pos then break end
            processLine(string.sub(buffer, 1, pos - 1))
            buffer = string.sub(buffer, pos + 1)
        end
    end

    if #buffer > 0 then processLine(buffer) end
    io.close(f)
    return true
end

local function allocateReceiverId()
    state.receiver.id = nil
    state.receiver.scannedModels = 0

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

    for filename in dir(MODELS_DIR) do
        if type(filename) == "string"
            and string.match(string.lower(filename), "%.yml$")
            and filename ~= currentFilename then
            local ok = scanModelIdsFromFile(MODELS_DIR .. "/" .. filename, used)
            if ok then
                state.receiver.scannedModels = state.receiver.scannedModels + 1
            else
                scanOk = false
            end
        end
    end

    if not scanOk then
        state.receiver.status = "scan-error"
        return
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

    local buttonColor = active and ORANGE or DARKGREY
    local buttonTextColor = active and BLACK or WHITE

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
                        color = buttonColor,
                        textColor = buttonTextColor,
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
    children[#children + 1] = label("Tap a box, then move only the switch you want to assign.")

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

local function captureMovedSwitch()
    local key = state.capture.active
    if not key then return end

    local capturedName = nil
    local capturedValue = nil

    for _, name in ipairs(state.capture.sources) do
        local current = readPhysicalSwitch(name)
        local previous = state.capture.snapshot[name]

        if capturedName == nil
            and current ~= nil
            and previous ~= nil
            and math.abs(current - previous) > 256 then
            capturedName = name
            capturedValue = current
        end

        state.capture.snapshot[name] = current
    end

    if not capturedName then return end

    state.switches[key] = {
        name = capturedName,
        position = positionFromValue(capturedValue),
    }

    state.capture.active = nil
    switchPage()
end

local function reviewPage()
    lvgl.clear()
    local colors = currentColors()

    -- Re-scan immediately before Review so the displayed ID reflects the SD
    -- card state at the point the user is about to confirm.
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
        children2 = previewChildren(),
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
            label("Receiver ID + switch flow confirmed. Hold [RTN] to exit."),
        },
        children2 = previewChildren(),
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

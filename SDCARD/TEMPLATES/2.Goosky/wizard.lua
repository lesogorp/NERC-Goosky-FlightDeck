-- NERC Goosky BNF Wizard v1 - EdgeTX 2.12 color radios
-- Phase 1: native EdgeTX LVGL wizard shell and selection flow.
--
-- IMPORTANT:
--   * This file intentionally contains NO ELRS check/fix logic.
--   * The existing GooskySetup.lua remains unchanged on this branch.
--   * Model writes are intentionally not enabled yet for profiles whose
--     throttle defaults have not been verified.
--
-- The wizard uses EdgeTX's stock wizard UI helper shipped with the 2.12 SD
-- card so the look/navigation matches the built-in Model Wizard.

local STOCK_WIZARD_DIR = "/TEMPLATES/1.Wizard/lib"
local wizard = loadScript(STOCK_WIZARD_DIR .. "/wizard-ui.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local page = 1
local pages = {}

local models = {
    { name = "S1 V1", telemetry = false, rf = "SBUS", profileReady = false },
    { name = "S1 V2", telemetry = true,  rf = "CRSF / ELRS", profileReady = true },
    { name = "S2 Legend V1", telemetry = false, rf = "SBUS / CRSF (FW)", profileReady = false },
    { name = "S2 MAX", telemetry = true, rf = "CRSF / ELRS", profileReady = true },
    { name = "RS4 Venom", telemetry = false, rf = "SBUS", profileReady = false },
}

local colors = { "Orange", "Blue", "Purple" }
local switchNames = { "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH" }
local switchPositions = {}
for _, name in ipairs(switchNames) do
    switchPositions[#switchPositions + 1] = name .. " UP"
    switchPositions[#switchPositions + 1] = name .. " MID"
    switchPositions[#switchPositions + 1] = name .. " DOWN"
end

local timerValues = {}
for seconds = 30, 1200, 30 do
    local minutes = math.floor(seconds / 60)
    local remain = seconds % 60
    timerValues[#timerValues + 1] = string.format("%d:%02d", minutes, remain)
end

local fields = {
    model = 2,
    color = 1,
    timer = 10,
    att = 1,
    bank = 1,
    hold = 16,
    reset = 7,
}

local function selectedModel()
    return models[fields.model]
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
    for _, item in ipairs(models) do modelNames[#modelNames + 1] = item.name end

    local children1 = {
        choiceRow("Goosky model", modelNames,
            function() return fields.model end,
            function(value) fields.model = value end),
        choiceRow("Color", colors,
            function() return fields.color end,
            function(value) fields.color = value end),
        choiceRow("Timer 1 limit", timerValues,
            function() return fields.timer end,
            function(value) fields.timer = value end),
    }

    local children2 = {
        textBlock("All five models use the same Goosky CH1-CH6 control layout."),
        textBlock("ELRS validation/repair is intentionally outside this initial wizard port."),
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
        textBlock("Phase 1 uses standard wizard choices."),
        textBlock("The current GooskySetup switch-movement auto-detection will be ported after the native wizard shell is validated."),
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
        wizard.summaryLine("Color", nil, colors[fields.color]),
        wizard.summaryLine("RF interface", nil, selected.rf),
        wizard.summaryLine("Telemetry", nil, selected.telemetry and "Supported" or "Not available"),
        wizard.summaryLine("ATT", nil, switchPositions[fields.att]),
        wizard.summaryLine("BANK", nil, switchNames[fields.bank]),
        wizard.summaryLine("HOLD", nil, switchPositions[fields.hold]),
        wizard.summaryLine("RESET", nil, switchPositions[fields.reset]),
        wizard.summaryLine("Timer", nil, timerValues[fields.timer]),
    }

    local status
    if selected.profileReady then
        status = "S1 V2 / S2 MAX use the existing proven GooskySetup model profile. Model-write port is the next step."
    else
        status = "Channel layout is known, but throttle defaults are not yet verified. This branch will not guess them."
    end

    local children2 = {
        textBlock("Review only - no model changes are written in this first native-wizard test build."),
        textBlock(status),
        textBlock("MOTOR MUST BE DISCONNECTED before any later build is allowed to apply model changes."),
    }

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

local function finishedPage()
    lvgl.clear()

    local selected = selectedModel()
    local children1 = {
        textBlock("Native EdgeTX wizard flow loaded successfully."),
        textBlock("Selected model: " .. selected.name),
        textBlock("The current model has NOT been modified."),
    }

    local children2 = {
        textBlock("Next port step:"),
        textBlock("1. Move proven apply_model() backend into this wizard."),
        textBlock("2. Restore switch-movement capture."),
        textBlock("3. Keep ELRS check/fix outside v1."),
    }

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Phase 1 Complete",
        hasPrevious = true,
        hasNext = false,
        previousFunc = function() selectPage(-1) end,
        children1 = children1,
        children2 = children2,
    }))
end

local function init()
    pages = {
        modelPage,
        switchesPage,
        summaryPage,
        finishedPage,
    }
    page = 1
    pages[page]()
end

local function run(event, touchState)
    if event == EVT_VIRTUAL_PREV_PAGE and page > 1 then
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

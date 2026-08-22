-- NERC Goosky BNF Wizard v1 bootstrap test
-- EdgeTX 2.12 color radios
-- Self-contained UI dependency. No ELRS check/fix. No model writes in this diagnostic build.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local IMAGE_DIR = "/IMAGES/"
local wizard = loadScript(RUN_DIR .. "/wizard-ui.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local page = 1
local pages = {}

local models = { "S1 V1", "S1 V2", "S2 Legend V1", "S2 MAX", "RS4 Venom" }
local standardColors = { "Orange", "Blue", "Purple" }
local rs4VenomColors = { "Orange", "Green" }
local timers = { "3:00", "3:30", "4:00", "4:30", "5:00", "5:30", "6:00" }

local state = {
    model = 2,
    color = 1,
    timer = 5,
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

    -- Only use verified matching assets. Do not show a different helicopter
    -- as a placeholder for an unfinished aircraft profile.
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

local function selectPage(step)
    local target = page + step
    if target < 1 or target > #pages then return end
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
                        -- Color options are model-specific. Start at the first
                        -- valid color whenever the aircraft is changed.
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
            label("Wizard loaded successfully."),
            label("This diagnostic build does not modify the model."),
            label("ELRS check/fix is intentionally excluded."),
        },
    }))
end

local function reviewPage()
    lvgl.clear()

    local colors = currentColors()

    lvgl.build(wizard.page({
        title = TITLE,
        subtitle = "Review / Confirm",
        hasPrevious = true,
        hasNext = true,
        previousLabel = "<  BACK",
        nextLabel = "CONFIRM",
        previousFunc = function() selectPage(-1) end,
        nextFunc = function() selectPage(1) end,
        children1 = {
            wizard.summaryLine("Model", nil, models[state.model]),
            wizard.summaryLine("Color", nil, colors[state.color]),
            wizard.summaryLine("Timer", nil, timers[state.timer]),
            label("Verify the model image before confirming."),
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
            wizard.summaryLine("Timer", nil, timers[state.timer]),
            label("Wizard flow confirmed successfully."),
            label("Diagnostic build only: model programming is still disabled."),
            label("Hold [RTN] to exit."),
        },
        children2 = previewChildren(),
    }))
end

local function init()
    pages = { modelPage, reviewPage, completePage }
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

    if wizard.exitWizard() then return 2 end
    return 0
end

return {
    init = init,
    run = run,
}

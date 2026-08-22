-- NERC Goosky BNF Wizard - bootstrap diagnostic
-- EdgeTX 2.12 color radios
-- This file intentionally has NO external Lua dependencies.
-- If this page appears, EdgeTX is successfully launching the template Lua.

local function init()
    lvgl.clear()

    lvgl.build({
        {
            type = "page",
            title = "NERC Goosky BNF Wizard",
            subtitle = "Bootstrap Test",
            backButton = true,
            children = {
                {
                    type = "rectangle",
                    w = lvgl.PERCENT_SIZE + 100,
                    h = lvgl.PERCENT_SIZE + 100,
                    flexFlow = lvgl.FLOW_COLUMN,
                    align = CENTER | VCENTER,
                    children = {
                        {
                            type = "label",
                            text = "GOOSKY WIZARD LUA LOADED",
                            color = COLOR_THEME_PRIMARY1,
                        },
                        {
                            type = "label",
                            text = "Template -> YAML -> Lua launch is working.",
                        },
                        {
                            type = "label",
                            text = "No model changes are made by this test.",
                        },
                        {
                            type = "label",
                            text = "Hold RTN to exit.",
                        },
                    },
                },
            },
        },
    })
end

local function run(event, touchState)
    return 0
end

return {
    init = init,
    run = run,
    useLvgl = true,
}

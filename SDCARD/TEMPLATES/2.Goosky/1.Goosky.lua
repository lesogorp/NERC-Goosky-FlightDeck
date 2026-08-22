-- NERC Goosky BNF Wizard v1 entry point for EdgeTX 2.12 color radios.
-- Initial port intentionally excludes ELRS check/fix logic.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local wizard = loadScript(RUN_DIR .. "/wizard-v2.lua")()

return {
    init = wizard.init,
    run = wizard.run,
    useLvgl = true,
}

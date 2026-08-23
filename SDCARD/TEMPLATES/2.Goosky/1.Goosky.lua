-- NERC Goosky BNF Wizard v1 entry point for EdgeTX 2.12 color radios.
-- Adds transaction handling around the production wizard implementation.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local wizard = loadScript(RUN_DIR .. "/wizard.lua")()
local tx = loadScript(RUN_DIR .. "/wizard-transaction.lua")()

local function init()
    if tx and type(tx.begin) == "function" then pcall(tx.begin) end
    wizard.init()
end

local function run(event, touchState)
    local result = wizard.run(event, touchState)
    if result ~= 0 then
        -- Successful programming commits inside wizard-apply.lua immediately.
        -- Any normal wizard exit before that point is an abort and must leave
        -- the generated model RF-safe and marked for later deletion.
        if tx and type(tx.rollback) == "function" then
            local info = model and model.getInfo and model.getInfo() or nil
            local name = type(info) == "table" and tostring(info.name or "") or ""
            local committed = string.match(name, "^S1 V2 ") or string.match(name, "^S2 MAX ")
            if not committed then pcall(tx.rollback, "wizard-aborted") end
        end
    end
    return result
end

return {
    init = init,
    run = run,
    useLvgl = true,
}

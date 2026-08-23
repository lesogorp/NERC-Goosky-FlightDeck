-- NERC Goosky BNF Wizard transactional apply wrapper.
-- Keeps the hardware-validated programming backend isolated while ensuring a
-- failed apply is immediately made RF-safe and a successful apply is committed.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local coreLoader = loadScript(RUN_DIR .. "/wizard-apply-core.lua")
local txLoader = loadScript(RUN_DIR .. "/wizard-transaction.lua")

if type(coreLoader) ~= "function" then error("Cannot load wizard apply core") end
if type(txLoader) ~= "function" then error("Cannot load wizard transaction helper") end

local core = coreLoader()
local tx = txLoader()
if type(core) ~= "function" then error("Invalid wizard apply core") end
if type(tx) ~= "table" then error("Invalid wizard transaction helper") end

return function(payload)
    local ok, result = pcall(core, payload)
    if not ok then
        if type(tx.rollback) == "function" then pcall(tx.rollback, "programming-failed") end
        error(tostring(result or "Unknown model programming error"))
    end

    if type(tx.commit) == "function" then tx.commit() end
    return result
end

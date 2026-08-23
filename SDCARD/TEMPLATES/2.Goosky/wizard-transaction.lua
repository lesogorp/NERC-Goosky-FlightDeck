-- NERC Goosky model-wizard transaction helper.
-- EdgeTX cannot safely delete the currently-active model from a standalone Lua
-- wizard, so cancelled/failed models are made RF-safe and marked for deletion.
-- A later wizard launch removes the previously-marked model once it is no
-- longer the active model. Successful programming clears the marker at once.

local TXN_FILE = "/SCRIPTS/TOOLS/NERC_GSkyFD_wizard_txn.cfg"
local MODELS_DIR = "/MODELS/"
local AUTO_CFG_PREFIX = "/SCRIPTS/TOOLS/NERC_GSkyFD_"
local LEGACY_AUTO_CFG_PREFIX = "/WIDGETS/NERC_GSkyFD/auto_"

local tx = {}

local function clean(value)
    return string.gsub(tostring(value or ""), "[\r\n]", "")
end

local function basename(value)
    local name = string.match(clean(value), "([^/\\]+)$") or clean(value)
    if not string.match(string.lower(name), "%.yml$") then return nil end
    if string.find(name, "%.%.", 1, true) then return nil end
    return name
end

local function configKey(info)
    local raw = type(info) == "table" and (info.filename or info.name) or "model"
    local key = string.lower(clean(raw))
    key = string.gsub(key, "[^%w_-]", "_")
    if key == "" then key = "model" end
    return key
end

local function unlink(path)
    if type(del) ~= "function" then return false end
    local ok, result = pcall(del, path)
    return ok and (result == 0 or result == 4 or result == 5)
end

local function readMarker()
    if not io or type(io.open) ~= "function" or type(io.read) ~= "function" then return nil end
    local f = io.open(TXN_FILE, "r")
    if not f then return nil end
    local content = ""
    while true do
        local chunk = io.read(f, 128)
        if not chunk or #chunk == 0 then break end
        content = content .. chunk
        if #content > 512 then break end
    end
    io.close(f)
    return basename(string.match(content, "filename=([^\r\n]+)"))
end

local function writeMarker(filename, reason)
    if not io or type(io.open) ~= "function" then return false end
    filename = basename(filename)
    if not filename then return false end
    local f = io.open(TXN_FILE, "w")
    if not f then return false end
    io.write(f, "version=1\n")
    io.write(f, "filename=" .. filename .. "\n")
    io.write(f, "reason=" .. clean(reason or "wizard-active") .. "\n")
    io.close(f)
    return true
end

local function currentInfo()
    if not model or type(model.getInfo) ~= "function" then return nil end
    local info = model.getInfo()
    if type(info) ~= "table" then return nil end
    return info
end

local function removeDashboardFiles(info)
    if type(info) ~= "table" then return end
    local fileKey = configKey(info)
    local nameKey = configKey({ name = info.name })
    unlink(AUTO_CFG_PREFIX .. fileKey .. ".cfg")
    unlink(LEGACY_AUTO_CFG_PREFIX .. fileKey .. ".cfg")
    if nameKey ~= fileKey then
        unlink(AUTO_CFG_PREFIX .. nameKey .. ".cfg")
        unlink(LEGACY_AUTO_CFG_PREFIX .. nameKey .. ".cfg")
    end
end

local function makeRfSafe()
    if not model then return end

    -- RF off first. This is the most important rollback action if programming
    -- failed after mixes/custom functions had already been written.
    if type(model.setModule) == "function" then
        pcall(model.setModule, 0, { Type = 0 })
        if type(model.getModule) == "function" then
            local ok, ext = pcall(model.getModule, 1)
            if ok and ext ~= nil then pcall(model.setModule, 1, { Type = 0 }) end
        end
    end

    -- Remove generated mixes and custom functions where the APIs are present.
    if type(model.deleteMixes) == "function" then
        for channel = 0, 31 do pcall(model.deleteMixes, channel) end
    end
    if type(model.setCustomFunction) == "function" then
        for index = 0, 31 do
            pcall(model.setCustomFunction, index, {
                switch = 0, func = 0, param = 0, value = 0, mode = 0, active = 0
            })
        end
    end
    if type(model.defaultInputs) == "function" then pcall(model.defaultInputs) end
end

function tx.begin()
    local info = currentInfo()
    if not info then return false end
    local current = basename(info.filename)
    if not current then return false end

    -- A marker surviving from an earlier forced EXIT identifies an abandoned
    -- wizard model. It can only be deleted here when it is no longer current.
    local previous = readMarker()
    if previous and previous ~= current then
        unlink(MODELS_DIR .. previous)
    end

    return writeMarker(current, "wizard-active")
end

function tx.rollback(reason)
    local info = currentInfo()
    if not info then return false end
    local filename = basename(info.filename)

    removeDashboardFiles(info)
    makeRfSafe()

    -- Keep an unmistakable placeholder instead of a flyable partial model.
    if type(model.setInfo) == "function" then
        local safe = currentInfo() or info
        safe.name = "INCOMPLETE Goosky"
        safe.bitmap = ""
        pcall(model.setInfo, safe)
    end

    if filename then writeMarker(filename, reason or "wizard-aborted") end
    return true
end

function tx.commit()
    unlink(TXN_FILE)
    return true
end

return tx

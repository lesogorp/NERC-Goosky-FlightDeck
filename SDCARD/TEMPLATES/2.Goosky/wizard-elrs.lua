-- NERC Goosky wizard ELRS stage
-- UI adapter around the shared profile-driven NERC_ELRS engine.

local LIB_DIR = "/SCRIPTS/LIB"

local profilesLoader = loadScript(LIB_DIR .. "/NERC_RF_PROFILES.lua")
local elrsLoader = loadScript(LIB_DIR .. "/NERC_ELRS.lua")
if type(profilesLoader) ~= "function" then error("Cannot load NERC_RF_PROFILES.lua") end
if type(elrsLoader) ~= "function" then error("Cannot load NERC_ELRS.lua") end

local profiles = profilesLoader()
local elrsFactory = elrsLoader()
profilesLoader=nil; elrsLoader=nil

local M = {}

function M.new(options)
    options = options or {}
    local wizard = options.wizard
    local title = options.title or "NERC Model Wizard"
    local getModelName = options.getModelName
    local ensureModule = options.ensureModule
    local goBack = options.goBack
    local goNext = options.goNext

    local session = nil
    local profile = nil
    local errorText = nil
    local lastSignature = nil

    local function label(text)
        return {
            type="label",
            w=lvgl.PERCENT_SIZE + 100,
            color=wizard.textColor(),
            font=wizard.metrics().fieldFont,
            text=text,
        }
    end

    local function stateSignature()
        if not session then return "no-session:" .. tostring(errorText or "") end
        local s=session.getState()
        local c=session.getCurrent()
        local fix=s.fix or {}
        return table.concat({
            tostring(s.device_found), tostring(s.scan_complete), tostring(s.transport_error),
            tostring(fix.stage), tostring(fix.message), tostring(c.packetRate),
            tostring(c.switchMode), tostring(c.telemetry), tostring(c.modelMatch),
            tostring(c.maxPower), tostring(c.dynamicPower), tostring(c.antennaMode)
        }, "|")
    end

    local function startSession()
        errorText=nil
        lastSignature=nil
        local modelName = type(getModelName)=="function" and getModelName() or ""
        profile, errorText = profiles.requireForAircraft("Goosky", modelName)
        if not profile then session=nil; return false end
        if type(ensureModule)=="function" then
            local ok, err = pcall(ensureModule)
            if not ok then errorText=tostring(err); session=nil; return false end
        end
        session = elrsFactory.new({ profile=profile })
        if not session.supported() then
            errorText="ELRS CHECK UNAVAILABLE"
            return false
        end
        return true
    end

    local function row(titleText,key)
        local current = session and session.getCurrent() or {}
        local recommended = session and session.getRecommended() or {}
        local currentText = tostring(current[key] or "?")
        local targetText = tostring(recommended[key] or "?")
        return wizard.summaryLine(titleText,nil,currentText .. "  ->  " .. targetText)
    end

    local function statusText()
        if errorText then return errorText end
        if not session then return "ELRS SESSION NOT AVAILABLE" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.transport_error then return s.transport_error end
        if fix.stage=="error" then return fix.message or "ELRS CHANGE FAILED" end
        if fix.stage=="complete" then return "ALL SETTINGS VERIFIED" end
        if fix.stage~="idle" then return fix.message or "APPLYING SETTINGS" end
        if not s.device_found then return "SEARCHING ELRS TX MODULE..." end
        if not s.scan_complete then return "READING ELRS SETTINGS..." end
        if session.fixRequired() then return "SETTINGS MISMATCH - FIX REQUIRED" end
        return "ELRS SETTINGS VERIFIED"
    end

    local function nextLabel()
        if errorText then return "RETRY" end
        if not session then return "RETRY" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.transport_error or fix.stage=="error" then return "RETRY" end
        if fix.stage~="idle" and fix.stage~="complete" then return "WORKING..." end
        if not s.scan_complete then return "SCANNING..." end
        if session.fixRequired() then return "FIX SETTINGS" end
        return "NEXT  >"
    end

    local function nextAction()
        if errorText or not session then
            startSession(); M._render(); return
        end
        local s=session.getState()
        local fix=s.fix or {}
        if s.transport_error or fix.stage=="error" then
            startSession(); M._render(); return
        end
        if fix.stage~="idle" and fix.stage~="complete" then return end
        if not s.scan_complete then return end
        if session.fixRequired() then
            -- The model has not been programmed yet, so the captured HOLD switch
            -- cannot gate motor output here. Receiver-off status is enforced by
            -- the ELRS module status before any TX-side setting is written.
            local ok, err = session.beginFix({ holdOn=true })
            if not ok then errorText=err end
            M._render()
            return
        end
        if type(goNext)=="function" then goNext() end
    end

    function M._render()
        lvgl.clear()
        local current = session and session.getCurrent() or {}
        local children={
            label(profile and profile.label or "ELRS RF Profile"),
            row("Rate","packetRate"),
            row("Channels","switchMode"),
            row("Telemetry","telemetry"),
            row("Model Match","modelMatch"),
            row("Power","maxPower"),
            row("Dynamic","dynamicPower"),
        }
        if current.antennaMode ~= nil and current.antennaMode ~= "?" then
            children[#children+1]=row("Antenna","antennaMode")
        end
        children[#children+1]=label(statusText())
        children[#children+1]=label("Power OFF the helicopter before using FIX SETTINGS.")

        lvgl.build(wizard.fullPage({
            title=title, subtitle="ELRS Settings",
            hasPrevious=true, hasNext=true,
            previousLabel="<  BACK", nextLabel=nextLabel,
            previousFunc=function() if type(goBack)=="function" then goBack() end end,
            nextFunc=nextAction,
            children=children,
        }))
        lastSignature=stateSignature()
    end

    function M.enter()
        startSession()
        M._render()
    end

    function M.update()
        if session then session.update(true) end
        local signature=stateSignature()
        if signature~=lastSignature then M._render() end
    end

    function M.isReady()
        return session and session.scanComplete()
            and not session.getState().transport_error
            and not session.fixRequired()
    end

    function M.getProfileId()
        return profile and profile.id or nil
    end

    function M.reset()
        session=nil; profile=nil; errorText=nil; lastSignature=nil
    end

    return M
end

return M

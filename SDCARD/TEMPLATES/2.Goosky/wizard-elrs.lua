-- NERC Goosky wizard ELRS stage
-- Compact UI adapter around the shared profile-driven NERC_ELRS engine.

local LIB_DIR = "/SCRIPTS/LIB"

local profilesLoader = loadScript(LIB_DIR .. "/NERC_RF_PROFILES.lua")
local elrsLoader = loadScript(LIB_DIR .. "/NERC_ELRS.lua")
if type(profilesLoader) ~= "function" then error("Cannot load NERC_RF_PROFILES.lua") end
if type(elrsLoader) ~= "function" then error("Cannot load NERC_ELRS.lua") end

local profiles = profilesLoader()
local elrsFactory = elrsLoader()
profilesLoader=nil; elrsLoader=nil

-- The VS Code simulator task injects this development-only backend into the
-- simulator SD pack. It is intentionally absent from flight radios, so normal
-- hardware always uses the native EdgeTX CRSF transport.
local simulation=nil
do
    local okLoader,simLoader=pcall(loadScript,"/WIDGETS/NERC_GSkyFD/simulator.lua")
    if okLoader and type(simLoader)=="function" then
        local okSim,sim=pcall(simLoader)
        if okSim and type(sim)=="table" and sim.is_goosky_simulator then simulation=sim end
    end
end

local M = {}

local ROWS = {
    { label="Rate", key="packetRate" },
    { label="Channels", key="switchMode" },
    { label="Telemetry", key="telemetry" },
    { label="Model Match", key="modelMatch" },
    { label="Power", key="maxPower" },
    { label="Dynamic", key="dynamicPower" },
    { label="Antenna", key="antennaMode", optional=true },
}

function M.new(options)
    options = options or {}
    local wizard = options.wizard
    local title = options.title or "NERC Model Wizard"
    local getModelName = options.getModelName
    local ensureModule = options.ensureModule
    local linkConnected = options.linkConnected
    local goBack = options.goBack
    local goNext = options.goNext

    local session=nil
    local profile=nil
    local errorText=nil
    local lastSignature=nil

    local metrics=wizard.metrics()
    local rowH=metrics.large and 30 or 21
    local headH=metrics.large and 26 or 19
    local statusH=metrics.large and 30 or 21
    local xPad=metrics.large and 12 or 7
    local font=metrics.fieldFont

    local function liveLink()
        if type(linkConnected) ~= "function" then return false end
        local ok,value=pcall(linkConnected)
        return ok and (value==true or (type(value)=="number" and value~=0))
    end

    local function stateSignature()
        if not session then return "no-session:" .. tostring(errorText or "") end
        local s=session.getState()
        local c=session.getCurrent()
        local fix=s.fix or {}
        return table.concat({
            tostring(s.device_found), tostring(s.scan_complete), tostring(s.transport_error),
            tostring(s.connected), tostring(s.armed), tostring(liveLink()),
            tostring(fix.stage), tostring(fix.message), tostring(c.packetRate),
            tostring(c.switchMode), tostring(c.telemetry), tostring(c.modelMatch),
            tostring(c.maxPower), tostring(c.dynamicPower), tostring(c.antennaMode)
        }, "|")
    end

    local function startSession()
        errorText=nil
        lastSignature=nil
        if liveLink() then
            errorText="POWER OFF HELICOPTER - TELEMETRY ACTIVE"
            session=nil
            return false
        end
        local modelName=type(getModelName)=="function" and getModelName() or ""
        profile,errorText=profiles.requireForAircraft("Goosky",modelName)
        if not profile then session=nil; return false end
        if type(ensureModule)=="function" then
            local ok,err=pcall(ensureModule)
            if not ok then errorText=tostring(err); session=nil; return false end
        end
        session=elrsFactory.new({ profile=profile, simulation=simulation })
        if not session.supported() then
            errorText="ELRS CHECK UNAVAILABLE"
            return false
        end
        return true
    end

    local function mismatchMap()
        local map={}
        if not session then return map end
        for _,item in ipairs(session.getMismatches() or {}) do map[item.key]=item end
        return map
    end

    local function canonicalCurrent(key,current,target,mismatch)
        if current==nil or current=="?" then return "--" end
        if not mismatch then
            if key=="switchMode" and target=="8ch Full Resolution" then return "8ch Full" end
            return tostring(target or current)
        end
        return tostring(current)
    end

    local function compactTarget(key,target)
        if key=="switchMode" and target=="8ch Full Resolution" then return "8ch Full" end
        return tostring(target or "--")
    end

    local function cell(text,width,color)
        return {
            type="rectangle", w=lvgl.PERCENT_SIZE+width, h=rowH,
            thickness=0, align=LEFT|VCENTER,
            children={{
                type="label", x=xPad, w=lvgl.PERCENT_SIZE+92,
                color=color or wizard.textColor(), font=font,
                text=text,
            }},
        }
    end

    local function statusCell(text,color)
        return {
            type="rectangle", w=lvgl.PERCENT_SIZE+17, h=rowH,
            thickness=0, align=LEFT|VCENTER,
            children={{
                type="label", align=CENTER,
                color=color or wizard.textColor(), font=font,
                text=text,
            }},
        }
    end

    local function tableHeader()
        local function hcell(text,width)
            return {
                type="rectangle", w=lvgl.PERCENT_SIZE+width, h=headH,
                thickness=0, align=LEFT|VCENTER,
                children={{ type="label", x=xPad, w=lvgl.PERCENT_SIZE+92,
                    color=wizard.textColor(), font=font, text=text }},
            }
        end
        local function statusHeader()
            return {
                type="rectangle", w=lvgl.PERCENT_SIZE+17, h=headH,
                thickness=0, align=LEFT|VCENTER,
                children={{ type="label", align=CENTER,
                    color=wizard.textColor(), font=font, text="STATUS" }},
            }
        end
        return {
            type="rectangle", w=lvgl.PERCENT_SIZE+100, h=headH,
            thickness=0, flexPad=0, flexFlow=lvgl.FLOW_ROW, align=LEFT|VCENTER,
            children={
                hcell("SETTING",25), hcell("CURRENT",29), hcell("TARGET",29), statusHeader()
            }
        }
    end

    local function settingRow(def,mismatches)
        local current=session and session.getCurrent() or {}
        local recommended=session and session.getRecommended() or {}
        local currentValue=current[def.key]
        if def.optional and (currentValue==nil or currentValue=="?") then return nil end
        local target=recommended[def.key]
        local mismatch=mismatches[def.key]
        local currentText=canonicalCurrent(def.key,currentValue,target,mismatch)
        local targetText=compactTarget(def.key,target)
        local statusText=mismatch and "FIX" or ((currentValue==nil or currentValue=="?") and "--" or "OK")
        local statusColor=mismatch and ORANGE or wizard.textColor()
        return {
            type="rectangle", w=lvgl.PERCENT_SIZE+100, h=rowH,
            thickness=0, flexPad=0, flexFlow=lvgl.FLOW_ROW, align=LEFT|VCENTER,
            children={
                cell(def.label,25), cell(currentText,29), cell(targetText,29), statusCell(statusText,statusColor)
            }
        }
    end

    local function statusText()
        if liveLink() then return "POWER OFF HELICOPTER - TELEMETRY ACTIVE" end
        if errorText then return errorText end
        if not session then return "ELRS SESSION NOT AVAILABLE" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.armed then return "ELRS REPORTS ARMED - POWER OFF HELICOPTER" end
        if s.connected then return "RECEIVER CONNECTED - POWER OFF HELICOPTER" end
        if s.transport_error then return s.transport_error end
        if fix.stage=="error" then return fix.message or "ELRS CHANGE FAILED" end
        if fix.stage=="complete" then return "ELRS SETTINGS VERIFIED" end
        if fix.stage~="idle" then return fix.message or "APPLYING ELRS SETTINGS" end
        if not s.device_found then return "SEARCHING FOR ELRS MODULE" end
        if not s.scan_complete then return "READING ELRS SETTINGS" end
        local count=#(session.getMismatches() or {})
        if count>0 then
            return tostring(count) .. (count==1 and " SETTING NEEDS CHANGE - RECEIVER OFF" or " SETTINGS NEED CHANGE - RECEIVER OFF")
        end
        return "ELRS PROFILE VERIFIED"
    end

    local function nextLabel()
        if liveLink() then return "POWER OFF" end
        if errorText or not session then return "RETRY" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.connected or s.armed then return "POWER OFF" end
        if s.transport_error or fix.stage=="error" then return "RETRY" end
        if fix.stage~="idle" and fix.stage~="complete" then return "APPLYING" end
        if not s.scan_complete then return "WAIT" end
        if session.fixRequired() then return "FIX" end
        return "NEXT  >"
    end

    local function nextAction()
        if liveLink() then
            errorText="POWER OFF HELICOPTER - TELEMETRY ACTIVE"
            M._render()
            return
        end
        if errorText or not session then startSession(); M._render(); return end
        local s=session.getState()
        local fix=s.fix or {}
        if s.connected or s.armed then
            errorText=s.armed and "ELRS REPORTS ARMED - POWER OFF HELICOPTER"
                or "RECEIVER CONNECTED - POWER OFF HELICOPTER"
            M._render()
            return
        end
        if s.transport_error or fix.stage=="error" then startSession(); M._render(); return end
        if fix.stage~="idle" and fix.stage~="complete" then return end
        if not s.scan_complete then return end
        if session.fixRequired() then
            local ok,err=session.beginFix({ holdOn=true, linkConnected=linkConnected })
            if not ok then errorText=err end
            M._render()
            return
        end
        if type(goNext)=="function" then goNext() end
    end

    function M._render()
        lvgl.clear()
        local mismatches=mismatchMap()
        local children={ tableHeader() }
        for _,def in ipairs(ROWS) do
            local r=settingRow(def,mismatches)
            if r then children[#children+1]=r end
        end
        children[#children+1]={
            type="rectangle", w=lvgl.PERCENT_SIZE+100, h=statusH,
            thickness=0, align=LEFT|VCENTER,
            children={{ type="label", x=xPad, w=lvgl.PERCENT_SIZE+96,
                color=wizard.textColor(), font=font, text=statusText() }},
        }

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

    function M.enter() startSession(); M._render() end
    function M.update()
        local safe=not liveLink()
        if session then session.update(safe) end
        if not safe then errorText="POWER OFF HELICOPTER - TELEMETRY ACTIVE" end
        local signature=stateSignature()
        if signature~=lastSignature then M._render() end
    end
    function M.isReady()
        if liveLink() then return false end
        local s=session and session.getState() or nil
        return session and s and not s.connected and not s.armed
            and session.scanComplete() and not s.transport_error and not session.fixRequired()
    end
    function M.getLedState()
        if liveLink() then return "mismatch" end
        if errorText or not session then return "checking" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.connected or s.armed then return "mismatch" end
        if not s.scan_complete then return "checking" end
        if s.transport_error or fix.stage=="error" or session.fixRequired() then return "mismatch" end
        return "ready"
    end
    function M.getProfileId() return profile and profile.id or nil end
    function M.reset() session=nil; profile=nil; errorText=nil; lastSignature=nil end

    return M
end

return M

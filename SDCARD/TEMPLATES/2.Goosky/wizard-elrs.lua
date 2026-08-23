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
        local modelName=type(getModelName)=="function" and getModelName() or ""
        profile,errorText=profiles.requireForAircraft("Goosky",modelName)
        if not profile then session=nil; return false end
        if type(ensureModule)=="function" then
            local ok,err=pcall(ensureModule)
            if not ok then errorText=tostring(err); session=nil; return false end
        end
        session=elrsFactory.new({ profile=profile })
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
        if errorText then return errorText end
        if not session then return "ELRS SESSION NOT AVAILABLE" end
        local s=session.getState()
        local fix=s.fix or {}
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
        if errorText or not session then return "RETRY" end
        local s=session.getState()
        local fix=s.fix or {}
        if s.transport_error or fix.stage=="error" then return "RETRY" end
        if fix.stage~="idle" and fix.stage~="complete" then return "APPLYING" end
        if not s.scan_complete then return "WAIT" end
        if session.fixRequired() then return "FIX" end
        return "NEXT  >"
    end

    local function nextAction()
        if errorText or not session then startSession(); M._render(); return end
        local s=session.getState()
        local fix=s.fix or {}
        if s.transport_error or fix.stage=="error" then startSession(); M._render(); return end
        if fix.stage~="idle" and fix.stage~="complete" then return end
        if not s.scan_complete then return end
        if session.fixRequired() then
            local ok,err=session.beginFix({ holdOn=true })
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
        if session then session.update(true) end
        local signature=stateSignature()
        if signature~=lastSignature then M._render() end
    end
    function M.isReady()
        return session and session.scanComplete()
            and not session.getState().transport_error
            and not session.fixRequired()
    end
    function M.getProfileId() return profile and profile.id or nil end
    function M.reset() session=nil; profile=nil; errorText=nil; lastSignature=nil end

    return M
end

return M

-- NERC Goosky BNF Wizard v1
-- EdgeTX 2.12 color radios
-- Hardware-validated switch capture, Receiver ID allocation and ELRS preflight.
-- Programs verified S1 V2 / S2 MAX profiles only.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local IMAGE_DIR = "/IMAGES/"
local MODELS_DIR = "/MODELS"
local ELRS_SIM_PATH = "/SCRIPTS/LIB/NERC_ELRS_SIM.lua"
local wizard = loadScript(RUN_DIR .. "/wizard-ui.lua")()
local elrsStageFactory = loadScript(RUN_DIR .. "/wizard-elrs.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local MAX_RECEIVER_ID = 63
local TARGET_MODULE_INDEX = 0
local TARGET_RF_TYPE = "TYPE_CROSSFIRE"
local TARGET_RF_SUBTYPE = "0"
local SWITCH_SETTLE_TICKS = 20
local PROGRAMMING_LED_MIN_TICKS = 80

local page = 1
local pages = {}
local switchPage
local elrsPage
local completePage
local safetyPage
local elrsStage=nil
local wizardLedSignature = nil
local safetyBlocked = false
local telemetrySwitchIndex = nil
local simulatorMode = false

local models = { "S1 V1", "S1 V2", "S2 Legend V1", "S2 MAX", "RS4 Venom" }
local standardColors = { "Orange", "Blue", "Purple" }
local rs4VenomColors = { "Orange", "Green" }
local timers = {}
local timerSeconds = {}
for seconds = 30, 1200, 30 do
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    timers[#timers + 1] = string.format("%d:%02d", m, s)
    timerSeconds[#timerSeconds + 1] = seconds
end

local state = {
    model = 2,
    color = 1,
    timer = 10,
    switches = { atti=nil, bank=nil, hold=nil, reset=nil },
    capture = {
        active=nil,
        sources={},
        snapshot={},
        candidateName=nil,
        candidatePosition=nil,
        candidateInitial=nil,
        candidateSince=0,
    },
    receiver = {
        id=nil,
        status="not-scanned",
        scannedModels=0,
        matchingModels=0,
        usedIds=0,
        maskLo=0,
        maskHi=0,
    },
    apply = { status="not-run", error=nil, startedAt=0 },
}

local switchRows = {
    { key="atti", label="ATTI" },
    { key="bank", label="BANK" },
    { key="hold", label="THROTTLE HOLD" },
    { key="reset", label="TIMER RESET" },
}

local function profileReady()
    local m=models[state.model]
    return m == "S1 V2" or m == "S2 MAX"
end

local function currentColors()
    if models[state.model] == "RS4 Venom" then return rs4VenomColors end
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
    local code = colorCode(currentColors()[state.color])
    local prefix = nil
    if modelName == "S1 V2" then prefix = "GKS1"
    elseif modelName == "S2 MAX" then prefix = "GKS2" end
    if not prefix or not code then return nil end

    local suffix = wizard.isLargeLCD() and "_800.png" or ".png"
    local path = IMAGE_DIR .. prefix .. code .. suffix
    if type(fstat) == "function" and not fstat(path) then return nil end
    return path
end

local function choiceRow(title, values, getter, setter)
    return wizard.settings({
        title=title,
        children={{ type="choice", values=values, get=getter, set=setter }},
    })
end

local function label(text)
    return {
        type="label",
        w=lvgl.PERCENT_SIZE + 100,
        color=wizard.textColor(),
        font=wizard.metrics().fieldFont,
        text=text,
    }
end

local function sideLabel(text)
    local inset=wizard.isLargeLCD() and 14 or 8
    return {
        type="label",
        x=inset,
        w=lvgl.PERCENT_SIZE + 94,
        color=wizard.textColor(),
        font=wizard.metrics().fieldFont,
        text=text,
    }
end

local function detectSimulatorMode()
    if type(fstat) ~= "function" then return false end
    local ok,stat=pcall(fstat,ELRS_SIM_PATH)
    return ok and stat~=nil and stat~=false
end

-- EdgeTX exposes TELE as a native special switch backed by TELEMETRY_STREAMING().
-- This is intentionally the outermost safety gate on flight hardware. In the
-- Companion development simulator, synthetic telemetry can assert TELE even
-- though no helicopter exists, so the injected ELRS simulator marker disables
-- this native TELE gate. ELRS connected/armed safety remains independently
-- enforced by the dedicated simulated ELRS status frames.
local function telemetryLinkActive()
    if simulatorMode then return false end
    if type(getSwitchIndex) ~= "function" or type(getSwitchValue) ~= "function" then
        return false
    end
    if telemetrySwitchIndex == nil then
        telemetrySwitchIndex = 0
        for _,name in ipairs({ "TELE", "Telemetry", "TELEM" }) do
            local ok,index=pcall(getSwitchIndex,name)
            if ok and index and index~=0 then telemetrySwitchIndex=index; break end
        end
    end
    if not telemetrySwitchIndex or telemetrySwitchIndex==0 then return false end
    local ok,value=pcall(getSwitchValue,telemetrySwitchIndex)
    if not ok then return false end
    return value==true or (type(value)=="number" and value~=0)
end

local function previewChildren()
    local path = previewImagePath()
    if path then
        return { wizard.image({ file=path, visibleFunc=function() return true end }) }
    end
    return { sideLabel("Model preview"), sideLabel("Matching image not installed yet.") }
end

local function sourceExists(name)
    if type(getFieldInfo) ~= "function" then return false end
    local info = getFieldInfo(string.lower(name))
    return info and info.id ~= nil
end

local function readPhysicalSwitch(name)
    if type(getValue) ~= "function" then return nil end
    local value = getValue(string.lower(name))
    if type(value) ~= "number" then return nil end
    return value
end

local function positionFromValue(value)
    if value < -512 then return "up" end
    if value > 512 then return "down" end
    return "mid"
end

local function positionDisplay(position)
    if position == "up" then return "UP" end
    if position == "down" then return "DOWN" end
    return "MID"
end

local function resetCaptureCandidate()
    local c = state.capture
    c.candidateName=nil
    c.candidatePosition=nil
    c.candidateInitial=nil
    c.candidateSince=0
end

local function buildSwitchSources()
    local sources = state.capture.sources
    for i=#sources,1,-1 do sources[i]=nil end
    local names = {"SA","SB","SC","SD","SE","SF","SG","SH","SI","SJ"}
    for i=1,#names do
        if sourceExists(names[i]) then sources[#sources+1]=names[i] end
    end
    if #sources == 0 then
        sources[1]="SA"; sources[2]="SB"; sources[3]="SC"; sources[4]="SD"
        sources[5]="SE"; sources[6]="SF"; sources[7]="SG"; sources[8]="SH"
    end
end

local function snapshotSwitches()
    local snap = state.capture.snapshot
    for k in pairs(snap) do snap[k]=nil end
    resetCaptureCandidate()
    for i=1,#state.capture.sources do
        local name = state.capture.sources[i]
        snap[name] = readPhysicalSwitch(name)
    end
end

local function assignmentDisplay(key)
    if state.capture.active == key then return "MOVE SWITCH..." end
    local a = state.switches[key]
    if not a then return "TAP TO ASSIGN" end
    if key == "bank" then return a.name end
    return a.name .. " " .. positionDisplay(a.position)
end

local function allSwitchesAssigned()
    local s=state.switches
    return s.atti and s.bank and s.hold and s.reset
end

local function displayError()
    local message=tostring(state.apply.error or "Unknown error")
    return string.match(message, ":%d+:%s*(.+)$") or message
end

local function ledAvailable()
    return LED_STRIP_LENGTH and LED_STRIP_LENGTH > 0
        and type(setRGBLedColor) == "function"
        and type(applyRGBLedColors) == "function"
end

local function ledCounts()
    local buttonCount = LED_STRIP_LENGTH >= 26 and 6 or 0
    return LED_STRIP_LENGTH - buttonCount, buttonCount
end

local function setLed(index,r,g,b)
    pcall(setRGBLedColor,index,r,g,b)
end

local function clearWizardLeds()
    if not ledAvailable() then wizardLedSignature="off"; return end
    if wizardLedSignature=="off" then return end
    for index=0,LED_STRIP_LENGTH-1 do setLed(index,0,0,0) end
    pcall(applyRGBLedColors)
    wizardLedSignature="off"
end

local function setStaticWizardLeds(mode)
    if not ledAvailable() then wizardLedSignature="static:"..mode; return end
    local signature="static:"..mode
    if wizardLedSignature==signature then return end

    local systemCount,buttonCount=ledCounts()
    local ringR,ringG,ringB=0,0,0
    local buttonR,buttonG,buttonB=0,0,0

    if mode=="setup" or mode=="review" or mode=="elrs-check" then
        ringR,ringG,ringB=255,255,255
    elseif mode=="switch-waiting" or mode=="elrs-mismatch" then
        ringR=255
    elseif mode=="switch-ready" or mode=="elrs-ready" then
        ringG=255
    elseif mode=="success" then
        ringG=255; buttonG=255
    elseif mode=="error" then
        ringR=255; buttonR=255
    end

    for index=0,systemCount-1 do setLed(index,ringR,ringG,ringB) end
    for segment=0,buttonCount-1 do setLed(systemCount+segment,buttonR,buttonG,buttonB) end
    pcall(applyRGBLedColors)
    wizardLedSignature=signature
end

local function updateProgrammingLeds()
    if not ledAvailable() then wizardLedSignature="programming"; return end
    local systemCount,buttonCount=ledCounts()
    local now=getTime()
    local ringPhase=math.floor(now/8)
    local switchPhase=math.floor(now/10)
    local signature="programming:"..tostring(ringPhase)..":"..tostring(switchPhase)
    if wizardLedSignature==signature then return end

    for index=0,LED_STRIP_LENGTH-1 do setLed(index,0,0,0) end
    local ringCount=systemCount>=20 and 2 or 1
    local ringStart=0
    local cometRed={255,110,35}
    for ring=1,ringCount do
        local ringSize=ring==ringCount and (systemCount-ringStart) or math.floor(systemCount/ringCount)
        if ringSize>0 then
            local head=ringPhase%ringSize
            for tail=0,#cometRed-1 do
                local offset=(head-tail)%ringSize
                setLed(ringStart+offset,cometRed[tail+1],0,0)
            end
        end
        ringStart=ringStart+ringSize
    end
    if buttonCount==6 then
        local sweep={0,1,2,3,4,5,4,3,2,1}
        local head=sweep[(switchPhase%#sweep)+1]
        for segment=0,5 do
            local distance=math.abs(segment-head)
            local red=distance==0 and 255 or (distance==1 and 55 or 0)
            setLed(systemCount+segment,red,0,0)
        end
    end
    pcall(applyRGBLedColors)
    wizardLedSignature=signature
end

local function receiverIdRequired()
    local m=models[state.model]
    return m == "S1 V2" or m == "S2 MAX"
end

local function cleanScalar(v)
    if not v then return nil end
    v = string.match(v, "^%s*(.-)%s*$") or v
    local first,last=string.sub(v,1,1),string.sub(v,-1)
    if (first=='\"' and last=='\"') or (first=="'" and last=="'") then v=string.sub(v,2,-2) end
    return v
end

local function scanRfIdentity(path)
    if not io or type(io.open)~="function" or type(io.read)~="function" then return false end
    local f=io.open(path,"r")
    if not f then return false end

    local modelId,rfType,rfSubType=nil,nil,TARGET_RF_SUBTYPE
    local section=nil
    local sectionIndent=-1
    local slotActive=false
    local slotIndent=-1
    local buffer=""

    local function processLine(line)
        local spaces,body=string.match(line,"^(%s*)(.-)%s*\r?$")
        spaces=spaces or ""; body=body or ""
        if body=="" then return end
        local indent=#spaces
        if section and indent<=sectionIndent then
            section=nil; slotActive=false; slotIndent=-1
        elseif section and slotActive and indent<=slotIndent then
            slotActive=false; slotIndent=-1
        end
        if not section then
            if body=="modelId:" then section="modelId"; sectionIndent=indent; return
            elseif body=="moduleData:" then section="moduleData"; sectionIndent=indent; return
            else return end
        end
        if not slotActive then
            local slot=string.match(body,"^(%d+):$")
            if slot and tonumber(slot)==TARGET_MODULE_INDEX and indent>sectionIndent then
                slotActive=true; slotIndent=indent
            end
            return
        end
        if section=="modelId" then
            local v=string.match(body,"^val:%s*(%d+)%s*$")
            if v then
                local id=tonumber(v)
                if id and id>=0 and id<=MAX_RECEIVER_ID then modelId=id end
            end
        else
            local v=string.match(body,"^type:%s*(.-)%s*$")
            if v then rfType=cleanScalar(v); return end
            v=string.match(body,"^subType:%s*(.-)%s*$")
            if v then rfSubType=cleanScalar(v) or TARGET_RF_SUBTYPE end
        end
    end

    while true do
        local chunk=io.read(f,256)
        if not chunk or #chunk==0 then break end
        buffer=buffer..chunk
        local start=1
        while true do
            local nl=string.find(buffer,"\n",start,true)
            if not nl then buffer=string.sub(buffer,start); break end
            processLine(string.sub(buffer,start,nl-1)); start=nl+1
        end
    end
    if #buffer>0 then processLine(buffer) end
    io.close(f)
    return true,modelId,rfType,rfSubType
end

local function markId(id)
    if id<32 then state.receiver.maskLo=bit32.bor(state.receiver.maskLo,bit32.lshift(1,id))
    else state.receiver.maskHi=bit32.bor(state.receiver.maskHi,bit32.lshift(1,id-32)) end
end

local function idUsed(id)
    if id<32 then return bit32.band(state.receiver.maskLo,bit32.lshift(1,id))~=0 end
    return bit32.band(state.receiver.maskHi,bit32.lshift(1,id-32))~=0
end

local function allocateReceiverId()
    local r=state.receiver
    r.id=nil; r.status="scan-error"; r.scannedModels=0; r.matchingModels=0; r.usedIds=0
    r.maskLo=0; r.maskHi=0
    if type(dir)~="function" then return end

    local currentFilename=""
    if model and type(model.getInfo)=="function" then
        local info=model.getInfo()
        if info and type(info.filename)=="string" then
            currentFilename=string.match(info.filename,"([^/\\]+)$") or info.filename
        end
    end

    local nextFile=dir(MODELS_DIR)
    if type(nextFile)~="function" then return end
    local filename=nextFile()
    while filename do
        if type(filename)=="string" and string.match(string.lower(filename),"%.yml$") and filename~=currentFilename then
            local ok,id,rfType,rfSubType=scanRfIdentity(MODELS_DIR.."/"..filename)
            if not ok then return end
            r.scannedModels=r.scannedModels+1
            if rfType==TARGET_RF_TYPE and tostring(rfSubType or TARGET_RF_SUBTYPE)==TARGET_RF_SUBTYPE then
                r.matchingModels=r.matchingModels+1
                if id~=nil and id>0 then markId(id) end
            end
        end
        filename=nextFile()
    end
    for id=1,MAX_RECEIVER_ID do if idUsed(id) then r.usedIds=r.usedIds+1 end end
    for id=1,MAX_RECEIVER_ID do if not idUsed(id) then r.id=id; r.status="ok"; break end end
    if r.id==nil then r.status="full" end
end

local function receiverIdDisplay()
    if not receiverIdRequired() then return "N/A" end
    local r=state.receiver
    if r.status=="ok" and r.id~=nil then return r.id.." AUTO" end
    if r.status=="full" then return "NONE FREE" end
    return "SCAN ERROR"
end

local function receiverIdReady()
    return (not receiverIdRequired()) or (state.receiver.status=="ok" and state.receiver.id~=nil)
end

local function ensureInternalElrsForCheck()
    if telemetryLinkActive() then error("POWER OFF HELICOPTER - TELEMETRY ACTIVE") end
    if not profileReady() then error("Selected model profile is not yet verified") end
    if state.receiver.status~="ok" or not state.receiver.id then allocateReceiverId() end
    if not receiverIdReady() then error("No valid Receiver ID is available") end
    if not model or type(model.setModule)~="function" then error("EdgeTX module API unavailable") end
    model.setModule(0, {
        Type=5, subType=0, modelId=state.receiver.id,
        firstChannel=0, channelsCount=8
    })
    if type(model.getModule)=="function" and model.getModule(1)~=nil then
        model.setModule(1,{Type=0})
    end
end

safetyPage=function()
    lvgl.clear()
    setStaticWizardLeds("error")
    lvgl.build(wizard.fullPage({
        title=TITLE, subtitle="Safety Check",
        hasPrevious=false, hasNext=false,
        children={
            label("HELICOPTER POWER / TELEMETRY DETECTED"),
            label("Power off the helicopter before using this wizard."),
            label("No receiver may be linked while setup or ELRS settings are changed."),
            label("The wizard will resume automatically after telemetry is inactive."),
        },
    }))
end

local function selectPage(step)
    local target=page+step
    if target<1 or target>#pages then return end
    if step>0 and telemetryLinkActive() then
        safetyBlocked=true
        if elrsStage then elrsStage.reset() end
        safetyPage()
        return
    end
    state.capture.active=nil
    resetCaptureCandidate()
    page=target
    pages[page]()
end

local function modelPage()
    lvgl.clear()
    setStaticWizardLeds("setup")
    local colors=currentColors()
    lvgl.build(wizard.page({
        title=TITLE, subtitle="Model Setup", hasPrevious=false, hasNext=true,
        nextLabel="NEXT  >", nextFunc=function() selectPage(1) end,
        children1={
            choiceRow("Goosky model",models,function() return state.model end,function(value)
                if state.model~=value then
                    state.model=value; state.color=1; state.apply.status="not-run"
                    state.receiver.id=nil; state.receiver.status="not-scanned"
                    if elrsStage then elrsStage.reset() end
                    modelPage()
                end
            end),
            choiceRow("Color",colors,function() return state.color end,function(value)
                state.color=value; state.apply.status="not-run"
            end),
            choiceRow("Flight timer",timers,function() return state.timer end,function(value)
                state.timer=value; state.apply.status="not-run"
            end),
        },
        children2={
            sideLabel("Select the helicopter, color and flight timer."),
            sideLabel("Switches and RF settings are checked on the next pages."),
            sideLabel(profileReady() and "Verified profile: ready to configure." or "Profile visible for future support; programming is blocked."),
        },
    }))
end

local function switchCaptureRow(row)
    local metrics=wizard.metrics()
    local rowH=metrics.large and 58 or 42
    local captureH=metrics.large and 50 or 36
    local captureW=math.floor(LCD_W*(metrics.large and 0.60 or 0.62))
    local key=row.key
    return {
        type="rectangle", w=lvgl.PERCENT_SIZE+100, h=rowH, thickness=0,
        flexPad=0, flexFlow=lvgl.FLOW_ROW, align=LEFT|VCENTER,
        children={
            { type="rectangle", w=lvgl.PERCENT_SIZE+34, h=rowH, thickness=0, align=LEFT|VCENTER,
              children={{ type="label", x=metrics.large and 18 or 10, w=lvgl.PERCENT_SIZE+92,
                          color=wizard.textColor(), text=row.label }} },
            { type="rectangle", w=lvgl.PERCENT_SIZE+66, h=rowH, thickness=0, align=LEFT|VCENTER,
              children={{ type="button", x=0, y=math.floor((rowH-captureH)/2), w=captureW, h=captureH,
                          text=function() return assignmentDisplay(key) end,
                          color=function() return state.capture.active==key and ORANGE or DARKGREY end,
                          textColor=function() return state.capture.active==key and BLACK or WHITE end,
                          cornerRadius=metrics.large and 12 or 8,
                          press=function() state.capture.active=key; snapshotSwitches() end }} },
        },
    }
end

switchPage=function()
    lvgl.clear()
    local ready=allSwitchesAssigned() and state.capture.active==nil
    setStaticWizardLeds(ready and "switch-ready" or "switch-waiting")
    local children={}
    for i=1,#switchRows do children[#children+1]=switchCaptureRow(switchRows[i]) end
    children[#children+1]=label("Tap a box, then move only the switch you want to assign.")
    lvgl.build(wizard.fullPage({
        title=TITLE, subtitle="Switch Assignment", hasPrevious=true, hasNext=true,
        previousLabel="<  BACK",
        nextLabel=function() return (allSwitchesAssigned() and state.capture.active==nil) and "NEXT  >" or "ASSIGN" end,
        previousFunc=function() selectPage(-1) end,
        nextFunc=function() if allSwitchesAssigned() and state.capture.active==nil then selectPage(1) end end,
        children=children,
    }))
end

local function finishCapture(name,position)
    local key=state.capture.active
    if not key then return end
    state.switches[key]={name=name,position=position}
    state.apply.status="not-run"
    state.capture.active=nil
    resetCaptureCandidate()
end

local function captureMovedSwitch()
    local c=state.capture
    local key=c.active
    if not key then return end
    local now=getTime()
    if not c.candidateName then
        for i=1,#c.sources do
            local name=c.sources[i]
            local current=readPhysicalSwitch(name)
            local previous=c.snapshot[name]
            if current~=nil and previous~=nil and math.abs(current-previous)>256 then
                c.candidateName=name; c.candidateInitial=positionFromValue(previous)
                c.candidatePosition=positionFromValue(current); c.candidateSince=now; break
            end
            c.snapshot[name]=current
        end
        return
    end
    local current=readPhysicalSwitch(c.candidateName)
    if current==nil then return end
    local pos=positionFromValue(current)
    if pos~=c.candidatePosition then
        if (key=="hold" or key=="reset") and pos==c.candidateInitial then
            finishCapture(c.candidateName,c.candidatePosition); return
        end
        c.candidatePosition=pos; c.candidateSince=now; return
    end
    if now-c.candidateSince>=SWITCH_SETTLE_TICKS then finishCapture(c.candidateName,c.candidatePosition) end
end

elrsPage=function()
    if telemetryLinkActive() then safetyBlocked=true; safetyPage(); return end
    setStaticWizardLeds("elrs-check")
    if elrsStage then elrsStage.enter() end
end

local function reviewPage()
    lvgl.clear()
    setStaticWizardLeds("review")
    if receiverIdRequired() and state.receiver.status~="ok" then allocateReceiverId() end
    local colors=currentColors()
    local children2=previewChildren()
    if profileReady() then
        children2[#children2+1]=sideLabel("Safety: disconnect motor or remove blades before testing.")
    else
        children2[#children2+1]=sideLabel("PROFILE NOT VERIFIED")
        children2[#children2+1]=sideLabel("Programming is intentionally blocked for this model.")
    end

    lvgl.build(wizard.page({
        title=TITLE, subtitle="Review / Confirm", hasPrevious=true,
        hasNext=profileReady() and receiverIdReady() and elrsStage and elrsStage.isReady(),
        previousLabel="<  BACK", nextLabel="CONFIRM",
        previousFunc=function() selectPage(-1) end,
        nextFunc=function() selectPage(1) end,
        children1={
            wizard.summaryLine("Model",nil,models[state.model]),
            wizard.summaryLine("Color",nil,colors[state.color]),
            wizard.summaryLine("Receiver ID",nil,receiverIdDisplay()),
            wizard.summaryLine("Timer",nil,timers[state.timer]),
            wizard.summaryLine("ATTI",nil,assignmentDisplay("atti")),
            wizard.summaryLine("BANK",nil,assignmentDisplay("bank")),
            wizard.summaryLine("HOLD",nil,assignmentDisplay("hold")),
            wizard.summaryLine("RESET",nil,assignmentDisplay("reset")),
        },
        children2=children2,
    }))
end

local function runApplyBackend()
    if telemetryLinkActive() then
        state.apply.status="failed"
        state.apply.error="HELICOPTER POWER / TELEMETRY DETECTED - PROGRAMMING CANCELLED"
        return false
    end
    if state.apply.status=="success" then return true end
    state.apply.status="running"; state.apply.error=nil
    if type(collectgarbage)=="function" then collectgarbage("collect") end
    local loader=loadScript(RUN_DIR .. "/wizard-apply.lua")
    if type(loader)~="function" then state.apply.status="failed"; state.apply.error="Cannot load wizard-apply.lua"; return false end
    local apply=loader(); loader=nil
    if type(apply)~="function" then state.apply.status="failed"; state.apply.error="Invalid wizard apply backend"; return false end
    local payload={
        modelName=models[state.model], color=currentColors()[state.color],
        timerSeconds=timerSeconds[state.timer], receiverId=state.receiver.id,
        rfProfile=(elrsStage and elrsStage.getProfileId()) or nil,
        atti=state.switches.atti, bank=state.switches.bank,
        hold=state.switches.hold, reset=state.switches.reset,
    }
    local ok,result=pcall(apply,payload)
    apply=nil; payload=nil
    if type(collectgarbage)=="function" then collectgarbage("collect") end
    if not ok then
        state.apply.status="failed"; state.apply.error=tostring(result or "Unknown model programming error"); return false
    end
    state.apply.status="success"; return true
end

local function programmingPage()
    lvgl.clear()
    local colors=currentColors()
    local children2=previewChildren()
    children2[#children2+1]=sideLabel("PROGRAMMING MODEL...")
    children2[#children2+1]=sideLabel("Please wait. Do not exit the wizard.")
    lvgl.build(wizard.page({
        title=TITLE, subtitle="Programming", hasPrevious=false, hasNext=false,
        children1={
            wizard.summaryLine("Model",nil,models[state.model]),
            wizard.summaryLine("Color",nil,colors[state.color]),
            wizard.summaryLine("Receiver ID",nil,receiverIdDisplay()),
            wizard.summaryLine("Timer",nil,timers[state.timer]),
        },
        children2=children2,
    }))
end

completePage=function()
    if state.apply.status=="not-run" then
        if telemetryLinkActive() then state.apply.status="failed"; state.apply.error="HELICOPTER POWER / TELEMETRY DETECTED"
        elseif not profileReady() then state.apply.status="failed"; state.apply.error="Selected model profile is not yet verified"
        elseif not receiverIdReady() then state.apply.status="failed"; state.apply.error="No valid Receiver ID is available"
        elseif not elrsStage or not elrsStage.isReady() then state.apply.status="failed"; state.apply.error="ELRS settings are not verified"
        else
            state.apply.status="pending"; state.apply.startedAt=getTime()
            programmingPage(); updateProgrammingLeds(); return
        end
    elseif state.apply.status=="pending" or state.apply.status=="running" then
        programmingPage(); updateProgrammingLeds(); return
    end

    lvgl.clear()
    local colors=currentColors()
    local ok=state.apply.status=="success"
    setStaticWizardLeds(ok and "success" or "error")
    local children1
    local children2=previewChildren()
    children2[#children2+1]=sideLabel(ok and "MODEL PROGRAMMED" or "PROGRAMMING FAILED")
    if ok then
        children1={
            wizard.summaryLine("Model",nil,models[state.model]),
            wizard.summaryLine("Color",nil,colors[state.color]),
            wizard.summaryLine("Receiver ID",nil,receiverIdDisplay()),
            wizard.summaryLine("Timer",nil,timers[state.timer]),
            wizard.summaryLine("ATTI",nil,assignmentDisplay("atti")),
            wizard.summaryLine("BANK",nil,assignmentDisplay("bank")),
            wizard.summaryLine("HOLD",nil,assignmentDisplay("hold")),
            wizard.summaryLine("RESET",nil,assignmentDisplay("reset")),
        }
        children2[#children2+1]=sideLabel("Verify controls, HOLD, banks and ATT before flight.")
        children2[#children2+1]=sideLabel("Discover telemetry with the receiver powered and linked.")
    else
        children1={
            label("PROGRAMMING FAILED"), label(displayError()),
            wizard.summaryLine("Model",nil,models[state.model]),
            wizard.summaryLine("Receiver ID",nil,receiverIdDisplay()),
        }
        children2[#children2+1]=sideLabel("Use BACK to correct the setup and retry.")
    end
    lvgl.build(wizard.page({
        title=TITLE, subtitle=ok and "Complete" or "Error",
        hasPrevious=not ok, hasNext=false,
        previousLabel="<  BACK", previousFunc=function()
            state.apply.status="not-run"; state.apply.error=nil; state.apply.startedAt=0; selectPage(-1)
        end,
        children1=children1, children2=children2,
    }))
end

local function enforceSafetyGate()
    if telemetryLinkActive() then
        if not safetyBlocked then
            safetyBlocked=true
            state.capture.active=nil
            resetCaptureCandidate()
            if elrsStage then elrsStage.reset() end
            if state.apply.status=="pending" or state.apply.status=="running" then
                state.apply.status="failed"
                state.apply.error="HELICOPTER POWER / TELEMETRY DETECTED - OPERATION CANCELLED"
            end
            safetyPage()
        end
        return false
    end
    if safetyBlocked then
        safetyBlocked=false
        if pages[page] then pages[page]() end
    end
    return true
end

local function init()
    simulatorMode=detectSimulatorMode()
    buildSwitchSources()
    elrsStage=elrsStageFactory.new({
        wizard=wizard, title=TITLE,
        getModelName=function() return models[state.model] end,
        ensureModule=ensureInternalElrsForCheck,
        linkConnected=telemetryLinkActive,
        goBack=function() selectPage(-1) end,
        goNext=function() selectPage(1) end,
    })
    pages={modelPage,switchPage,elrsPage,reviewPage,completePage}
    page=1; wizardLedSignature=nil; safetyBlocked=false; telemetrySwitchIndex=nil
    state.apply.status="not-run"; state.apply.error=nil; state.apply.startedAt=0
    if telemetryLinkActive() then safetyBlocked=true; safetyPage() else pages[1]() end
end

local function run(event,touchState)
    if not enforceSafetyGate() then
        if wizard.exitWizard() then clearWizardLeds(); return 2 end
        return 0
    end

    if page==1 then
        setStaticWizardLeds("setup")
    elseif page==2 then
        if state.capture.active~=nil then captureMovedSwitch() end
        local ready=allSwitchesAssigned() and state.capture.active==nil
        setStaticWizardLeds(ready and "switch-ready" or "switch-waiting")
    elseif page==3 then
        if elrsStage then elrsStage.update() end
        local ledState=elrsStage and elrsStage.getLedState and elrsStage.getLedState() or "checking"
        if ledState=="ready" then
            setStaticWizardLeds("elrs-ready")
        elseif ledState=="mismatch" then
            setStaticWizardLeds("elrs-mismatch")
        else
            setStaticWizardLeds("elrs-check")
        end
    elseif page==4 then
        setStaticWizardLeds("review")
    elseif page==5 then
        if state.apply.status=="pending" then
            updateProgrammingLeds()
            if getTime()-state.apply.startedAt>=PROGRAMMING_LED_MIN_TICKS then runApplyBackend(); completePage() end
        elseif state.apply.status=="running" then updateProgrammingLeds()
        elseif state.apply.status=="success" then setStaticWizardLeds("success")
        elseif state.apply.status=="failed" then setStaticWizardLeds("error") end
    end

    if event==EVT_VIRTUAL_PREV_PAGE and page>1 then
        if page~=5 or state.apply.status=="failed" then
            killEvents(event)
            if page==5 then state.apply.status="not-run"; state.apply.error=nil; state.apply.startedAt=0 end
            selectPage(-1)
        end
    elseif event==EVT_VIRTUAL_NEXT_PAGE and page<#pages then
        local canAdvance=true
        if page==2 then canAdvance=allSwitchesAssigned() and state.capture.active==nil
        elseif page==3 then canAdvance=elrsStage and elrsStage.isReady() end
        if canAdvance then killEvents(event); selectPage(1) end
    end
    if wizard.exitWizard() then clearWizardLeds(); return 2 end
    return 0
end

return { init=init, run=run }

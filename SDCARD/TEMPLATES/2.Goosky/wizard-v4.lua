-- NERC Goosky BNF Wizard v1 diagnostic build
-- EdgeTX 2.12 color radios
-- Bounded-memory Receiver ID scan + settled switch capture.
-- No ELRS check/fix and no model writes yet.

local RUN_DIR = "/TEMPLATES/2.Goosky"
local IMAGE_DIR = "/IMAGES/"
local MODELS_DIR = "/MODELS"
local wizard = loadScript(RUN_DIR .. "/wizard-ui.lua")()

local TITLE = "NERC Goosky BNF Wizard"
local MAX_RECEIVER_ID = 63
local TARGET_MODULE_INDEX = 0
local TARGET_RF_TYPE = "TYPE_CROSSFIRE"
local TARGET_RF_SUBTYPE = "0"
local SWITCH_SETTLE_TICKS = 20 -- getTime() is 10 ms/tick = 200 ms

local page = 1
local pages = {}
local switchPage

local models = { "S1 V1", "S1 V2", "S2 Legend V1", "S2 MAX", "RS4 Venom" }
local standardColors = { "Orange", "Blue", "Purple" }
local rs4VenomColors = { "Orange", "Green" }
local timers = { "3:00", "3:30", "4:00", "4:30", "5:00", "5:30", "6:00" }

local state = {
    model = 2,
    color = 1,
    timer = 5,
    switches = { atti=nil, bank=nil, hold=nil, reset=nil },
    capture = {
        active=nil,
        sources={},
        snapshot={},
        candidateName=nil,
        candidatePosition=nil,
        candidateInitial=nil,
        candidateSince=0,
        needsRebuild=false,
    },
    receiver = {
        id=nil,
        status="not-scanned",
        scannedModels=0,
        matchingModels=0,
        usedIds=0,
        maskLo=0,
        maskHi=0,
        memBefore=0,
        memAfter=0,
    },
}

local switchRows = {
    { key="atti", label="ATTI" },
    { key="bank", label="BANK" },
    { key="hold", label="THROTTLE HOLD" },
    { key="reset", label="TIMER RESET" },
}

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

local function previewChildren()
    local path = previewImagePath()
    if path then
        return { wizard.image({ file=path, visibleFunc=function() return true end }) }
    end
    return { label("Model preview"), label("Matching image not installed yet.") }
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

local function receiverIdRequired()
    local m=models[state.model]
    return m == "S1 V2" or m == "S2 MAX"
end

local function cleanScalar(v)
    if not v then return nil end
    v = string.match(v, "^%s*(.-)%s*$") or v
    local first,last=string.sub(v,1,1),string.sub(v,-1)
    if (first=='"' and last=='"') or (first=="'" and last=="'") then
        v=string.sub(v,2,-2)
    end
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
            if body=="modelId:" then
                section="modelId"; sectionIndent=indent; return
            elseif body=="moduleData:" then
                section="moduleData"; sectionIndent=indent; return
            else
                return
            end
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
            if not nl then
                buffer=string.sub(buffer,start)
                break
            end
            processLine(string.sub(buffer,start,nl-1))
            start=nl+1
        end
    end
    if #buffer>0 then processLine(buffer) end
    io.close(f)
    return true,modelId,rfType,rfSubType
end

local function markId(id)
    if id<32 then
        state.receiver.maskLo=bit32.bor(state.receiver.maskLo,bit32.lshift(1,id))
    else
        state.receiver.maskHi=bit32.bor(state.receiver.maskHi,bit32.lshift(1,id-32))
    end
end

local function idUsed(id)
    if id<32 then
        return bit32.band(state.receiver.maskLo,bit32.lshift(1,id))~=0
    end
    return bit32.band(state.receiver.maskHi,bit32.lshift(1,id-32))~=0
end

local function usedIdText()
    local out=""
    local shown=0
    for id=1,MAX_RECEIVER_ID do
        if idUsed(id) then
            if shown>0 then out=out.."," end
            out=out..id
            shown=shown+1
            if shown>=8 then
                if state.receiver.usedIds>shown then out=out..",..." end
                break
            end
        end
    end
    if out=="" then return "none" end
    return out
end

local function allocateReceiverId()
    local r=state.receiver
    if type(collectgarbage)=="function" then collectgarbage("collect") end
    r.memBefore=type(collectgarbage)=="function" and math.floor(collectgarbage("count")+0.5) or 0
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

    -- Receiver ID 0 behaves as the EdgeTX/CRSF default and is intentionally
    -- reserved. Allocate only 1..63 so AUTO always chooses an explicit ID.
    for id=1,MAX_RECEIVER_ID do
        if not idUsed(id) then r.id=id; r.status="ok"; break end
    end
    if r.id==nil then r.status="full" end

    filename=nil; nextFile=nil
    if type(collectgarbage)=="function" then collectgarbage("collect") end
    r.memAfter=type(collectgarbage)=="function" and math.floor(collectgarbage("count")+0.5) or 0
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

local function selectPage(step)
    local target=page+step
    if target<1 or target>#pages then return end
    state.capture.active=nil
    state.capture.needsRebuild=false
    resetCaptureCandidate()
    page=target
    pages[page]()
end

local function modelPage()
    lvgl.clear()
    local colors=currentColors()
    lvgl.build(wizard.page({
        title=TITLE, subtitle="Model Setup", hasPrevious=false, hasNext=true,
        nextLabel="NEXT  >", nextFunc=function() selectPage(1) end,
        children1={
            choiceRow("Goosky model",models,function() return state.model end,function(value)
                if state.model~=value then state.model=value; state.color=1; modelPage() end
            end),
            choiceRow("Color",colors,function() return state.color end,function(value) state.color=value end),
            choiceRow("Flight timer",timers,function() return state.timer end,function(value) state.timer=value end),
        },
        children2={
            label("Select the helicopter, color and flight timer."),
            label("Switches are assigned on the next page."),
            label("No model programming occurs in this test build."),
        },
    }))
end

local function switchCaptureRow(row)
    local metrics=wizard.metrics()
    local rowH=metrics.large and 58 or 42
    local captureH=metrics.large and 50 or 36
    local captureW=math.floor(LCD_W*(metrics.large and 0.60 or 0.62))
    local active=state.capture.active==row.key
    return {
        type="rectangle", w=lvgl.PERCENT_SIZE+100, h=rowH, thickness=0,
        flexPad=0, flexFlow=lvgl.FLOW_ROW, align=LEFT|VCENTER,
        children={
            { type="rectangle", w=lvgl.PERCENT_SIZE+34, h=rowH, thickness=0, align=LEFT|VCENTER,
              children={{ type="label", x=metrics.large and 18 or 10, w=lvgl.PERCENT_SIZE+92,
                          color=wizard.textColor(), text=row.label }} },
            { type="rectangle", w=lvgl.PERCENT_SIZE+66, h=rowH, thickness=0, align=LEFT|VCENTER,
              children={{ type="button", x=0, y=math.floor((rowH-captureH)/2), w=captureW, h=captureH,
                          text=assignmentDisplay(row.key), color=active and ORANGE or DARKGREY,
                          textColor=active and BLACK or WHITE, cornerRadius=metrics.large and 12 or 8,
                          press=function()
                              state.capture.active=row.key
                              snapshotSwitches()
                              state.capture.needsRebuild=true
                          end }} },
        },
    }
end

switchPage=function()
    lvgl.clear()
    local children={}
    for i=1,#switchRows do children[#children+1]=switchCaptureRow(switchRows[i]) end
    children[#children+1]=label("Tap a box, then move only the switch you want to assign.")
    lvgl.build(wizard.fullPage({
        title=TITLE, subtitle="Switch Assignment", hasPrevious=true,
        hasNext=allSwitchesAssigned() and state.capture.active==nil,
        previousLabel="<  BACK", nextLabel="NEXT  >",
        previousFunc=function() selectPage(-1) end,
        nextFunc=function() selectPage(1) end,
        children=children,
    }))
end

local function finishCapture(name,position)
    local key=state.capture.active
    if not key then return end
    state.switches[key]={name=name,position=position}
    state.capture.active=nil
    resetCaptureCandidate()
    state.capture.needsRebuild=true
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
                c.candidateName=name
                c.candidateInitial=positionFromValue(previous)
                c.candidatePosition=positionFromValue(current)
                c.candidateSince=now
                break
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
            finishCapture(c.candidateName,c.candidatePosition)
            return
        end
        c.candidatePosition=pos
        c.candidateSince=now
        return
    end

    if now-c.candidateSince>=SWITCH_SETTLE_TICKS then
        finishCapture(c.candidateName,c.candidatePosition)
    end
end

local function reviewPage()
    lvgl.clear()
    allocateReceiverId()
    if type(collectgarbage)=="function" then collectgarbage("collect") end
    local colors=currentColors()
    local r=state.receiver
    local children2=previewChildren()
    children2[#children2+1]=label("Scan "..r.scannedModels.." / CRSF "..r.matchingModels.." / IDs "..r.usedIds)
    children2[#children2+1]=label("Used: "..usedIdText())
    children2[#children2+1]=label("ID 0 reserved")
    children2[#children2+1]=label("Lua KB: "..r.memBefore.." -> "..r.memAfter)
    lvgl.build(wizard.page({
        title=TITLE, subtitle="Review / Confirm", hasPrevious=true, hasNext=receiverIdReady(),
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

local function completePage()
    lvgl.clear()
    local colors=currentColors()
    lvgl.build(wizard.page({
        title=TITLE, subtitle="Confirmed", hasPrevious=true, hasNext=false,
        previousLabel="<  BACK", previousFunc=function() selectPage(-1) end,
        children1={
            wizard.summaryLine("Model",nil,models[state.model]),
            wizard.summaryLine("Color",nil,colors[state.color]),
            wizard.summaryLine("Receiver ID",nil,receiverIdDisplay()),
            wizard.summaryLine("ATTI",nil,assignmentDisplay("atti")),
            wizard.summaryLine("BANK",nil,assignmentDisplay("bank")),
            wizard.summaryLine("HOLD",nil,assignmentDisplay("hold")),
            wizard.summaryLine("RESET",nil,assignmentDisplay("reset")),
            label("Diagnostic flow confirmed. Hold [RTN] to exit."),
        },
        children2=previewChildren(),
    }))
end

local function init()
    buildSwitchSources()
    pages={modelPage,switchPage,reviewPage,completePage}
    page=1
    pages[1]()
end

local function run(event,touchState)
    if page==2 and state.capture.needsRebuild then
        state.capture.needsRebuild=false
        switchPage()
        return 0
    end

    if page==2 and state.capture.active~=nil then
        captureMovedSwitch()
    end

    if event==EVT_VIRTUAL_PREV_PAGE and page>1 then
        killEvents(event); selectPage(-1)
    elseif event==EVT_VIRTUAL_NEXT_PAGE and page<#pages then
        if page~=2 or allSwitchesAssigned() then killEvents(event); selectPage(1) end
    end
    if wizard.exitWizard() then return 2 end
    return 0
end

return { init=init, run=run }

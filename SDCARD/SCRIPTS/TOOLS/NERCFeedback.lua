-- NERC Feedback settings tool for EdgeTX color radios.
-- Radio-wide preferences for NERC-managed LEDs and haptic feedback.

local loader = loadScript("/SCRIPTS/LIB/NERC_FEEDBACK.lua")
if type(loader) ~= "function" then error("Cannot load NERC_FEEDBACK.lua") end
local feedback = loader()
loader = nil

local TITLE = "NERC Feedback"
local settings = feedback.load()
local row = 1
local saveMessage = ""

local rows = {
    { key="leds", label="LEDs" },
    { key="gimbalBrightness", label="Gimbal Brightness" },
    { key="switchBrightness", label="SW1-SW6 Brightness" },
    { key="haptic", label="Haptic Feedback" },
}

local function eventIs(event, value)
    return type(value) == "number" and event == value
end

local function valueText(def)
    local value = settings[def.key]
    if def.key == "leds" or def.key == "haptic" then
        return value and "ON" or "OFF"
    end
    return tostring(value or 0) .. "%"
end

local function save()
    local ok, err = feedback.save(settings)
    saveMessage = ok and "SAVED" or tostring(err or "SAVE FAILED")
end

local function changeSelected(direction)
    local def = rows[row]
    if not def then return end
    if def.key == "leds" or def.key == "haptic" then
        settings[def.key] = not settings[def.key]
    else
        local value = tonumber(settings[def.key]) or 100
        value = value + (direction or 1) * 10
        if value > 100 then value = 0 end
        if value < 0 then value = 100 end
        settings[def.key] = value
    end
    settings = feedback.normalize(settings)
    save()
end

local function ledAvailable()
    return LED_STRIP_LENGTH and LED_STRIP_LENGTH > 0
        and type(setRGBLedColor) == "function"
        and type(applyRGBLedColors) == "function"
end

local function applyPreview()
    if not ledAvailable() then return end
    local functionCount = LED_STRIP_LENGTH >= 26 and 6 or 0
    local systemCount = LED_STRIP_LENGTH - functionCount
    local gimbal = settings.leds and settings.gimbalBrightness or 0
    local switches = settings.leds and settings.switchBrightness or 0
    local gw = feedback.scale(255, gimbal)
    local sg = feedback.scale(190, switches)

    for index=0,systemCount-1 do
        pcall(setRGBLedColor,index,gw,gw,gw)
    end
    for segment=0,functionCount-1 do
        pcall(setRGBLedColor,systemCount+segment,0,sg,0)
    end
    pcall(applyRGBLedColors)
end

local function clearPreview()
    if not ledAvailable() then return end
    for index=0,LED_STRIP_LENGTH-1 do pcall(setRGBLedColor,index,0,0,0) end
    pcall(applyRGBLedColors)
end

local function draw()
    lcd.clear(BLACK)
    local wide = LCD_W >= 700
    local margin = wide and 42 or 20
    local headerH = wide and 60 or 44
    local rowH = wide and 70 or 50
    local startY = headerH + (wide and 18 or 10)

    lcd.drawFilledRectangle(0,0,LCD_W,headerH,lcd.RGB(185,24,24))
    lcd.drawText(margin, math.floor(headerH/2), TITLE, VCENTER + BOLD + WHITE)

    for i,def in ipairs(rows) do
        local y = startY + (i-1)*rowH
        local selected = i == row
        if selected then
            lcd.drawFilledRectangle(margin-8,y-4,LCD_W-(margin*2)+16,rowH-4,lcd.RGB(42,42,42))
            lcd.drawRectangle(margin-8,y-4,LCD_W-(margin*2)+16,rowH-4,lcd.RGB(220,80,40),2)
        end
        lcd.drawText(margin,y+math.floor((rowH-8)/2),def.label,VCENTER + (wide and BOLD or 0) + WHITE)
        lcd.drawText(LCD_W-margin,y+math.floor((rowH-8)/2),valueText(def),RIGHT + VCENTER + BOLD + (selected and ORANGE or WHITE))
    end

    local footerY = math.min(LCD_H-52,startY + #rows*rowH + 8)
    lcd.drawText(margin,footerY,"Rotate: select   ENTER: change   EXIT: done",SMLSIZE + WHITE)
    lcd.drawText(margin,footerY+20,"LED preview is active while this tool is open.",SMLSIZE + GREY)
    if saveMessage ~= "" then
        lcd.drawText(LCD_W-margin,footerY+20,saveMessage,RIGHT + SMLSIZE + GREEN)
    end
end

local function init()
    settings = feedback.load()
    row = 1
    saveMessage = ""
    applyPreview()
end

local function run(event,touchState)
    if eventIs(event,EVT_VIRTUAL_EXIT) or eventIs(event,EVT_EXIT_BREAK) then
        clearPreview()
        return 2
    end

    if eventIs(event,EVT_VIRTUAL_PREV) or eventIs(event,EVT_ROT_LEFT) then
        row = row - 1
        if row < 1 then row = #rows end
    elseif eventIs(event,EVT_VIRTUAL_NEXT) or eventIs(event,EVT_ROT_RIGHT) then
        row = row + 1
        if row > #rows then row = 1 end
    elseif eventIs(event,EVT_MINUS_FIRST) or eventIs(event,EVT_MINUS_REPT) then
        changeSelected(-1)
    elseif eventIs(event,EVT_PLUS_FIRST) or eventIs(event,EVT_PLUS_REPT)
        or eventIs(event,EVT_VIRTUAL_ENTER) or eventIs(event,EVT_ENTER_FIRST)
        or eventIs(event,EVT_ENTER_BREAK) then
        changeSelected(1)
    end

    if touchState and (eventIs(event,EVT_TOUCH_TAP) or eventIs(event,EVT_TOUCH_BREAK)) then
        local y = touchState.y or touchState.startY or 0
        local wide = LCD_W >= 700
        local headerH = wide and 60 or 44
        local rowH = wide and 70 or 50
        local startY = headerH + (wide and 18 or 10)
        local selected = math.floor((y-startY)/rowH)+1
        if selected >= 1 and selected <= #rows then
            if selected == row then changeSelected(1) else row = selected end
        end
    end

    applyPreview()
    draw()
    return 0
end

return { init=init, run=run }

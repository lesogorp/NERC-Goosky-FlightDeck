---- #########################################################################
---- #                                                                       #
---- # Copyright (C) EdgeTX                                                  #
-----#                                                                       #
-----# Credits: graphics by https://github.com/jrwieland                     #
-----#                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #                                                                       #
---- # This program is free software; you can redistribute it and/or modify  #
---- # it under the terms of the GNU General Public License version 2 as     #
---- # published by the Free Software Foundation.                            #
---- #                                                                       #
---- # This program is distributed in the hope that it will be useful        #
---- # but WITHOUT ANY WARRANTY; without even the implied warranty of        #
---- # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         #
---- # GNU General Public License for more details.                          #
---- #                                                                       #
---- #########################################################################

-- Author: Alexander Gnauck
-- Vendored from EdgeTX 2.12 wizard-ui.lua so the NERC Goosky wizard is self-contained.
-- NERC changes:
--   * theme-aware field/review text using EdgeTX COLOR_THEME_PRIMARY1
--   * native EdgeTX page/body background
--   * large touch-friendly BACK / NEXT / CONFIRM buttons
--   * no tiny stock previous/next page arrows
--   * fixed-column review/summary rows for consistent alignment
--   * responsive sizing for 480x320 (TX15/GX15) and 800x480 (TX16S MK3)
--   * responsive model-image helper for Review / Confirm
--   * full-width page helper for touch-first switch assignment

local wizard = {}

local THICKNESS = 0
local LANDSCAPE = 0
local PORTRAIT = 1
local ORIENTATION = (LCD_W > LCD_H) and LANDSCAPE or PORTRAIT
local LARGE_LCD = LCD_W >= 700
local THEME_TEXT = COLOR_THEME_PRIMARY1 or WHITE
local PANEL_COLOR = DARKGREY

local NAV_H = LARGE_LCD and 84 or 60
local BTN_W = LARGE_LCD and 200 or 140
local BTN_H = LARGE_LCD and 64 or 52
local BTN_PAD = LARGE_LCD and 18 or 10
local SUMMARY_H = LARGE_LCD and 36 or 30
local SUMMARY_X_PAD = LARGE_LCD and 10 or 6
local NAV_FONT = LARGE_LCD and DBLSIZE or MIDSIZE
local FIELD_FONT = 0
local RADIUS = LARGE_LCD and 12 or 8
local IMAGE_PAD = LARGE_LCD and 24 or 12
local exit = false

function wizard.isLargeLCD()
    return LARGE_LCD
end

function wizard.textColor()
    return THEME_TEXT
end

function wizard.metrics()
    return {
        large = LARGE_LCD,
        navH = NAV_H,
        buttonW = BTN_W,
        buttonH = BTN_H,
        buttonPad = BTN_PAD,
        summaryH = SUMMARY_H,
        fieldFont = FIELD_FONT,
        imagePad = IMAGE_PAD,
    }
end

function wizard.exitWizard()
    return exit
end

local function closeDialog()
    lvgl.confirm({
        title = "Exit",
        message = "Do you really want to exit the model wizard?",
        confirm = function()
            exit = true
        end,
    })
end

local function navButton(text, x, press, isNext)
    return {
        type = "button",
        x = x,
        y = math.floor((NAV_H - BTN_H) / 2),
        w = BTN_W,
        h = BTN_H,
        text = text,
        press = press,
        font = NAV_FONT,
        color = isNext and ORANGE or PANEL_COLOR,
        textColor = isNext and BLACK or WHITE,
        cornerRadius = RADIUS,
    }
end

local function navigation(settings)
    local children = {}

    if settings.hasPrevious then
        children[#children + 1] = navButton(
            settings.previousLabel or "<  BACK",
            BTN_PAD,
            settings.previousFunc,
            false
        )
    end

    if settings.hasNext then
        children[#children + 1] = navButton(
            settings.nextLabel or "NEXT  >",
            LCD_W - BTN_W - BTN_PAD,
            settings.nextFunc,
            true
        )
    end

    return {
        type = "rectangle",
        w = lvgl.PERCENT_SIZE + 100,
        h = NAV_H,
        thickness = THICKNESS,
        children = children,
    }
end

local function pageShell(settings, body)
    return {
        {
            type = "page",
            title = settings.title,
            subtitle = settings.subtitle,
            flexPad = 0,
            flexFlow = lvgl.FLOW_COLUMN,
            align = CENTER | VTOP,
            backButton = true,
            back = closeDialog,
            children = {
                body,
                navigation(settings),
            },
        },
    }
end

function wizard.page(settings)
    local bodyH = math.max(1, lvgl.PAGE_BODY_HEIGHT - NAV_H)

    if ORIENTATION == LANDSCAPE then
        return pageShell(settings, {
            type = "rectangle",
            w = lvgl.PERCENT_SIZE + 100,
            h = bodyH,
            thickness = THICKNESS,
            flexFlow = lvgl.FLOW_ROW,
            align = LEFT | VTOP,
            children = {
                {
                    type = "rectangle",
                    w = lvgl.PERCENT_SIZE + 60,
                    h = lvgl.PERCENT_SIZE + 100,
                    thickness = THICKNESS,
                    flexFlow = lvgl.FLOW_COLUMN,
                    align = LEFT | VTOP,
                    children = settings.children1,
                },
                {
                    type = "rectangle",
                    scrollBar = false,
                    w = lvgl.PERCENT_SIZE + 40,
                    h = lvgl.PERCENT_SIZE + 100,
                    thickness = THICKNESS,
                    flexFlow = lvgl.FLOW_COLUMN,
                    align = LEFT | VTOP,
                    children = settings.children2,
                },
            },
        })
    end

    return pageShell(settings, {
        type = "rectangle",
        w = lvgl.PERCENT_SIZE + 100,
        h = bodyH,
        thickness = THICKNESS,
        flexFlow = lvgl.FLOW_COLUMN,
        align = LEFT | VTOP,
        children = {
            {
                type = "rectangle",
                w = lvgl.PERCENT_SIZE + 100,
                h = lvgl.PERCENT_SIZE + 60,
                thickness = THICKNESS,
                flexFlow = lvgl.FLOW_COLUMN,
                align = LEFT | VTOP,
                children = settings.children1,
            },
            {
                type = "rectangle",
                scrollBar = false,
                w = lvgl.PERCENT_SIZE + 100,
                h = lvgl.PERCENT_SIZE + 40,
                thickness = THICKNESS,
                flexFlow = lvgl.FLOW_COLUMN,
                align = LEFT | VTOP,
                children = settings.children2,
            },
        },
    })
end

-- Full-width content area used when large finger targets matter more than the
-- normal 60/40 wizard split (for example, switch capture).
function wizard.fullPage(settings)
    local bodyH = math.max(1, lvgl.PAGE_BODY_HEIGHT - NAV_H)
    return pageShell(settings, {
        type = "rectangle",
        w = lvgl.PERCENT_SIZE + 100,
        h = bodyH,
        thickness = THICKNESS,
        flexFlow = lvgl.FLOW_COLUMN,
        align = LEFT | VTOP,
        children = settings.children,
    })
end

function wizard.settings(settings)
    return {
        type = "rectangle",
        flexPad = 0,
        flexFlow = lvgl.FLOW_ROW,
        thickness = THICKNESS,
        w = lvgl.PERCENT_SIZE + 100,
        visible = settings.visible,
        children = {
            {
                type = "rectangle",
                thickness = THICKNESS,
                w = lvgl.PERCENT_SIZE + 60,
                children = {
                    {
                        type = "label",
                        w = lvgl.PERCENT_SIZE + 100,
                        color = THEME_TEXT,
                        font = FIELD_FONT,
                        text = settings.title,
                    },
                },
            },
            {
                type = "rectangle",
                thickness = THICKNESS,
                w = lvgl.PERCENT_SIZE + 40,
                flexFlow = lvgl.FLOW_ROW,
                align = LEFT | VCENTER,
                children = settings.children,
            },
        },
    }
end

function wizard.settingsVertical(settings)
    return {
        type = "rectangle",
        flexPad = 0,
        thickness = THICKNESS,
        w = lvgl.PERCENT_SIZE + 100,
        flexFlow = lvgl.FLOW_COLUMN,
        align = LEFT | VTOP,
        visible = settings.visible,
        children = {
            {
                type = "rectangle",
                thickness = THICKNESS,
                w = lvgl.PERCENT_SIZE + 100,
                children = {
                    {
                        type = "label",
                        w = lvgl.PERCENT_SIZE + 100,
                        color = THEME_TEXT,
                        font = FIELD_FONT,
                        text = settings.title,
                    },
                },
            },
            {
                type = "rectangle",
                thickness = THICKNESS,
                flexFlow = lvgl.FLOW_ROW,
                align = LEFT | VCENTER,
                children = settings.children,
            },
        },
    }
end

function wizard.summaryLine(title, chNum, text2)
    local txt
    if chNum ~= nil then
        txt = "CH" .. (chNum + 1)
    else
        txt = text2
    end

    return {
        type = "rectangle",
        w = lvgl.PERCENT_SIZE + 100,
        h = SUMMARY_H,
        thickness = THICKNESS,
        flexPad = 0,
        flexFlow = lvgl.FLOW_ROW,
        align = LEFT | VCENTER,
        children = {
            {
                type = "rectangle",
                w = lvgl.PERCENT_SIZE + 42,
                h = SUMMARY_H,
                thickness = THICKNESS,
                align = LEFT | VCENTER,
                children = {
                    {
                        type = "label",
                        x = SUMMARY_X_PAD,
                        w = lvgl.PERCENT_SIZE + 95,
                        color = THEME_TEXT,
                        font = FIELD_FONT,
                        text = title .. ":",
                    },
                },
            },
            {
                type = "rectangle",
                w = lvgl.PERCENT_SIZE + 58,
                h = SUMMARY_H,
                thickness = THICKNESS,
                align = LEFT | VCENTER,
                children = {
                    {
                        type = "label",
                        x = SUMMARY_X_PAD,
                        w = lvgl.PERCENT_SIZE + 95,
                        color = THEME_TEXT,
                        font = FIELD_FONT,
                        text = txt,
                    },
                },
            },
        },
    }
end

function wizard.image(settings)
    local border = IMAGE_PAD
    return {
        type = "image",
        x = border,
        y = border,
        w = math.max(1, LCD_W * 40 / 100 - border * 2),
        h = math.max(1, lvgl.PAGE_BODY_HEIGHT - NAV_H - border * 2),
        file = settings.file,
        visible = settings.visibleFunc,
    }
end

return wizard

---@omw-context player

-- Take/Steal and Drop menu shown after an item is pulled in.

local ui = require('openmw.ui')
local util = require('openmw.util')
local async = require('openmw.async')
local I = require('openmw.interfaces')

local v2 = util.vector2

local menu = {}
local windowElement = nil
local activeCallback = nil
local buttonElements = {}

-- ==============================================
-- CONFIGURATION
-- ==============================================
local BTN_WIDTH = 160
local BTN_HEIGHT = 36
local BTN_SPACING = 8
local WINDOW_PADDING = 16
local TITLE_HEIGHT = 30
local TEXT_SIZE = 18
local TITLE_TEXT_SIZE = 20

local WINDOW_WIDTH = BTN_WIDTH + (WINDOW_PADDING * 2)
local WINDOW_HEIGHT = TITLE_HEIGHT + (BTN_HEIGHT * 2) + (BTN_SPACING * 2) + WINDOW_PADDING

local COLOR_NORMAL = util.color.rgb(0.9, 0.8, 0.6)      -- Sandy gold (Morrowind style)
local COLOR_STEAL = util.color.rgb(1.0, 0.3, 0.3)       -- Red warning
local COLOR_TITLE = util.color.rgb(1.0, 0.85, 0.5)      -- Brighter gold for title
local COLOR_BG = util.color.rgb(0, 0, 0)                -- Black background
local COLOR_HOVER = util.color.rgb(0.3, 0.25, 0.15)     -- Subtle highlight on hover

local function isOwned(item)
    if not item then return false end

    if item.owner then
        if item.owner.recordId or item.owner.factionId then
            return true
        end
    end

    return false
end

local function getItemName(item)
    if not item then return "Unknown" end

    if item.type and item.type.record then
        local record = item.type.record(item)
        if record and record.name then
            return record.name
        end
    end

    return item.recordId or "Unknown Item"
end

-- ==============================================
-- MENU MANAGEMENT
-- ==============================================
local function closeMenu(action)
    if windowElement then
        windowElement:destroy()
        windowElement = nil
    end
    buttonElements = {}

    I.UI.setMode(nil)

    if activeCallback then
        local cb = activeCallback
        activeCallback = nil
        cb(action)
    end
end

-- ==============================================
-- MENU OPEN
-- ==============================================
function menu.open(item, callback)
    if windowElement then
        closeMenu('cancel')
    end

    activeCallback = callback
    buttonElements = {}

    local takeLabel = "Take"
    local takeColor = COLOR_NORMAL

    if isOwned(item) then
        takeLabel = "Steal"
        takeColor = COLOR_STEAL
    end

    local itemName = getItemName(item)

    if #itemName > 20 then
        itemName = itemName:sub(1, 18) .. "..."
    end

    local layerId = ui.layers.indexOf("Modal")
    local screenSize = ui.layers[layerId].size
    local windowPos = v2(
        (screenSize.x - WINDOW_WIDTH) / 2,
        (screenSize.y - WINDOW_HEIGHT) / 2 - 50  -- Slightly above center
    )

    -- Interface mode: cursor and pause. Esc is handled in player.lua.
    I.UI.setMode('Interface', { windows = {} })

    windowElement = ui.create({
        type = ui.TYPE.Widget,
        layer = 'Modal',
        props = {
            position = windowPos,
            size = v2(WINDOW_WIDTH, WINDOW_HEIGHT),
        },
        content = ui.content {}
    })

    windowElement.layout.content:add({
        name = 'windowBackground',
        type = ui.TYPE.Image,
        props = {
            relativeSize = v2(1, 1),
            resource = ui.texture { path = 'white' },
            color = COLOR_BG,
            alpha = 0.9,
        },
    })

    windowElement.layout.content:add({
        name = 'title',
        type = ui.TYPE.Text,
        props = {
            position = v2(WINDOW_WIDTH / 2, WINDOW_PADDING),
            anchor = v2(0.5, 0),
            text = itemName,
            textColor = COLOR_TITLE,
            textSize = TITLE_TEXT_SIZE,
            textAlignH = ui.ALIGNMENT.Center,
        },
    })

    local buttonStartY = WINDOW_PADDING + TITLE_HEIGHT

    local buttons = {
        { label = takeLabel, color = takeColor, action = 'take' },
        { label = "Drop", color = COLOR_NORMAL, action = 'drop' },
    }

    for i, btn in ipairs(buttons) do
        local yPos = buttonStartY + ((i - 1) * (BTN_HEIGHT + BTN_SPACING))

        local buttonLayout = {
            type = ui.TYPE.Widget,
            props = {
                position = v2(WINDOW_PADDING, yPos),
                size = v2(BTN_WIDTH, BTN_HEIGHT),
            },
            content = ui.content {}
        }

        local buttonData = { background = nil, focused = false }
        table.insert(buttonElements, buttonData)

        windowElement.layout.content:add(buttonLayout)

        local bgElement = {
            name = 'background',
            type = ui.TYPE.Image,
            props = {
                relativeSize = v2(1, 1),
                resource = ui.texture { path = 'white' },
                color = COLOR_BG,
                alpha = 0.85,
            },
        }
        buttonData.background = bgElement
        buttonLayout.content:add(bgElement)

        buttonLayout.content:add({
            name = 'text',
            type = ui.TYPE.Text,
            props = {
                relativePosition = v2(0.5, 0.5),
                anchor = v2(0.5, 0.5),
                text = btn.label,
                textColor = btn.color,
                textSize = TEXT_SIZE,
                textAlignH = ui.ALIGNMENT.Center,
                textAlignV = ui.ALIGNMENT.Center,
            },
        })

        local action = btn.action
        buttonLayout.content:add({
            name = 'clickbox',
            type = ui.TYPE.Widget,
            props = {
                relativeSize = v2(1, 1),
            },
            events = {
                mouseClick = async:callback(function()
                    closeMenu(action)
                end),
                focusGain = async:callback(function()
                    buttonData.focused = true
                    bgElement.props.color = COLOR_HOVER
                    if windowElement then windowElement:update() end
                end),
                focusLoss = async:callback(function()
                    buttonData.focused = false
                    bgElement.props.color = COLOR_BG
                    if windowElement then windowElement:update() end
                end),
            }
        })
    end

    windowElement:update()
end

function menu.isOpen()
    return windowElement ~= nil
end

function menu.cancel()
    if windowElement then
        closeMenu('cancel')
    end
end

return menu

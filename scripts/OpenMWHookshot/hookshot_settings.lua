---@omw-context player

--[[
    hookshot_settings.lua
    Settings registration, reactive access, and debug utilities for hookshot mod.

    All settings are accessed via function calls that read from storage live,
    so changes in the settings menu take effect immediately without reloadlua.
]]--

local interfaces = require('openmw.interfaces')
local storage = require('openmw.storage')
local input = require('openmw.input')
local util = require('openmw.util')
local vfs = require('openmw.vfs')
local types = require('openmw.types')
local self = require('openmw.self')

local settings = {}

-- ==============================================
-- MOD METADATA
-- ==============================================
settings.MOD_VERSION = "0.4.3-beta"

-- ==============================================
-- EQUIPMENT GATES (GLOVE + PER-FEATURE UNLOCKS)
-- ==============================================
-- Each gate is a LIST of recordIds; equipping ANY id in a list satisfies
-- that gate. Ids are compared case-insensitively.
--
-- GLOVE_RECORD_IDS is the base gate: without one of these equipped the
-- hookshot can't be drawn at all. Both ids below ship in Hookshot.omwaddon
-- (dbs_hookshot_ar is the ARMO "Hookshot", dbs_hookshot is the CLOT
-- "Hook shot") - previously only the ARMO passed the gate, so the
-- clothing variant silently did nothing.
settings.GLOVE_RECORD_IDS = {
    "dbs_hookshot_adv",
    "dbs_hookshot_item",
    "dbs_hs_mandalore",
    "dbs_hookshot_ar",
}

-- ITEM_TARGET_RECORD_IDS gates the item-targeting feature specifically:
-- reticle lock-on and pull for carriable items. Add the recordId(s) of
-- whatever upgraded glove / focus / ring should unlock telekinetic pull,
-- e.g. { "dbs_hookshot_ar_mk2" }.
--
-- EMPTY LIST = INHERIT THE BASE GATE. Leaving this empty preserves the
-- pre-gate behaviour (any hookshot can pull items) so upgrading the mod
-- doesn't silently remove a working feature. Populate it to lock the
-- feature behind a specific item.
settings.ITEM_TARGET_RECORD_IDS = {}

-- Builds a lookup set of every equipped recordId, lowercased, in ONE pass
-- over the equipment table (~12 entries, no raycasts, no iteration over
-- nearby objects). All gates below read from this one set, so adding a
-- fourth or fifth gate costs nothing extra at the call site.
local function equippedRecordIdSet(actor)
    local equipped = {}
    local equipment = types.Actor.equipment(actor or self)
    for _, item in pairs(equipment) do
        if item and item.recordId then
            equipped[item.recordId:lower()] = true
        end
    end
    return equipped
end

local function anyEquipped(equipped, recordIds)
    for _, id in ipairs(recordIds) do
        if equipped[id:lower()] then
            return true
        end
    end
    return false
end

-- Resolves EVERY gate from a single equipment scan. Returns a plain table
-- so call sites can cache it for the duration of a draw.
--
-- Deliberately NOT wired into onUpdate/onFrame: call this from input-
-- triggered code (the HookshotActivate handler and fireHookshot) so the
-- cost is paid once per key press instead of every frame. See player.lua's
-- refreshCapabilities() for the call sites.
function settings.capabilities(actor)
    local equipped = equippedRecordIdSet(actor)
    local hasGlove = anyEquipped(equipped, settings.GLOVE_RECORD_IDS)

    -- An empty unlock list means "no extra requirement beyond the glove".
    local itemTargeting
    if #settings.ITEM_TARGET_RECORD_IDS == 0 then
        itemTargeting = hasGlove
    else
        itemTargeting = hasGlove and anyEquipped(equipped, settings.ITEM_TARGET_RECORD_IDS)
    end

    return {
        glove = hasGlove,
        itemTargeting = itemTargeting,
    }
end

-- Kept for compatibility with any existing call sites.
function settings.isGloveEquipped(actor)
    return settings.capabilities(actor).glove
end

-- ==============================================
-- SOUND PATHS
-- ==============================================
settings.sounds = {
    toggle = "Sound/Hookshot_Toggle.mp3",
    set    = "Sound/Hookshot_Set.mp3",
    fire   = "Sound/Hookshot_Fire.mp3",
    target = "Sound/Hookshot_Target.mp3",
}

-- ==============================================
-- DYNAMIC ICON LOADING (like T4rg3t5)
-- ==============================================
settings.iconNames = {}
settings.RETICLE_TEXTURE_PATH = 'textures/s3/crosshair/'
settings.FALLBACK_TEXTURE_PATH = 'Textures/'
settings.useFallbackTextures = false

-- Scan for available reticle icons from T4rg3t5
for icon in vfs.pathsWithPrefix(settings.RETICLE_TEXTURE_PATH) do
    if icon:find('.dds') then
        settings.iconNames[#settings.iconNames + 1] = icon:match('.*/(.-)%.')
    end
end

-- If no T4rg3t5 icons found, scan for hookshot's own textures
if #settings.iconNames == 0 then
    settings.useFallbackTextures = true
    for icon in vfs.pathsWithPrefix(settings.FALLBACK_TEXTURE_PATH) do
        if icon:lower():find('hookshot') and icon:find('.dds') then
            settings.iconNames[#settings.iconNames + 1] = icon:match('.*/(.-)%.')
        end
    end
end

-- Ultimate fallback - hardcoded default
if #settings.iconNames == 0 then
    settings.iconNames = { 'hookshot_circle' }
end

-- ==============================================
-- SETTINGS PAGE REGISTRATION
-- ==============================================
interfaces.Settings.registerPage {
    key = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "OpenMW Hookshot",
    description = "OpenMW Hookshot Lua Mod v" .. settings.MOD_VERSION .. ". Settings changes apply immediately."
}

-- ==============================================
-- REGISTER INPUT TRIGGERS (must be done before settings that reference them)
-- ==============================================
print("[HOOKSHOT] Registering input triggers and actions...")

input.registerTrigger {
    key = 'HookshotActivate',
    l10n = 'OpenMWHookshot',
    name = '',
    description = '',
}
print("[HOOKSHOT] Registered trigger: HookshotActivate")

input.registerTrigger {
    key = 'HookshotSheath',
    l10n = 'OpenMWHookshot',
    name = '',
    description = '',
}
print("[HOOKSHOT] Registered trigger: HookshotSheath")

input.registerAction {
    key = 'HookshotRappelUp',
    l10n = 'OpenMWHookshot',
    name = '',
    description = '',
    type = input.ACTION_TYPE.Boolean,
    defaultValue = false,
}
print("[HOOKSHOT] Registered action: HookshotRappelUp")

input.registerAction {
    key = 'HookshotRappelDown',
    l10n = 'OpenMWHookshot',
    name = '',
    description = '',
    type = input.ACTION_TYPE.Boolean,
    defaultValue = false,
}
print("[HOOKSHOT] Registered action: HookshotRappelDown")

input.registerAction {
    key = 'HookshotRappelRelease',
    l10n = 'OpenMWHookshot',
    name = '',
    description = '',
    type = input.ACTION_TYPE.Boolean,
    defaultValue = false,
}
print("[HOOKSHOT] Registered action: HookshotRappelRelease")

print("[HOOKSHOT] All triggers and actions registered")

-- ==============================================
-- BASIC SETTINGS
-- ==============================================
interfaces.Settings.registerGroup {
    key = "Settings_OpenMW_Hookshot_Basic",
    page = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "Basic Settings",
    description = "Core hookshot configuration",
    permanentStorage = true,
    order = 0,
    settings = {
        { key = "HOOKSHOT_BINDING", renderer = "inputBinding", name = "Draw/Sheathe Key",
          argument = { key = 'HookshotActivate', type = 'trigger' },
          default = 'z',
          description = 'Key to draw and sheathe the hookshot. Fire is bound to the base game Attack key while drawn.'},
        { key = "SHEATH_BINDING", renderer = "inputBinding", name = "Sheath Key (secondary)",
          argument = { key = 'HookshotSheath', type = 'trigger' },
          default = 'x',
          description = 'Optional second key to force-sheathe the hookshot, in addition to the Draw/Sheathe key above.'},
        { key = "MAX_HOOKSHOT_RANGE", renderer = "number", name = "Max Range", default = 2000,
          argument = { min = 500, max = 5000, integer = true },
          description = 'Maximum range for hookshot to have effect' },
        { key = "PULL_SPD", renderer = "number", name = "Pull Speed", default = 2000,
          argument = { min = 1000, max = 6000, integer = true },
          description = 'Speed per second to pull targets/player' },
        { key = "HOOK_TRAVEL_SPEED", renderer = "number", name = "Hook Travel Speed", default = 4000,
          argument = { min = 1000, max = 12000, integer = true },
          description = 'Speed (game units/sec) at which the hook tip travels to its target before pulling begins.' },
        { key = "RAPPEL_CLIMB_SPD", renderer = "number", name = "Rappel Climb Speed", default = 400,
          argument = { min = 100, max = 2000, integer = true },
          description = 'Vertical speed (units/sec) while ascending/descending the rope' },
        { key = "RAPPEL_FUN_MODE", renderer = "checkbox", name = "Rappel Fun Mode", default = false,
          description = 'When enabled, allows rappelling from any elevated surface with enough clearance below (walls, high platforms). When disabled, only ceilings allow hanging.' },
        { key = "MIN_RAPPEL_CLEARANCE", renderer = "number", name = "Min Rappel Clearance", default = 380,
          argument = { min = 200, max = 1000, integer = true },
          description = 'Minimum clearance below surface to allow rappelling (Fun Mode only)' },
        { key = "DEBUG_MODE", renderer = "checkbox", name = "Debug Mode", default = false,
          description = 'Enable debug print statements'},
    }
}

-- ==============================================
-- GRAPPLE HANDOFF SETTINGS
-- ==============================================
-- The last stretch of a non-rappel grapple is deliberately NOT teleported.
-- The drag aims slightly above the landing point and releases short of it,
-- letting the engine's own movement/gravity carry the player the rest of
-- the way. That keeps the mod out of the collision solver at exactly the
-- moment it's most likely to shove the player through geometry, and leaves
-- the final approach visible to other movement mods.
interfaces.Settings.registerGroup {
    key = "Settings_OpenMW_Hookshot_Handoff",
    page = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "Grapple Handoff",
    description = "Controls how the grapple drag ends and hands off to normal movement. Set either value to 0 to restore the old drag-all-the-way behaviour.",
    permanentStorage = true,
    order = 4,
    settings = {
        { key = "HANDOFF_RISE", renderer = "number", name = "Approach Height", default = 55,
          argument = { min = 0, max = 150, integer = true },
          description = 'How far above the landing point the drag aims, in game units. Produces an arc that comes in over the target instead of straight at it. 0 disables.' },
        { key = "HANDOFF_DISTANCE", renderer = "number", name = "Release Distance", default = 55,
          argument = { min = 0, max = 150, integer = true },
          description = 'How far short of the aim point the drag releases, in game units. The remaining distance is covered by a jump and normal air movement. 0 disables.' },
    }
}

-- ==============================================
-- RAPPEL CONTROL SETTINGS
-- ==============================================
interfaces.Settings.registerGroup {
    key = "Settings_OpenMW_Hookshot_Rappel_V4",
    page = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "Rappel Controls",
    description = "Optional additional keybindings for rappelling. W/S/Space always work as defaults.",
    permanentStorage = true,
    order = 1,
    settings = {
        {
            key = "RAPPEL_UP_BINDING_V4",
            renderer = "inputBinding",
            name = "Ascend Key",
            argument = { key = 'HookshotRappelUp', type = 'action' },
            default = 'j',
            description = 'Additional key to climb up the rope (W always works)'
        },
        {
            key = "RAPPEL_DOWN_BINDING_V4",
            renderer = "inputBinding",
            name = "Descend Key",
            argument = { key = 'HookshotRappelDown', type = 'action' },
            default = 'k',
            description = 'Additional key to descend the rope (S always works)'
        },
        {
            key = "RAPPEL_RELEASE_BINDING_V4",
            renderer = "inputBinding",
            name = "Release Key",
            argument = { key = 'HookshotRappelRelease', type = 'action' },
            default = 'l',
            description = 'Additional key to release and drop (Space always works)'
        },
    }
}

-- ==============================================
-- RETICLE APPEARANCE SETTINGS
-- ==============================================
interfaces.Settings.registerGroup {
    key = "Settings_OpenMW_Hookshot_Reticle",
    page = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "Reticle Appearance",
    description = "Customize the targeting reticle",
    permanentStorage = true,
    order = 2,
    settings = {
        { key = "RETICLE_ICON", renderer = "select", name = "Reticle Icon", default = 'starburst',
          argument = { items = settings.iconNames },
          description = 'Icon style for the targeting reticle' },
        { key = "RETICLE_IDLE_SIZE", renderer = "number", name = "Idle Size", default = 24,
          argument = { min = 8, max = 64, integer = true },
          description = 'Reticle size when no target (smaller = subtle)' },
        { key = "RETICLE_MIN_SIZE", renderer = "number", name = "Min Target Size", default = 32,
          argument = { min = 16, max = 128, integer = true },
          description = 'Minimum reticle size when targeting (at max distance)' },
        { key = "RETICLE_MAX_SIZE", renderer = "number", name = "Max Target Size", default = 96,
          argument = { min = 32, max = 256, integer = true },
          description = 'Maximum reticle size when targeting (at min distance)' },
        { key = "RETICLE_MIN_DISTANCE", renderer = "number", name = "Min Distance", default = 100,
          argument = { min = 50, max = 500, integer = true },
          description = 'Distance at which reticle reaches maximum size' },
        { key = "RETICLE_MAX_DISTANCE", renderer = "number", name = "Max Distance", default = 2000,
          argument = { min = 500, max = 5000, integer = true },
          description = 'Distance at which reticle reaches minimum size' },
        { key = "ENABLE_LOCK_ANIMATION", renderer = "checkbox", name = "Lock-on Animation", default = true,
          description = 'Enable pulse animation when target is acquired' },
    }
}

-- ==============================================
-- RETICLE COLOR SETTINGS
-- ==============================================
interfaces.Settings.registerGroup {
    key = "Settings_OpenMW_Hookshot_Colors",
    page = "OpenMWHookshotPg",
    l10n = "OpenMWHookshot",
    name = "Reticle Colors",
    description = "Color coding by target type",
    permanentStorage = true,
    order = 3,
    settings = {
        { key = "COLOR_NO_TARGET", renderer = "color", name = "No Target",
          default = util.color.hex('666666'),
          description = 'Color when no valid target (idle)' },
        { key = "COLOR_FLOOR", renderer = "color", name = "Floor/Ground",
          default = util.color.hex('00ff80'),
          description = 'Color when targeting floor or walkable surface' },
        { key = "COLOR_WALL", renderer = "color", name = "Wall",
          default = util.color.hex('0080ff'),
          description = 'Color when targeting a wall' },
        { key = "COLOR_CEILING", renderer = "color", name = "Ceiling (Hang Point)",
          default = util.color.hex('b300ff'),
          description = 'Color when targeting ceiling (can hang)' },
        { key = "COLOR_RAPPEL", renderer = "color", name = "Rappel Point (Fun Mode)",
          default = util.color.hex('ff00ff'),
          description = 'Color when targeting a rappel-eligible surface (Fun Mode only)' },
        { key = "COLOR_ENEMY", renderer = "color", name = "Enemy/NPC",
          default = util.color.hex('ff3300'),
          description = 'Color when targeting an enemy or NPC' },
        { key = "COLOR_ITEM", renderer = "color", name = "Grabbable Item",
          default = util.color.hex('ffcc00'),
          description = 'Color when targeting a grabbable item' },
    }
}

-- ==============================================
-- STORAGE SECTIONS (created once, used by accessors)
-- ==============================================
local basicSection = storage.playerSection("Settings_OpenMW_Hookshot_Basic")
local reticleSection = storage.playerSection("Settings_OpenMW_Hookshot_Reticle")
local colorSection = storage.playerSection("Settings_OpenMW_Hookshot_Colors")
local handoffSection = storage.playerSection("Settings_OpenMW_Hookshot_Handoff")

-- ==============================================
-- REACTIVE ACCESSORS
-- ==============================================
-- Each call reads live from storage (just a hash table lookup).

-- Basic settings
function settings.maxRange()           return basicSection:get("MAX_HOOKSHOT_RANGE") end
function settings.pullSpeed()          return basicSection:get("PULL_SPD") end
function settings.hookTravelSpeed()    return basicSection:get("HOOK_TRAVEL_SPEED") or 4000 end
function settings.rappelClimbSpeed()   return basicSection:get("RAPPEL_CLIMB_SPD") end
function settings.rappelFunMode()      return basicSection:get("RAPPEL_FUN_MODE") end
function settings.minRappelClearance() return basicSection:get("MIN_RAPPEL_CLEARANCE") end
function settings.debugMode()          return basicSection:get("DEBUG_MODE") end

-- Handoff settings
function settings.handoffRise()        return handoffSection:get("HANDOFF_RISE") or 0 end
function settings.handoffDistance()    return handoffSection:get("HANDOFF_DISTANCE") or 0 end

-- Reticle settings
function settings.reticleIcon()        return reticleSection:get("RETICLE_ICON") end
function settings.reticleIdleSize()    return reticleSection:get("RETICLE_IDLE_SIZE") end
function settings.reticleMinSize()     return reticleSection:get("RETICLE_MIN_SIZE") end
function settings.reticleMaxSize()     return reticleSection:get("RETICLE_MAX_SIZE") end
function settings.reticleMinDistance()  return reticleSection:get("RETICLE_MIN_DISTANCE") end
function settings.reticleMaxDistance()  return reticleSection:get("RETICLE_MAX_DISTANCE") end
function settings.lockAnimation()      return reticleSection:get("ENABLE_LOCK_ANIMATION") end

-- Color accessor — takes a target type string, returns the corresponding color
local COLOR_KEYS = {
    none    = "COLOR_NO_TARGET",
    floor   = "COLOR_FLOOR",
    wall    = "COLOR_WALL",
    ceiling = "COLOR_CEILING",
    rappel  = "COLOR_RAPPEL",
    enemy   = "COLOR_ENEMY",
    item    = "COLOR_ITEM",
}

function settings.color(targetType)
    local key = COLOR_KEYS[targetType or "none"]
    if key then
        return colorSection:get(key)
    end
    return colorSection:get("COLOR_NO_TARGET")
end

-- ==============================================
-- DEBUG PRINT
-- ==============================================
function settings.debugPrint(...)
    if basicSection:get("DEBUG_MODE") then
        print("[HOOKSHOT DEBUG]", ...)
    end
end

return settings

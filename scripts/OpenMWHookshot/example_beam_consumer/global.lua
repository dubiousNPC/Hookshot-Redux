---@omw-context global

--[[
    example_beam_consumer/global.lua

    Global-side rope renderer for the updateRope/endRope interface in
    example_beam_consumer/player.lua.

    LIFECYCLE CHOICE. The rope is drawn as a SHORT SELF-EXPIRING beam under
    a stable per-player beam id, re-armed by every ROPE_UPDATE. That gives
    three things a persistent beam wouldn't:

      * The rope never outlives the mod. If the player script stops
        updating for any reason - reloadlua, a script error, cell change,
        the player state machine taking a path that forgets to retract -
        the rope fades on its own within ROPE_DURATION instead of hanging
        in the world forever.
      * Retraction doesn't depend on a "remove" method existing. endRope
        tries one, but a provider that doesn't expose it still ends the
        rope correctly, just with a fade instead of a cut.
      * Nothing has to survive a save/load, because a rope in flight is
        transient gameplay state that the player script rebuilds anyway.

    The upsert path is used rather than adapter:emit(), because emit mints
    a NEW beam id per call - refreshing at 7-60 Hz through emit would stack
    up dozens of overlapping ropes.
]]--

local world = require("openmw.world")

local BeamFXAdapter =
    require("scripts.OpenMWHookshot.example_beam_consumer.beamfx_adapter")
local events = require("scripts.OpenMWHookshot.example_beam_consumer.events")

-- ==============================================
-- ROPE APPEARANCE
-- ==============================================
-- A hand-built upsert bypasses the provider's own preset resolution, so
-- the appearance is spelled out here. The material still starts from the
-- understated "fishing_line" look, but uses a rope-sized world radius and a
-- stronger screen-space floor so it remains continuous and readable at range.
local ROPE_APPEARANCE = {
    style = "filament",
    radius = 0.50,
    minPixelWidth = 1.75,
    outerColor = { 0.36, 0.43, 0.50 },
    coreColor = { 0.78, 0.84, 0.90 },
    baseColor = { 0.11, 0.13, 0.15 },
    coreRatio = 0.35,
    intensity = 0.45,
    opacity = 0.80,
    baseOpacity = 0.35,
    depthSoftness = 1,
    fogInfluence = 1,
}

-- Must stay comfortably above the player side's KEEPALIVE_INTERVAL (0.15)
-- or the rope flickers between refreshes.
local ROPE_DURATION = 0.40
local ROPE_FADE = 0.12

-- ==============================================
-- ADAPTER
-- ==============================================
local visuals

-- A rope in flight is transient: the player script republishes it from
-- live gameplay state on the next frame, so there is nothing to rebuild
-- after a load or a provider epoch change. Returning true tells the
-- adapter reconstruction succeeded and shouldn't be retried.
local function reconstructPersistentVisuals(adapter, reason)
    return true
end

visuals = BeamFXAdapter.new({
    producerId = "dbs.sahjop.hookshot",
    displayName = "Dubious_SahJop - HookShot",
    reconstruct = reconstructPersistentVisuals,
    retryMinimumSeconds = 0.25,
    retryMaximumSeconds = 5,
    warningIntervalSeconds = 30,
})

-- Set once if the provider turns out not to expose "remove", so endRope
-- stops asking and the adapter stops logging about it. Ropes still end
-- correctly via expiry.
local removeUnsupported = false

-- BeamFX keeps a beam generation's space immutable. Remember the active
-- generation's space so a rare interior/worldspace transition can remove and
-- recreate the same stable rope id instead of waiting for transient expiry.
local activeSpaceByBeamId = {}

-- ==============================================
-- VALIDATION
-- ==============================================
local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function validPosition(value)
    return type(value) == "table"
        and finiteNumber(value.x)
        and finiteNumber(value.y)
        and finiteNumber(value.z)
end

local function isPlayer(object)
    if object == nil then
        return false
    end
    -- world.players is a core engine list; indexing it and taking its
    -- length cannot raise, so neither read needs a guard.
    local players = world.players
    for index = 1, #players do
        if players[index] == object then
            return true
        end
    end
    return false
end

local function objectCell(object)
    -- object is already confirmed to be a player by isPlayer() above, so
    -- reading .cell is a plain GameObject field access.
    return object.cell
end

-- ==============================================
-- BEAM IDENTITY
-- ==============================================
-- One rope per player, keyed by a stable id so repeated upserts update the
-- same beam instead of spawning new ones. Multiplayer-safe by construction
-- even though vanilla OpenMW only ever has one player.
local function beamIdFor(sender)
    local id = sender.id
    if type(id) ~= "string" then
        return "dbs_hookshot_rope"
    end
    return "dbs_hookshot_rope_" .. id
end

local function ropeSpec(spaceKey, from, to)
    local segment = {
        startPos = from,
        endPos = to,
    }
    for field, value in pairs(ROPE_APPEARANCE) do
        segment[field] = value
    end

    return {
        spaceKey = spaceKey,
        lifecycle = {
            mode = "transient",
            duration = ROPE_DURATION,
            fadeDuration = ROPE_FADE,
        },
        audience = { mode = "same_space" },
        priority = "normal",
        maxSegments = 1,
        segments = { segment },
    }
end

-- ==============================================
-- EVENT HANDLERS
-- ==============================================
local function onRopeUpdate(request)
    if type(request) ~= "table"
        or not isPlayer(request.sender)
        or not validPosition(request.from)
        or not validPosition(request.to)
    then
        return
    end

    local cell = objectCell(request.sender)
    if cell == nil then
        return
    end

    local spaceKey = visuals:spaceKeyForCell(cell)
    if spaceKey == nil then
        return
    end

    local beamId = beamIdFor(request.sender)
    local previousSpaceKey = activeSpaceByBeamId[beamId]
    if previousSpaceKey ~= nil
        and previousSpaceKey ~= spaceKey
        and not removeUnsupported
    then
        local removed, removeErr = visuals:invoke("remove", beamId, "space_changed")
        if removed == nil and removeErr == "unsupported_api" then
            removeUnsupported = true
        end
    end

    -- Visual-only, best effort. No gameplay result may depend on this
    -- succeeding, so the failure is swallowed rather than propagated.
    local result = visuals:invoke(
        "upsert",
        beamId,
        ropeSpec(spaceKey, request.from, request.to)
    )
    if result ~= nil then
        activeSpaceByBeamId[beamId] = spaceKey
    end
end

local function onRopeEnd(request)
    if type(request) ~= "table" or not isPlayer(request.sender) then
        return
    end

    local beamId = beamIdFor(request.sender)
    activeSpaceByBeamId[beamId] = nil

    if removeUnsupported then
        return
    end

    local result, err = visuals:invoke("remove", beamId)
    if result == nil and err == "unsupported_api" then
        removeUnsupported = true
    end
end

local function onUpdate()
    visuals:update()
end

local function onLoad()
    activeSpaceByBeamId = {}
    visuals:reset("load")
end

local function onNewGame()
    activeSpaceByBeamId = {}
    visuals:reset("new_game")
end

return {
    eventHandlers = {
        [events.ROPE_UPDATE] = onRopeUpdate,
        [events.ROPE_END] = onRopeEnd,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
}

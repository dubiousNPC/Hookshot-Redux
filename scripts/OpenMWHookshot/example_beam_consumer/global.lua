---@omw-context global

-- Global rope renderer. One retained path per player under a short persistent
-- lease: replacePathPoints renews it, so a rope cannot outlive the mod.

local world = require("openmw.world")

local BeamFXAdapter =
    require("scripts.OpenMWHookshot.example_beam_consumer.beamfx_adapter")
local events = require("scripts.OpenMWHookshot.example_beam_consumer.events")

-- ==============================================
-- ROPE APPEARANCE
-- ==============================================
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

-- Fixed topology: replacePathPoints requires this exact count every call.
local ROPE_POINTS = 2

-- Must stay above player.lua's KEEPALIVE_INTERVAL (0.15).
local ROPE_LEASE = 0.5

-- Legacy transient fallback, used only when the provider has no path methods.
local ROPE_DURATION = 0.40
local ROPE_FADE = 0.12

-- ==============================================
-- ADAPTER
-- ==============================================
local visuals

local spaceKeyByCell = setmetatable({}, { __mode = "k" })
local beamIdBySender = setmetatable({}, { __mode = "k" })

-- spaceKey and point count per live beam id.
local pathState = {}

local removeUnsupported = false
local pathUnsupported = false

local function clearDerivedCaches()
    spaceKeyByCell = setmetatable({}, { __mode = "k" })
    beamIdBySender = setmetatable({}, { __mode = "k" })
end

-- A new provider generation can issue different space keys.
local function reconstructPersistentVisuals(adapter, reason)
    clearDerivedCaches()
    pathState = {}
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
    local players = world.players
    if players[1] == object then
        return true
    end
    for index = 2, #players do
        if players[index] == object then
            return true
        end
    end
    return false
end

local function objectCell(object)
    return object.cell
end

-- ==============================================
-- BEAM IDENTITY
-- ==============================================
local function beamIdFor(sender)
    local cached = beamIdBySender[sender]
    if cached then return cached end

    local id = sender.id
    local beamId
    if type(id) ~= "string" then
        beamId = "dbs_hookshot_rope"
    else
        beamId = "dbs_hookshot_rope_" .. id
    end
    beamIdBySender[sender] = beamId
    return beamId
end

-- ==============================================
-- GEOMETRY
-- ==============================================
-- from/to arrive fresh per event, so they can be handed over directly.
local function ropePoints(from, to)
    if ROPE_POINTS == 2 then
        return { from, to }
    end

    local points = { from }
    local last = ROPE_POINTS - 1
    for i = 1, last - 1 do
        local t = i / last
        points[i + 1] = {
            x = from.x + (to.x - from.x) * t,
            y = from.y + (to.y - from.y) * t,
            z = from.z + (to.z - from.z) * t,
        }
    end
    points[ROPE_POINTS] = to
    return points
end

local function pathSpec(spaceKey, points)
    return {
        spaceKey = spaceKey,
        lifecycle = { mode = "persistent", leaseSeconds = ROPE_LEASE },
        audience = { mode = "same_space" },
        priority = "normal",
        maxSegments = ROPE_POINTS - 1,
        points = points,
        segmentDefaults = ROPE_APPEARANCE,
    }
end

-- Legacy single-segment transient spec.
local function ropeSpec(spaceKey, from, to)
    local segment = {
        startPos = from,
        endPos = to,
        style = ROPE_APPEARANCE.style,
        radius = ROPE_APPEARANCE.radius,
        minPixelWidth = ROPE_APPEARANCE.minPixelWidth,
        outerColor = ROPE_APPEARANCE.outerColor,
        coreColor = ROPE_APPEARANCE.coreColor,
        baseColor = ROPE_APPEARANCE.baseColor,
        coreRatio = ROPE_APPEARANCE.coreRatio,
        intensity = ROPE_APPEARANCE.intensity,
        opacity = ROPE_APPEARANCE.opacity,
        baseOpacity = ROPE_APPEARANCE.baseOpacity,
        depthSoftness = ROPE_APPEARANCE.depthSoftness,
        fogInfluence = ROPE_APPEARANCE.fogInfluence,
    }

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

local function removeBeam(beamId, reason)
    pathState[beamId] = nil
    if removeUnsupported then return end

    local result, err = visuals:invoke("remove", beamId, reason)
    if result == nil and err == "unsupported_api" then
        removeUnsupported = true
    end
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

    local spaceKey = spaceKeyByCell[cell]
    if spaceKey == nil then
        spaceKey = visuals:spaceKeyForCell(cell)
        if spaceKey == nil then
            return
        end
        spaceKeyByCell[cell] = spaceKey
    end

    local beamId = beamIdFor(request.sender)
    local live = pathState[beamId]

    if live and live.spaceKey ~= spaceKey then
        removeBeam(beamId, "space_changed")
        live = nil
    end

    if pathUnsupported then
        if visuals:invoke("upsert", beamId, ropeSpec(spaceKey, request.from, request.to)) then
            pathState[beamId] = { spaceKey = spaceKey, points = 2 }
        end
        return
    end

    local points = ropePoints(request.from, request.to)

    if live and live.points == ROPE_POINTS then
        if visuals:invoke("replacePathPoints", beamId, points) then
            return
        end
        -- Provenance lost or count changed; rebuild below.
        pathState[beamId] = nil
    end

    local result, err = visuals:invoke("upsertPath", beamId, pathSpec(spaceKey, points))
    if result ~= nil then
        pathState[beamId] = { spaceKey = spaceKey, points = ROPE_POINTS }
    elseif err == "unsupported_api" then
        pathUnsupported = true
    end
end

local function onRopeEnd(request)
    if type(request) ~= "table" or not isPlayer(request.sender) then
        return
    end
    removeBeam(beamIdFor(request.sender), "retracted")
end

local function onUpdate()
    visuals:update()
end

local function onLoad()
    pathState = {}
    clearDerivedCaches()
    visuals:reset("load")
end

local function onNewGame()
    pathState = {}
    clearDerivedCaches()
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

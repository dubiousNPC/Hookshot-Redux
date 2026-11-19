---@omw-context global

-- Global rope renderer. One retained path per player under a short persistent
-- lease: replacePathPoints renews it, so a rope cannot outlive the mod.

local world = require("openmw.world")
local vfs = require("openmw.vfs")

local BeamFXAdapter =
    require("scripts.OpenMWHookshot.example_beam_consumer.beamfx_adapter")
local events = require("scripts.OpenMWHookshot.example_beam_consumer.events")

-- ==============================================
-- ROPE APPEARANCE
-- ==============================================
-- DARKENED 2026-11-12. The rope read as a bright pale filament against dark
-- interiors; every colour channel is scaled to roughly 0.45 of what it was and
-- the emissive intensity with it, so the rope reads as cord rather than light.
-- Opacity is untouched -- the rope should still be solid, just not glowing.
local ROPE_APPEARANCE = {
    style = "filament",
    radius = 0.50,
    minPixelWidth = 1.75,
    outerColor = { 0.16, 0.19, 0.23 },
    coreColor = { 0.34, 0.37, 0.41 },
    baseColor = { 0.05, 0.06, 0.07 },
    coreRatio = 0.35,
    intensity = 0.20,
    opacity = 0.80,
    baseOpacity = 0.30,
    depthSoftness = 1,
    fogInfluence = 1,
}

-- Fixed topology: replacePathPoints requires this exact count every call, so
-- the taut rope and the slack one must agree on it. 12 points is enough for a
-- readable catenary and still one short path packet.
local ROPE_POINTS = 12

-- ==============================================
-- SLACK ROPE (delayed firing, tethered)
-- ==============================================
-- Only the delayed-firing tether hangs: the dart is planted, the player walks
-- around, and a dead-straight line between shoulder and anchor looks wrong.
-- Every other rope state is under tension and stays straight.
--
-- "Looser" here means three things together, not just more rope:
--   slack                 rest length as a multiple of the straight distance
--   constraintIterations  fewer passes leaves the chain softer and ropier
--   drag                  settles the swing instead of letting it ring
local SLACK_CHAIN = {
    segmentCount         = ROPE_POINTS - 1,
    slack                = 1.18,
    fixedStep            = 1 / 60,
    maxSubsteps          = 4,
    constraintIterations = 3,
    acceleration         = { x = 0, y = 0, z = -600 },
    drag                 = 1.2,
}

-- Re-seed rather than drag the chain across a jump this big.
local SLACK_RESEED_DISTANCE = 600

-- BeamFX is optional: without it the slack rope is drawn straight. Absence is
-- tested with a file check, not a pcall, so a broken verlet.lua still raises.
local VERLET_PATH = "scripts/beamfx/shared/verlet.lua"
local verletModule = nil
local function verlet()
    if verletModule == nil then
        verletModule = vfs.fileExists(VERLET_PATH)
            and require("scripts.beamfx.shared.verlet") or false
    end
    return verletModule or nil
end

-- chain + last pins, per live beam id
local ropeSim = {}

local function distanceBetween(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function dropSim(beamId)
    ropeSim[beamId] = nil
end

-- Returns the chain's points, or nil to fall back to the straight line.
local function slackPoints(beamId, from, to)
    local v = verlet()
    if v == nil then return nil end

    local sim = ropeSim[beamId]
    local reseed = sim == nil
        or distanceBetween(sim.from, from) > SLACK_RESEED_DISTANCE
        or distanceBetween(sim.to, to) > SLACK_RESEED_DISTANCE

    if reseed then
        local chain = v.newChain({
            startPos             = from,
            endPos               = to,
            segmentCount         = SLACK_CHAIN.segmentCount,
            slack                = SLACK_CHAIN.slack,
            fixedStep            = SLACK_CHAIN.fixedStep,
            maxSubsteps          = SLACK_CHAIN.maxSubsteps,
            constraintIterations = SLACK_CHAIN.constraintIterations,
            acceleration         = SLACK_CHAIN.acceleration,
            drag                 = SLACK_CHAIN.drag,
        })
        if chain == nil then return nil end
        sim = { chain = chain }
        ropeSim[beamId] = sim
    end

    local chain = sim.chain
    -- The shoulder moves with the player and the dart does not, but pin both:
    -- a planted dart can still ride a moving platform.
    if not chain:pin(1, from) then return nil end
    if not chain:pin(chain:pointCount(), to) then return nil end
    sim.from, sim.to = from, to

    local points = chain:points()
    if type(points) ~= "table" or #points ~= ROPE_POINTS then return nil end
    return points
end

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
    ropeSim = {}
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
    ropeSim[beamId] = nil
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

    -- Delayed firing, tethered: let the rope hang. Anything else is taut.
    local points
    if request.slack == true then
        points = slackPoints(beamId, request.from, request.to)
    else
        dropSim(beamId)
    end
    points = points or ropePoints(request.from, request.to)

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

-- The chain is stepped here, not in onRopeUpdate: the player only sends a rope
-- update every KEEPALIVE_INTERVAL (0.15 s) or when it moves far enough, and a
-- rope that only solved on those frames would jerk rather than swing.
local function stepSlackChains(dt)
    if dt == nil or dt <= 0 then return end
    for beamId, sim in pairs(ropeSim) do
        local live = pathState[beamId]
        if live == nil or live.points ~= ROPE_POINTS then
            ropeSim[beamId] = nil
        else
            sim.chain:update(dt)
            local points = sim.chain:points()
            if type(points) == "table" and #points == ROPE_POINTS then
                if not visuals:invoke("replacePathPoints", beamId, points) then
                    pathState[beamId] = nil
                    ropeSim[beamId] = nil
                end
            end
        end
    end
end

local function onUpdate(dt)
    stepSlackChains(dt)
    visuals:update()
end

local function onLoad()
    pathState = {}
    ropeSim = {}
    clearDerivedCaches()
    visuals:reset("load")
end

local function onNewGame()
    pathState = {}
    ropeSim = {}
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

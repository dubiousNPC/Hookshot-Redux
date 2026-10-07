---@omw-context player
-- Player-side rope interface: I.DubiousHookshotVisuals.updateRope(from, to),
-- endRope(), handOrigin(). Streams endpoints to the global renderer.

local core = require("openmw.core")
local self = require("openmw.self")

local events = require("scripts.OpenMWHookshot.example_beam_consumer.events")

local U = require("scripts.OpenMWHookshot.hookshot_util")

-- ==============================================
-- UPDATE THROTTLING
-- ==============================================
-- Sends on movement, or every KEEPALIVE_INTERVAL; the global beam self-expires.
local KEEPALIVE_INTERVAL = 0.15  -- must stay under global.lua's ROPE_DURATION
local MIN_MOVE = 2.0

local rope = {
    active = false,
    lastSentAt = 0,
    lastFrom = nil,
    lastTo = nil,
}

local function resetRopeState()
    rope.active = false
    rope.lastSentAt = 0
    rope.lastFrom = nil
    rope.lastTo = nil
end

-- ==============================================
-- VALIDATION
-- ==============================================
local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

-- Plain serializable copy, or nil; a visual must never break gameplay.
local function copyPosition(value)
    if value == nil then
        return nil
    end
    local x, y, z = value.x, value.y, value.z
    if not finiteNumber(x)
        or not finiteNumber(y)
        or not finiteNumber(z)
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function movedEnough(previous, current)
    if previous == nil then
        return true
    end
    local dx = current.x - previous.x
    local dy = current.y - previous.y
    local dz = current.z - previous.z
    return (dx * dx + dy * dy + dz * dz) > (MIN_MOVE * MIN_MOVE)
end

-- ==============================================
-- PUBLIC INTERFACE
-- ==============================================
local function handOrigin()
    return U.actorShoulderOrigin(self)
end

-- Safe every frame. False only for unusable positions.
local function updateRope(from, to)
    local safeFrom = copyPosition(from)
    local safeTo = copyPosition(to)
    if safeFrom == nil or safeTo == nil then
        return false
    end

    local currentTime = core.getSimulationTime()
    local due = (currentTime - rope.lastSentAt) >= KEEPALIVE_INTERVAL
    local moved = movedEnough(rope.lastFrom, safeFrom) or movedEnough(rope.lastTo, safeTo)

    if rope.active and not due and not moved then
        return true
    end

    core.sendGlobalEvent(events.ROPE_UPDATE, {
        sender = self.object,
        from = safeFrom,
        to = safeTo,
    })

    rope.active = true
    rope.lastSentAt = currentTime
    rope.lastFrom = safeFrom
    rope.lastTo = safeTo
    return true
end

-- Idempotent.
local function endRope()
    if not rope.active then
        return
    end
    resetRopeState()
    core.sendGlobalEvent(events.ROPE_END, { sender = self.object })
end

local function onLoad()
    resetRopeState()
end

return {
    interfaceName = "DubiousHookshotVisuals",
    interface = {
        updateRope = updateRope,
        endRope = endRope,
        handOrigin = handOrigin,
    },
    engineHandlers = {
        onLoad = onLoad,
    },
}

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
    lastSlack = nil,
}

local function resetRopeState()
    rope.active = false
    rope.lastSentAt = 0
    rope.lastFrom = nil
    rope.lastTo = nil
    rope.lastSlack = nil
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
-- `opts.slack` asks the renderer to hang the rope instead of drawing it taut.
-- Only the delayed-firing tether sets it; it is optional, so a caller built
-- against the old two-argument form still works.
local function updateRope(from, to, opts)
    local safeFrom = copyPosition(from)
    local safeTo = copyPosition(to)
    if safeFrom == nil or safeTo == nil then
        return false
    end

    local slack = (type(opts) == "table" and opts.slack == true) or false

    local currentTime = core.getSimulationTime()
    local due = (currentTime - rope.lastSentAt) >= KEEPALIVE_INTERVAL
    local moved = movedEnough(rope.lastFrom, safeFrom) or movedEnough(rope.lastTo, safeTo)
    -- A flag flip has to go out even on a still frame, or the rope keeps the
    -- shape it had when the tether started.
    local flipped = rope.lastSlack ~= slack

    if rope.active and not due and not moved and not flipped then
        return true
    end

    core.sendGlobalEvent(events.ROPE_UPDATE, {
        sender = self.object,
        from = safeFrom,
        to = safeTo,
        slack = slack,
    })

    rope.active = true
    rope.lastSentAt = currentTime
    rope.lastFrom = safeFrom
    rope.lastTo = safeTo
    rope.lastSlack = slack
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

---@omw-context player

--[[
    example_beam_consumer/player.lua

    Player-side rope visuals interface, shaped to match
    HOOKSHOT_INTEGRATION_EXAMPLE.lua:

        I.DubiousHookshotVisuals.updateRope(fromPos, toPos)
        I.DubiousHookshotVisuals.endRope()
        I.DubiousHookshotVisuals.handOrigin()

    The old FIRE_HOOK interface fired once with a fixed pair of endpoints,
    which can only draw a rope frozen at the moment of firing. A hookshot
    rope has to track BOTH ends every frame - the launcher end follows the
    player's hand as they turn and move, and the far end travels toward the
    impact point while the hook is in flight - so the interface is now an
    update/end pair driven from onUpdate.
]]--

local core = require("openmw.core")
local self = require("openmw.self")
-- openmw.util / openmw.types are no longer required here: the shoulder
-- origin maths moved wholesale into hookshot_util.

local events = require("scripts.OpenMWHookshot.example_beam_consumer.events")

-- ==============================================
-- ROPE ORIGIN
-- ==============================================
-- Delegated to hookshot_util so the mod has exactly ONE definition of
-- where the rope leaves the player. player.lua measures outbound hook
-- travel from that same helper, so a second offset defined here would put
-- the rendered beam somewhere the gameplay doesn't think the hook is.
--
-- The previous local version offset upward by halfExtents.z, which is
-- HALF standing height - i.e. waist level, since actor.position is at the
-- feet. The shared helper uses 0.81 of full height, which is the right
-- shoulder. It also keeps the right/forward components proportional to
-- actor height, so it stays correct across races and scaled actors.
--
-- Still not a queried bone: there's no documented Lua call for that from a
-- local script, so it won't track a raised or lowered arm. That needs a
-- separate attach-point object.
local U = require("scripts.OpenMWHookshot.hookshot_util")

-- ==============================================
-- UPDATE THROTTLING
-- ==============================================
-- The global side keeps the rope alive with a short self-expiring beam, so
-- this has to refresh at least that often or the rope blinks out. Between
-- refreshes we only send when an endpoint has actually moved, which keeps
-- a stationary rope down to ~7 events/sec instead of one per frame.
local KEEPALIVE_INTERVAL = 0.15  -- Seconds; must stay under the global side's ROPE_DURATION
local MIN_MOVE = 0.25            -- Small epsilon keeps slow hand/rope motion visually smooth

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

-- Copies a position into a plain serializable table. Accepts anything with
-- readable x/y/z (util.vector3, or a plain table), and returns nil rather
-- than erroring on anything else - a visual must never be able to break
-- the gameplay code that calls it.
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
-- Approximate right-shoulder origin. Recomputed every call so it follows
-- the player as they turn, move, and (via the bounds query) whatever
-- race/height they are. Kept exported under the original name so any
-- existing I.DubiousHookshotVisuals.handOrigin() caller keeps working.
local function handOrigin()
    return U.actorShoulderOrigin(self)
end

-- Publishes the rope's current endpoints. Safe to call every frame.
-- Returns false if the positions were unusable, true otherwise (including
-- when the update was throttled - the caller shouldn't care).
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

    -- The payload carries only serializable positions and an object
    -- reference. In particular it does not send the player's Cell; the
    -- global side resolves that from the sender.
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

-- Retracts the rope. Idempotent, so calling it from several teardown paths
-- (released, cancelled, blocked, state reset) is fine.
local function endRope()
    if not rope.active then
        return
    end
    resetRopeState()
    core.sendGlobalEvent(events.ROPE_END, { sender = self.object })
end

local function onLoad()
    -- The global adapter resets independently. Clearing only this local
    -- throttle state guarantees the first post-load shot is published even
    -- if simulation time moved backwards.
    resetRopeState()
end

return {
    -- Other player scripts in this mod call:
    --   local I = require('openmw.interfaces')
    --   I.DubiousHookshotVisuals.updateRope(I.DubiousHookshotVisuals.handOrigin(), hookPos)
    --   I.DubiousHookshotVisuals.endRope()
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

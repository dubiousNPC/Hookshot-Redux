---@omw-context player
-- Math helpers, type checks, array helpers. No self/nearby/camera imports.

local types = require('openmw.types')
local util = require('openmw.util')

local U = {}

-- ==============================================
-- MATH UTILITIES
-- ==============================================

function U.anglesToV(pitch, yaw)
    local xzLen = math.cos(pitch)
    return util.vector3(
        xzLen * math.sin(yaw),
        xzLen * math.cos(yaw),
        math.sin(pitch)
    )
end

function U.addToVector3(v, xDiff, yDiff, zDiff)
    return util.vector3(v.x + xDiff, v.y + yDiff, v.z + zDiff)
end

function U.clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

function U.remapClamped(value, oldMin, oldMax, newMin, newMax)
    local remapped = util.remap(value, oldMin, oldMax, newMin, newMax)
    return math.max(newMin, math.min(newMax, remapped))
end

-- ==============================================
-- RIGHT SHOULDER ORIGIN (rope/beam anchor)
-- ==============================================
-- Single source of truth for the rope anchor. Static offset from the feet,
-- scaled by standing height; local frame x = right, y = forward, z = up.
local SHOULDER_RIGHT_FRACTION = 0.13
local SHOULDER_FORWARD_FRACTION = 0.05
local SHOULDER_HEIGHT_FRACTION = 0.81

function U.actorShoulderOrigin(actor)
    local bounds = types.Actor.getPathfindingAgentBounds(actor)
    local fullHeight = bounds.halfExtents.z * 2
    local yaw = actor.rotation:getYaw()
    local localOffset = util.vector3(
        fullHeight * SHOULDER_RIGHT_FRACTION,
        fullHeight * SHOULDER_FORWARD_FRACTION,
        fullHeight * SHOULDER_HEIGHT_FRACTION
    )
    return actor.position + util.transform.rotateZ(yaw) * localOffset
end

-- ==============================================
-- OBJECT TYPE CHECKING
-- ==============================================

function U.getHP(actor)
    return types.Actor.stats.dynamic.health(actor).current
end

function U.isAlive(actor)
    return U.getHP(actor) > 0
end

function U.isCarriableItem(t)
    if not t then return false end
    local isItem = types.Item.objectIsInstance(t)
    local isLight = types.Light.objectIsInstance(t)
    return isItem and not isLight
end

function U.isActor(t)
    return t and t.type and t.type.baseType == types.Actor
end

function U.isGrabbable(t)
    return U.isCarriableItem(t) or U.isActor(t)
end

-- ==============================================
-- ARRAY HELPERS
-- ==============================================

-- In-place compaction: keeps elements where fnKeep(t, i, j) returns true.
function U.arrayCompact(t, fnKeep)
    local j, n = 1, #t
    for i = 1, n do
        if fnKeep(t, i, j) then
            if i ~= j then
                t[j] = t[i]
            end
            j = j + 1
        end
    end
    table.move(t, n + 1, n + n - j + 1, j)
    return t
end

-- ==============================================
-- SHARED CONSTANTS
-- ==============================================
U.PLAYER_HEIGHT = 128

return U

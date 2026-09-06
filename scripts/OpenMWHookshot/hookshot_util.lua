---@omw-context player

--[[
    hookshot_util.lua
    Pure utility functions for hookshot mod.

    Math helpers, object type classification, and array operations.
    No side effects — no openmw.self, openmw.nearby, or openmw.camera imports.
]]--

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

function U.angleBetweenVectors(v1, v2)
    local dot = v1:dot(v2)
    local len1 = v1:length()
    local len2 = v2:length()
    if len1 == 0 or len2 == 0 then return math.pi end
    return math.acos(U.clamp(dot / (len1 * len2), -1, 1))
end

-- ==============================================
-- RIGHT SHOULDER ORIGIN (rope/beam anchor)
-- ==============================================
-- Approximate RIGHT SHOULDER world position for a given actor. Not a
-- queried bone - there is no documented Lua call for that from a local
-- script (checked against Cod3x) - so this is a tuned static offset from
-- the actor's root position/yaw, scaled by full standing height so it's
-- proportioned correctly across races/scales rather than one flat number.
-- Confirmed against Cod3x: types.Actor.getPathfindingAgentBounds(actor)
-- and actor.rotation:getYaw() are both documented, and util.transform's
-- own example doc comment uses exactly this
-- move(pos) * rotateZ(yaw) composition.
--
-- Local frame is x = right, y = forward, z = up, and actor.position sits
-- at the FEET (hookshot_physics.getBoundingData builds its cage upward
-- from position to +height, which only works feet-anchored). So the
-- height fraction is measured from the ground, and 0.81 of full standing
-- height is roughly where the shoulder joint sits on a humanoid - NOT 0.5,
-- which is waist height and is where a naive halfExtents.z offset lands.
--
-- THIS IS THE SINGLE SOURCE OF TRUTH for the rope anchor. player.lua and
-- example_beam_consumer both resolve to it, so the launch point can't
-- drift between the gameplay-side travel maths and the rendered beam.
local SHOULDER_RIGHT_FRACTION = 0.13    -- centerline-to-shoulder / full height
local SHOULDER_FORWARD_FRACTION = 0.05  -- pushes the point off the chest plane; 0 to disable
local SHOULDER_HEIGHT_FRACTION = 0.81   -- shoulder height / full height, from the ground

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

-- Retained name for existing call sites. Same function, clearer name above.
U.actorHandOrigin = U.actorShoulderOrigin

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

-- In-place array compaction: keeps elements where fnKeep returns true.
-- fnKeep(t, i, j) receives the array, source index, and destination index.
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
U.PLAYER_HEIGHT = 128  -- Standard player height for probe calculations (used by targeting + physics)

return U

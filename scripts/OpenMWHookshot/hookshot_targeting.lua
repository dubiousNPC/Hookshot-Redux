---@omw-context player

-- Raycasting, surface probes, rappel and ledge checks, target classification.

local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local orient = require('scripts.OpenMWHookshot.hookshot_orient')
local settings = require('scripts.OpenMWHookshot.hookshot_settings')
local U = require('scripts.OpenMWHookshot.hookshot_util')

local debugPrint = settings.debugPrint

local Targeting = {}

-- ==============================================
-- EQUIPMENT GATES
-- ==============================================
-- Set from player.lua on draw and fire. Permissive by default.
local capabilities = {
    itemTargeting = true,
}

function Targeting.setCapabilities(caps)
    capabilities.itemTargeting = (caps == nil) or (caps.itemTargeting ~= false)
end

-- ==============================================
-- CONSTANTS
-- ==============================================
local HOOKSHOT_PHY = nearby.COLLISION_TYPE.World
                   + nearby.COLLISION_TYPE.Door
                   + nearby.COLLISION_TYPE.HeightMap
                   + nearby.COLLISION_TYPE.Actor

-- Ledge edge detection
local PLAYER_HEIGHT = U.PLAYER_HEIGHT
local DOWNWARD_LOOK_THRESHOLD = -0.05    -- camera pitch, radians (~3 degrees down)
local LEDGE_EDGE_TOLERANCE = 64          -- max Z difference for "same surface"
local LEDGE_PROBE_CLEARANCE = 40

-- Item cone half-angle, radians (~8.6 degrees)
local ITEM_DETECTION_ANGLE_THRESHOLD = 0.15

-- ==============================================
-- CAMERA QUERY
-- ==============================================
function Targeting.getCameraDirData()
    local pos = camera.getPosition()
    local pitch = -(camera.getPitch() + camera.getExtraPitch())
    local yaw = (camera.getYaw() + camera.getExtraYaw())
    return pos, U.anglesToV(pitch, yaw), yaw, pitch
end

-- ==============================================
-- SURFACE NORMAL DETECTION
-- ==============================================
function Targeting.probeSurfaceNormal(hitPos, approachDir)
    local probeStart = hitPos - approachDir * 100
    local probeEnd = hitPos + approachDir * 100

    local result = nearby.castRay(probeStart, probeEnd, {
        collisionType = HOOKSHOT_PHY,
        ignore = self
    })

    if result.hit and result.hitNormal then
        debugPrint("Surface normal probe hit:", orient.normalToString(result.hitNormal))
        return result.hitNormal
    else
        debugPrint("Surface normal probe missed, using default up")
        return util.vector3(0, 0, 1)
    end
end

-- ==============================================
-- RAPPEL CLEARANCE CHECK
-- ==============================================
-- Clearance below the hang point (Fun Mode only).
function Targeting.checkRappelClearance(hitPos, hitNormal)
    if not settings.rappelFunMode() then
        return false
    end

    if not hitNormal then
        return false
    end

    local surfaceType = orient.classifySurface(hitNormal)

    -- Ceilings are handled by getTargetType.
    if surfaceType == "ceiling" then
        return false  -- Let normal ceiling logic handle it
    end

    if surfaceType == "floor" then
        -- Heightmap terrain is never a rappel floor: probe with a heightmap-only ray.

        local heightmapCheck = nearby.castRay(
            hitPos + util.vector3(0, 0, 50),
            hitPos - util.vector3(0, 0, 50),
            {
                collisionType = nearby.COLLISION_TYPE.HeightMap,
                ignore = self
            }
        )

        if heightmapCheck.hit then
            debugPrint("Floor rappel check: heightmap terrain detected, denying")
            return false
        end

        -- Elevated platform with an air gap below.
        local probeStart = hitPos + util.vector3(0, 0, 50)
        local probeEnd = hitPos - util.vector3(0, 0, settings.minRappelClearance() + 100)

        local result = nearby.castRay(probeStart, probeEnd, {
            collisionType = HOOKSHOT_PHY,
            ignore = self
        })

        if result.hit then
            local belowFloorStart = result.hitPos - util.vector3(0, 0, 20)
            local belowFloorEnd = belowFloorStart - util.vector3(0, 0, settings.minRappelClearance() + 50)

            local belowResult = nearby.castRay(belowFloorStart, belowFloorEnd, {
                collisionType = HOOKSHOT_PHY,
                ignore = self
            })

            if belowResult.hit then
                local clearance = (belowFloorStart - belowResult.hitPos):length()
                debugPrint("Floor rappel check: clearance below platform =", clearance, "required =", settings.minRappelClearance())
                return clearance >= settings.minRappelClearance()
            else
                debugPrint("Floor rappel check: no ground below platform, clearance OK")
                return true
            end
        else
            debugPrint("Floor rappel check: probe missed, denying")
            return false
        end

    elseif surfaceType == "wall" then
        local horizontalNormal = util.vector3(hitNormal.x, hitNormal.y, 0)
        if horizontalNormal:length() > 0.01 then
            horizontalNormal = horizontalNormal:normalize()
        else
            debugPrint("Wall rappel check: can't determine wall orientation, denying")
            return false
        end

        local playerHangPos = hitPos + horizontalNormal * 30

        local checkStart = playerHangPos
        local checkEnd = playerHangPos - util.vector3(0, 0, settings.minRappelClearance() + 50)

        local result = nearby.castRay(checkStart, checkEnd, {
            collisionType = HOOKSHOT_PHY,
            ignore = self
        })

        if result.hit then
            local clearance = (checkStart - result.hitPos):length()
            debugPrint("Wall rappel check: clearance =", clearance, "required =", settings.minRappelClearance())
            return clearance >= settings.minRappelClearance()
        else
            debugPrint("Wall rappel check: no ground below, clearance OK")
            return true
        end
    end

    return false
end

-- ==============================================
-- LEDGE EDGE DETECTION
-- ==============================================
-- Ledge edge vs continuous surface: probe back toward the player. Same height
-- and flat means rooftop/floor, not an edge.
function Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType)
    -- Floors always; walls and ceilings only when looking down.
    local isFloorSurface = surfaceType == "floor"

    if not isFloorSurface then
        if not cameraPitch or cameraPitch > DOWNWARD_LOOK_THRESHOLD then
            debugPrint("Ledge edge check: non-floor + not looking down, skipping (pitch =", cameraPitch, ")")
            return true  -- Skip this check (allow rappel)
        end
    end

    debugPrint("Ledge edge check: running (surfaceType =", surfaceType, ", pitch =", cameraPitch, ")")

    local towardPlayer = util.vector3(
        cameraPos.x - hitPos.x,
        cameraPos.y - hitPos.y,
        0
    )

    if towardPlayer:length() < 1 then
        debugPrint("Ledge edge check: player directly above target, allowing rappel")
        return true  -- Player directly above, can't determine approach direction
    end

    towardPlayer = towardPlayer:normalize()

    -- Probe point WALL_OFFSET toward the player.
    local probePoint = hitPos + towardPlayer * orient.WALL_OFFSET

    local probeStart = probePoint + util.vector3(0, 0, PLAYER_HEIGHT * 0.5 + LEDGE_PROBE_CLEARANCE)
    local probeEnd = probePoint - util.vector3(0, 0, PLAYER_HEIGHT * 2)

    debugPrint("Ledge edge check: probing from",
        string.format("(%.1f, %.1f, %.1f)", probeStart.x, probeStart.y, probeStart.z),
        "to",
        string.format("(%.1f, %.1f, %.1f)", probeEnd.x, probeEnd.y, probeEnd.z))

    local result = nearby.castRay(probeStart, probeEnd, {
        collisionType = HOOKSHOT_PHY,
        ignore = self
    })

    if result.hit then
        local groundZ = result.hitPos.z
        local hitZ = hitPos.z
        local heightDiff = math.abs(groundZ - hitZ)

        local isFlat = result.hitNormal and result.hitNormal.z > 0.7

        debugPrint("Ledge edge check: ground found at Z =", groundZ,
                   "hit Z =", hitZ,
                   "diff =", heightDiff,
                   "tolerance =", LEDGE_EDGE_TOLERANCE,
                   "isFlat =", tostring(isFlat))

        -- Continuous surface, not a ledge.
        if heightDiff < LEDGE_EDGE_TOLERANCE and isFlat then
            debugPrint("Ledge edge check: CONTINUOUS SURFACE detected - denying rappel")
            return false
        else
            debugPrint("Ledge edge check: surface height differs or not flat - this is a ledge edge")
            return true
        end
    else
        debugPrint("Ledge edge check: no ground in approach path - LEDGE EDGE confirmed")
        return true
    end
end

-- ==============================================
-- TARGET CLASSIFICATION
-- ==============================================
-- Reticle target type, including rappel eligibility.
function Targeting.getTargetType(hitObject, surfaceType, hitPos, hitNormal, cameraPos, cameraPitch)
    local function isRappelEligible()
        if not hitPos or not hitNormal then return false end

        if not Targeting.checkRappelClearance(hitPos, hitNormal) then
            return false
        end

        if not Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType) then
            return false
        end

        return true
    end

    if not hitObject then
        if surfaceType == "ceiling" then
            return "ceiling"
        elseif surfaceType == "wall" then
            if isRappelEligible() then
                return "rappel"
            end
            return "wall"
        else
            if isRappelEligible() then
                return "rappel"
            end
            return "floor"
        end
    end

    if U.isActor(hitObject) then
        return "enemy"
    elseif U.isCarriableItem(hitObject) then
        -- Locked item targeting reads as no target.
        if not capabilities.itemTargeting then
            return "none"
        end
        return "item"
    else
        -- Doors and statics
        if surfaceType == "ceiling" then
            return "ceiling"
        elseif isRappelEligible() then
            return "rappel"
        elseif surfaceType == "wall" then
            return "wall"
        else
            return "floor"
        end
    end
end

-- ==============================================
-- FALLBACK GRABBABLE DETECTION
-- ==============================================
-- Closest grabbable near the aim, for objects the ray misses. cameraDir is unit length.
-- `accept` runs last: it is the only expensive test, so distance and angle cull first.
local function checkFallbackCandidate(obj, cameraPos, cameraDir, maxRangeSq, best, accept)
    local toObj = obj.position - cameraPos
    local distSq = toObj:dot(toObj)

    if distSq > maxRangeSq or distSq < 1e-6 then
        return
    end

    local distance = math.sqrt(distSq)
    local angle = math.acos(U.clamp(toObj:dot(cameraDir) / distance, -1, 1))

    if not (angle < best.angle
        or (angle < ITEM_DETECTION_ANGLE_THRESHOLD and distance < best.distance * 0.5))
    then
        return
    end

    if accept and not accept(obj) then
        return
    end

    best.target = obj
    best.angle = angle
    best.distance = distance
end

function Targeting.findGrabbableNearAim(cameraPos, cameraDir, maxRange)
    local best = {
        target = nil,
        angle = ITEM_DETECTION_ANGLE_THRESHOLD,
        distance = maxRange,
    }
    local maxRangeSq = maxRange * maxRange

    -- Items skipped entirely when item targeting is locked.
    if capabilities.itemTargeting then
        local items = nearby.items
        for i = 1, #items do
            checkFallbackCandidate(items[i], cameraPos, cameraDir, maxRangeSq, best,
                U.isCarriableItem)
        end
    end

    local actors = nearby.actors
    local me = self.object
    for i = 1, #actors do
        local actor = actors[i]
        if actor ~= me then
            checkFallbackCandidate(actor, cameraPos, cameraDir, maxRangeSq, best, U.isActor)
        end
    end

    if best.target then
        debugPrint("Fallback detection found:", best.target.recordId, "at angle:", best.angle, "distance:", best.distance)
    end

    return best.target, best.distance
end

return Targeting

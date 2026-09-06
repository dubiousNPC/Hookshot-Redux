---@omw-context player

--[[
    hookshot_targeting.lua
    Raycasting pipeline, surface analysis, and target classification for hookshot mod.

    Everything between "where is the camera pointing?" and "what did we hit?"
    Raycasting, surface probing, rappel clearance checks, ledge detection,
    target classification, and the fallback cone search for small objects.
]]--

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
-- Pushed down from player.lua's refreshCapabilities() on draw and fire.
-- Kept as module state rather than threaded through every call signature,
-- and defaulted to permissive so a missed setCapabilities() call can never
-- silently disable targeting.
local capabilities = {
    itemTargeting = true,
}

function Targeting.setCapabilities(caps)
    capabilities.itemTargeting = (caps == nil) or (caps.itemTargeting ~= false)
end

-- ==============================================
-- CONSTANTS
-- ==============================================
-- Hookshot collision mask: exclude water so hookshot works while swimming
local HOOKSHOT_PHY = nearby.COLLISION_TYPE.World
                   + nearby.COLLISION_TYPE.Door
                   + nearby.COLLISION_TYPE.HeightMap
                   + nearby.COLLISION_TYPE.Actor

-- Ledge edge detection constants (inspired by parkour sensor)
local PLAYER_HEIGHT = U.PLAYER_HEIGHT
local DOWNWARD_LOOK_THRESHOLD = -0.05    -- ~10 degrees in radians (camera pitch threshold)
local LEDGE_EDGE_TOLERANCE = 64          -- Max Z difference to consider "same surface" (half player height)
local LEDGE_PROBE_CLEARANCE = 40         -- Extra height above probe point for downward cast

-- Angle threshold for detecting items near crosshair (in radians)
-- ~0.1 radians ≈ 5.7 degrees - tight cone for precision
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
-- Returns true if there's enough clearance (minRappelClearance setting) below where the player would hang
function Targeting.checkRappelClearance(hitPos, hitNormal)
    if not settings.rappelFunMode() then
        return false
    end

    if not hitNormal then
        return false
    end

    -- Classify the surface to understand what we're dealing with
    local surfaceType = orient.classifySurface(hitNormal)

    -- Ceilings are always handled separately (always rappel-eligible)
    if surfaceType == "ceiling" then
        return false  -- Let normal ceiling logic handle it
    end

    if surfaceType == "floor" then
        -- FILTER: Exclude heightmap terrain from floor rappel points
        -- Heightmap is outdoor ground - we don't want to rappel from regular terrain
        -- Interior floors use World collision type, not HeightMap
        -- We can't directly check collision type from result, so we use a workaround:
        -- Cast a ray that ONLY hits heightmap and see if it hits at the same spot

        local heightmapCheck = nearby.castRay(
            hitPos + util.vector3(0, 0, 50),
            hitPos - util.vector3(0, 0, 50),
            {
                collisionType = nearby.COLLISION_TYPE.HeightMap,
                ignore = self
            }
        )

        if heightmapCheck.hit then
            -- This floor is heightmap terrain - not rappel-eligible
            debugPrint("Floor rappel check: heightmap terrain detected, denying")
            return false
        end

        -- Not heightmap, so check for elevated platform with air gap below
        local probeStart = hitPos + util.vector3(0, 0, 50)
        local probeEnd = hitPos - util.vector3(0, 0, settings.minRappelClearance() + 100)

        local result = nearby.castRay(probeStart, probeEnd, {
            collisionType = HOOKSHOT_PHY,
            ignore = self
        })

        if result.hit then
            -- Now cast from BELOW that hit point to see how far down the next surface is
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
        -- For walls, check if the hit point is high enough off the ground
        local horizontalNormal = util.vector3(hitNormal.x, hitNormal.y, 0)
        if horizontalNormal:length() > 0.01 then
            horizontalNormal = horizontalNormal:normalize()
        else
            debugPrint("Wall rappel check: can't determine wall orientation, denying")
            return false
        end

        -- Player hang position would be offset from wall
        local playerHangPos = hitPos + horizontalNormal * 30

        -- Cast straight down from where player would hang
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
-- Check if we're aiming at a ledge edge vs a continuous surface (rooftop/floor)
-- Inspired by the parkour sensor's "lip check" technique
--
-- The idea: cast a probe from a point CLOSER to the player (toward us from
-- the hit point). If that probe hits the same surface at roughly the same
-- height, it's a continuous floor/rooftop - NOT a ledge edge. If it misses
-- or hits something much lower, there's a real drop-off and it's a valid
-- rappel point.
function Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType)
    -- Always run this check for floor surfaces (catches sloped canton floors in Vivec etc.)
    -- For non-floor surfaces, only apply when looking significantly downward
    local isFloorSurface = surfaceType == "floor"

    if not isFloorSurface then
        -- For walls/ceilings, only apply when looking down
        if not cameraPitch or cameraPitch > DOWNWARD_LOOK_THRESHOLD then
            debugPrint("Ledge edge check: non-floor + not looking down, skipping (pitch =", cameraPitch, ")")
            return true  -- Skip this check (allow rappel)
        end
    end

    debugPrint("Ledge edge check: running (surfaceType =", surfaceType, ", pitch =", cameraPitch, ")")

    -- Calculate direction from hit point toward player (horizontal only)
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

    -- Offset the probe point toward the player by WALL_OFFSET (same offset we use for landing)
    local probePoint = hitPos + towardPlayer * orient.WALL_OFFSET

    -- Cast from above the probe point, down through where the surface should be
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
        -- There's ground in the approach path - check if it's the same surface
        local groundZ = result.hitPos.z
        local hitZ = hitPos.z
        local heightDiff = math.abs(groundZ - hitZ)

        -- Also check that the surface is reasonably flat (like parkour sensor's slope > 0.7)
        local isFlat = result.hitNormal and result.hitNormal.z > 0.7

        debugPrint("Ledge edge check: ground found at Z =", groundZ,
                   "hit Z =", hitZ,
                   "diff =", heightDiff,
                   "tolerance =", LEDGE_EDGE_TOLERANCE,
                   "isFlat =", tostring(isFlat))

        -- If the ground is within tolerance of the hit point AND it's flat,
        -- this is a continuous surface (rooftop/floor), not a ledge
        if heightDiff < LEDGE_EDGE_TOLERANCE and isFlat then
            debugPrint("Ledge edge check: CONTINUOUS SURFACE detected - denying rappel")
            return false
        else
            debugPrint("Ledge edge check: surface height differs or not flat - this is a ledge edge")
            return true
        end
    else
        -- No ground found in probe path - there's a drop-off, this is a real ledge
        debugPrint("Ledge edge check: no ground in approach path - LEDGE EDGE confirmed")
        return true
    end
end

-- ==============================================
-- TARGET CLASSIFICATION
-- ==============================================
-- Determine target type for reticle coloring
-- Includes rappel eligibility check for fun mode and ledge edge detection
function Targeting.getTargetType(hitObject, surfaceType, hitPos, hitNormal, cameraPos, cameraPitch)
    -- Helper function to check full rappel eligibility (clearance + ledge edge)
    local function isRappelEligible()
        if not hitPos or not hitNormal then return false end

        -- First check: basic clearance (existing check)
        if not Targeting.checkRappelClearance(hitPos, hitNormal) then
            return false
        end

        -- Second check: ledge edge detection
        -- This filters out continuous surfaces like rooftops and floors
        if not Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType) then
            return false
        end

        return true
    end

    if not hitObject then
        -- World geometry - use surface type
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

    -- Has hit object
    if U.isActor(hitObject) then
        return "enemy"
    elseif U.isCarriableItem(hitObject) then
        -- Item targeting locked: report no-target rather than a coloured
        -- item lock. The reticle greys out over items and fireHookshot
        -- refuses them, so the UI never promises a pull it won't perform.
        if not capabilities.itemTargeting then
            return "none"
        end
        return "item"
    else
        -- Some other object (door, static mesh like buildings/trees/mushrooms)
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
-- Find the closest grabbable object near where we're aiming
-- This is used as a fallback when raycast hits world geometry but there's
-- actually an item/actor in the way that the physics ray missed
-- Shared by both loops below. cameraDir is assumed unit-length (true of
-- every call site - Targeting.getCameraDirData()'s U.anglesToV always
-- returns a unit vector by construction), which lets the angle math skip
-- a length() call U.angleBetweenVectors would otherwise redo every time.
local function checkFallbackCandidate(obj, cameraPos, cameraDir, maxRangeSq, best)
    local toObj = obj.position - cameraPos
    local distSq = toObj:dot(toObj)

    -- Cheap squared-distance cull first - skips the sqrt AND the angle
    -- math (another sqrt plus an acos) for anything obviously out of
    -- range, which in a busy cell is most of the candidate list.
    if distSq > maxRangeSq or distSq < 1e-6 then
        return
    end

    local distance = math.sqrt(distSq)
    local angle = math.acos(U.clamp(toObj:dot(cameraDir) / distance, -1, 1))

    if angle < best.angle or (angle < ITEM_DETECTION_ANGLE_THRESHOLD and distance < best.distance * 0.5) then
        best.target = obj
        best.angle = angle
        best.distance = distance
    end
end

function Targeting.findGrabbableNearAim(cameraPos, cameraDir, maxRange)
    local best = {
        target = nil,
        angle = ITEM_DETECTION_ANGLE_THRESHOLD,
        distance = maxRange,
    }
    local maxRangeSq = maxRange * maxRange

    -- Check nearby items. Skipped wholesale when item targeting is locked -
    -- this is the loop that would otherwise snap the reticle onto a fork
    -- the player has no way to pull, and skipping it also saves the scan.
    if capabilities.itemTargeting then
        for _, item in ipairs(nearby.items) do
            if U.isCarriableItem(item) then
                checkFallbackCandidate(item, cameraPos, cameraDir, maxRangeSq, best)
            end
        end
    end

    -- Check nearby actors (but not self)
    for _, actor in ipairs(nearby.actors) do
        if actor ~= self and U.isActor(actor) then
            checkFallbackCandidate(actor, cameraPos, cameraDir, maxRangeSq, best)
        end
    end

    if best.target then
        debugPrint("Fallback detection found:", best.target.recordId, "at angle:", best.angle, "distance:", best.distance)
    end

    return best.target, best.distance
end

return Targeting

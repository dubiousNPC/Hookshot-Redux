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
    item = true,
    npc = true,
}

function Targeting.setCapabilities(caps)
    capabilities.item = (caps == nil) or (caps.item ~= false)
    capabilities.npc = (caps == nil) or (caps.npc ~= false)
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
            -- Measure the drop PAST THE EDGE, where the player will hang:
            -- step from the hit toward the player (the open side, as
            -- checkLedgeEdge establishes) until a downward ray no longer meets
            -- the platform top.
            --
            -- Not straight down from 20 below the top: that start is inside
            -- the platform, so the ray met the platform's own underside and
            -- every platform thicker than 20 units read as no clearance
            -- (measured in game: 22 for a 54-unit slab, 100 for a 155-unit one).
            local top = result.hitPos.z
            local minClear = settings.minRappelClearance()
            local toward = util.vector3(self.position.x - hitPos.x, self.position.y - hitPos.y, 0)
            if toward:length() < 1 then
                debugPrint("Floor rappel check: player directly above, denying")
                return false
            end
            toward = toward:normalize()
            for d = 0, 160, 8 do
                local p = hitPos + toward * d
                local drop = nearby.castRay(
                    util.vector3(p.x, p.y, top + 30),
                    util.vector3(p.x, p.y, top - minClear - 50),
                    { collisionType = HOOKSHOT_PHY, ignore = self })
                if not drop.hit then
                    debugPrint("Floor rappel check:", d, "past the hit, no ground below, clearance OK")
                    return true
                end
                if drop.hitPos.z < top - 40 then
                    local clearance = top - drop.hitPos.z
                    debugPrint("Floor rappel check:", d, "past the hit, clearance =", clearance, "required =", minClear)
                    return clearance >= minClear
                end
            end
            debugPrint("Floor rappel check: no edge within 160 toward the player, denying")
            return false
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
-- HANG POSITION
-- ==============================================
-- Where a hang puts the player: feet HANG_DROP below the anchor, in the
-- clear column closest to straight under it.
--
-- The landing offset used to follow the surface normal, so the hang sat out
-- along the normal rather than under the rope: 30 out and only 20 below a wall
-- anchor (the head above the hook, the rope sticking sideways), and diagonally
-- off a sloped ceiling. A ledge (a floor hit) put the feet straight below a
-- point on top of the platform, inside it.
local HANG_RADIUS = 32        -- player half-width (30) plus a margin
local HANG_STEP = 8
local HANG_MAX_OFFSET = 160   -- beyond this, keep the legacy offset
-- The anchor comes from a rendering ray and can sit 10-12 units inside the
-- collision surface (measured in game). A rope-ray hit this close to the
-- anchor is the anchor's own surface, not an obstruction.
local HANG_ANCHOR_SLOP = 32

-- Horizontal unit vector or nil.
local function flat(v)
    if not v then return nil end
    local h = util.vector3(v.x, v.y, 0)
    if h:length() < 0.15 then return nil end
    return h:normalize()
end

-- Is the player-sized column at (x, y), from topZ down to feetZ, free?
-- Vertical rays at the centre and at four points HANG_RADIUS out.
local function columnClear(centre, topZ, feetZ, side)
    local offsets = {
        util.vector3(0, 0, 0),
        side * HANG_RADIUS, side * -HANG_RADIUS,
        util.vector3(-side.y, side.x, 0) * HANG_RADIUS,
        util.vector3(side.y, -side.x, 0) * HANG_RADIUS,
    }
    for _, o in ipairs(offsets) do
        local x, y = centre.x + o.x, centre.y + o.y
        local r = nearby.castRay(util.vector3(x, y, topZ), util.vector3(x, y, feetZ),
            { collisionType = HOOKSHOT_PHY, ignore = self })
        if r.hit then return false, r end
    end
    return true
end

---@param anchor any vector3, where the hook holds
---@param hitNormal any vector3
---@param surfaceType string "floor" | "wall" | "ceiling"
---@param towardPlayer any vector3 or nil, anchor-to-player direction
---@return any|nil feet position, or nil to keep the legacy landing offset
function Targeting.resolveHangPosition(anchor, hitNormal, surfaceType, towardPlayer)
    local feetZ = anchor.z - orient.CEILING_OFFSET
    -- Which way is open. A ceiling is open straight down; a sloped one also
    -- away from its slope. A wall is open along its normal. A ledge is a floor
    -- hit whose open side is the player's (checkLedgeEdge found no ground there).
    local out
    if surfaceType == "wall" then
        out = flat(hitNormal)
    elseif surfaceType == "ceiling" then
        out = flat(hitNormal) or flat(towardPlayer)
    else
        out = flat(towardPlayer)
    end
    if not out then return nil end

    -- Over a ledge the rays start ABOVE the top surface, so a column still
    -- over the platform is blocked by it, and the rope is allowed to bend over
    -- the edge. Elsewhere the column is the player's own height (head plus a
    -- margin), which never starts a ray inside a sloped ceiling, and the rope
    -- from there to the hook must be clear.
    local ledge = surfaceType == "floor"
    local headZ = feetZ + PLAYER_HEIGHT + 20
    local topZ = ledge and (anchor.z + 30) or headZ
    local hook = anchor + (hitNormal and hitNormal:normalize() * 4 or util.vector3(0, 0, -4))
    local function ropeBlocked(r)
        return r.hit and r.hitPos and (r.hitPos - anchor):length() > HANG_ANCHOR_SLOP
    end
    -- A ceiling may be clear straight under the hook; a wall's face is never.
    local first = (surfaceType == "ceiling") and 0 or (HANG_RADIUS + 2)
    -- Where the wall's collision face really is, at the body's heights: the
    -- anchor can sit inside it (HANG_ANCHOR_SLOP), and a leaning wall is
    -- nearer at one height than another. Without this the hang point was ~10
    -- units into the face and the physics push-out varied from 48 to 73.
    if surfaceType == "wall" then
        for _, z in ipairs({ feetZ + PLAYER_HEIGHT * 0.5, headZ }) do
            local from = util.vector3(anchor.x, anchor.y, z) + out * 200
            local face = nearby.castRay(from, util.vector3(anchor.x, anchor.y, z) - out * 50,
                { collisionType = HOOKSHOT_PHY, ignore = self })
            if face.hit and face.hitPos then
                local faceOut = (face.hitPos - anchor):dot(out)
                first = math.max(first, math.ceil(faceOut + HANG_RADIUS + 2))
            end
        end
    end

    for d = first, HANG_MAX_OFFSET, HANG_STEP do
        local centre = anchor + out * d
        local rope = (not ledge) and nearby.castRay(util.vector3(centre.x, centre.y, headZ), hook,
            { collisionType = HOOKSHOT_PHY, ignore = self })
        local clear, blocker = false, rope
        if not (rope and ropeBlocked(rope)) then clear, blocker = columnClear(centre, topZ, feetZ, out) end
        if not clear and (d == first or d + HANG_STEP > HANG_MAX_OFFSET) then
            debugPrint("Hang column", d, "out blocked by", (rope and ropeBlocked(rope)) and "rope ray" or "column ray",
                blocker and blocker.hitObject and blocker.hitObject.recordId or "-",
                blocker and blocker.hitPos and orient.normalToString(blocker.hitPos) or "-")
        end
        if clear then
            debugPrint("Hang column found", d, "out from the anchor")
            return util.vector3(centre.x, centre.y, feetZ)
        end
    end
    debugPrint("No clear hang column within", HANG_MAX_OFFSET, "- keeping the surface offset")
    return nil
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
        -- A locked mode reads as no target, so the reticle never promises a
        -- pull that fireHookshot will refuse.
        if not capabilities.npc then
            return "none"
        end
        return "enemy"
    elseif U.isCarriableItem(hitObject) then
        if not capabilities.item then
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
    if capabilities.item then
        local items = nearby.items
        for i = 1, #items do
            checkFallbackCandidate(items[i], cameraPos, cameraDir, maxRangeSq, best,
                U.isCarriableItem)
        end
    end

    if capabilities.npc then
        local actors = nearby.actors
        local me = self.object
        for i = 1, #actors do
            local actor = actors[i]
            if actor ~= me then
                checkFallbackCandidate(actor, cameraPos, cameraDir, maxRangeSq, best, U.isActor)
            end
        end
    end

    if best.target then
        debugPrint("Fallback detection found:", best.target.recordId, "at angle:", best.angle, "distance:", best.distance)
    end

    return best.target, best.distance
end

return Targeting

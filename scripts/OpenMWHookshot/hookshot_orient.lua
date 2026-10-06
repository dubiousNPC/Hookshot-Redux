---@omw-context player
-- Surface classification and landing/hang positions.

local util = require('openmw.util')

local orient = {}

-- ==============================================
-- CONFIGURATION
-- ==============================================
-- Normal Z: above FLOOR is floor, below CEILING is ceiling, else wall.
orient.FLOOR_THRESHOLD = 0.5
orient.CEILING_THRESHOLD = -0.5

orient.FLOOR_OFFSET = 50          -- above a floor
orient.WALL_OFFSET = 60           -- out from a wall
orient.CEILING_OFFSET = 195       -- below a ceiling

-- ==============================================
-- SURFACE CLASSIFICATION
-- ==============================================
-- Returns "floor", "wall" or "ceiling".
function orient.classifySurface(hitNormal)
    if not hitNormal then return "floor" end

    local z = hitNormal.z

    if z > orient.FLOOR_THRESHOLD then
        return "floor"
    elseif z < orient.CEILING_THRESHOLD then
        return "ceiling"
    else
        return "wall"
    end
end

-- ==============================================
-- UTILITY FUNCTIONS
-- ==============================================
function orient.normalToString(normal)
    if not normal then return "nil" end
    return string.format("(%.2f, %.2f, %.2f)", normal.x, normal.y, normal.z)
end

-- ==============================================
-- LANDING CALCULATION
-- ==============================================
-- Offsets follow the surface normal, not the approach direction.
-- Returns { position, yaw, surfaceType, isHang, isRappelPoint }.
function orient.calculateLanding(hitPos, hitNormal, approachDir, playerYaw, rappelEligible)
    hitNormal = hitNormal or util.vector3(0, 0, 1)
    rappelEligible = rappelEligible or false

    local surfaceType = orient.classifySurface(hitNormal)
    local offset
    local isHang = false
    local isRappelPoint = false

    if surfaceType == "floor" then
        offset = hitNormal:normalize() * orient.FLOOR_OFFSET

        -- Elevated platform: hang below its edge.
        if rappelEligible then
            isHang = true
            isRappelPoint = true
            offset = util.vector3(0, 0, -orient.CEILING_OFFSET)
        end

    elseif surfaceType == "wall" then
        local horizontalNormal = util.vector3(hitNormal.x, hitNormal.y, 0)
        if horizontalNormal:length() > 0.01 then
            horizontalNormal = horizontalNormal:normalize()
        else
            horizontalNormal = util.vector3(-approachDir.x, -approachDir.y, 0):normalize()
        end
        offset = horizontalNormal * orient.WALL_OFFSET + util.vector3(0, 0, 20)

        if rappelEligible then
            isHang = true
            isRappelPoint = true
            offset = horizontalNormal * (orient.WALL_OFFSET * 0.5) + util.vector3(0, 0, -20)
        end

    elseif surfaceType == "ceiling" then
        offset = hitNormal:normalize() * orient.CEILING_OFFSET
        isHang = true
        isRappelPoint = true
    end

    local landingPos = hitPos + offset

    return {
        position = landingPos,
        yaw = playerYaw,
        surfaceType = surfaceType,
        isHang = isHang,
        isRappelPoint = isRappelPoint,
    }
end

return orient

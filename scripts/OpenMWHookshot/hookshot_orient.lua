---@omw-context player

--[[
    hookshot_orient.lua
    Surface classification and landing position calculation for hookshot mod.
    
    This module determines:
    - What type of surface was hit (floor, wall, ceiling)
    - Whether the surface is rappel-eligible (ceiling OR elevated surface with clearance)
    - Safe offset positions for landing/hanging
]]--

local util = require('openmw.util')

local orient = {}

-- ==============================================
-- CONFIGURATION
-- ==============================================
-- Surface classification thresholds (based on normal Z component)
orient.FLOOR_THRESHOLD = 0.5      -- Z > 0.5 = floor
orient.CEILING_THRESHOLD = -0.5   -- Z < -0.5 = ceiling
-- Everything else = wall

-- Offset distances from hit point (in game units)
orient.FLOOR_OFFSET = 50          -- How far above floor to place player
orient.WALL_OFFSET = 60           -- How far from wall to place player
orient.CEILING_OFFSET = 195       -- How far below ceiling to place player (head clearance)

-- ==============================================
-- SURFACE CLASSIFICATION
-- ==============================================
--[[
    Classifies a surface based on its normal vector.
    
    @param hitNormal (Vector3) - The surface normal
    @return (string) - "floor", "wall", or "ceiling"
]]--
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
--[[
    Calculates safe landing position and determines if rappel is allowed.
    
    The key insight: offset direction should follow the surface normal,
    not the approach direction. This ensures we always move "away" from
    the surface into safe space.
    
    @param hitPos (Vector3) - Where the hookshot hit
    @param hitNormal (Vector3) - Surface normal at hit point
    @param approachDir (Vector3) - Direction player was looking/traveling
    @param playerYaw (number) - Player's current yaw (to preserve facing)
    @param rappelEligible (boolean) - Whether this surface passed clearance check (optional)
    
    @return (table) - {
        position = Vector3,      -- Where to place the player
        yaw = number,            -- What direction player should face
        surfaceType = string,    -- "floor", "wall", or "ceiling"
        isHang = boolean,        -- Whether this triggers hang state
        isRappelPoint = boolean, -- Whether this is a rappel-eligible point (for reticle color)
    }
]]--
function orient.calculateLanding(hitPos, hitNormal, approachDir, playerYaw, rappelEligible)
    -- Default normal if none provided (assume floor)
    hitNormal = hitNormal or util.vector3(0, 0, 1)
    rappelEligible = rappelEligible or false
    
    local surfaceType = orient.classifySurface(hitNormal)
    local offset
    local isHang = false
    local isRappelPoint = false
    
    if surfaceType == "floor" then
        -- Landing on floor/slope: offset along normal (upward from surface)
        offset = hitNormal:normalize() * orient.FLOOR_OFFSET
        
        -- Floor can be a rappel point if it has clearance (elevated platform)
        if rappelEligible then
            isHang = true
            isRappelPoint = true
            -- Use ceiling-style offset for hanging from elevated floor
            offset = util.vector3(0, 0, -orient.CEILING_OFFSET)
        end
        
    elseif surfaceType == "wall" then
        -- Landing near wall: offset along normal (away from wall)
        -- Use only horizontal component of normal for offset direction
        local horizontalNormal = util.vector3(hitNormal.x, hitNormal.y, 0)
        if horizontalNormal:length() > 0.01 then
            horizontalNormal = horizontalNormal:normalize()
        else
            -- Edge case: nearly horizontal surface classified as wall
            -- Fall back to using approach direction
            horizontalNormal = util.vector3(-approachDir.x, -approachDir.y, 0):normalize()
        end
        offset = horizontalNormal * orient.WALL_OFFSET
        -- Add small vertical offset to prevent ground clipping
        offset = offset + util.vector3(0, 0, 20)
        
        -- Wall can be a rappel point if it has clearance below
        if rappelEligible then
            isHang = true
            isRappelPoint = true
            -- Keep some horizontal offset from wall, but position for vertical rappel
            offset = horizontalNormal * (orient.WALL_OFFSET * 0.5) + util.vector3(0, 0, -20)
        end
        
    elseif surfaceType == "ceiling" then
        -- Hanging from ceiling: offset along normal (downward from surface)
        offset = hitNormal:normalize() * orient.CEILING_OFFSET
        isHang = true
        isRappelPoint = true  -- Ceilings are always rappel points
    end
    
    local landingPos = hitPos + offset
    
    return {
        position = landingPos,
        yaw = playerYaw,  -- Preserve approach direction
        surfaceType = surfaceType,
        isHang = isHang,
        isRappelPoint = isRappelPoint,
    }
end

return orient

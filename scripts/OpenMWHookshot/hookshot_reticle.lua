---@omw-context player

-- Crosshair UI. Display only; player.lua supplies the target info.

local camera = require('openmw.camera')
local ui = require('openmw.ui')
local util = require('openmw.util')

local settings = require('scripts.OpenMWHookshot.hookshot_settings')
local U = require('scripts.OpenMWHookshot.hookshot_util')

local debugPrint = settings.debugPrint

-- ==============================================
-- ANIMATION CONSTANTS
-- ==============================================
local LOCK_ON_ANIMATION_DURATION = 0.15  -- How long the "lock on" pulse animation takes
local LOCK_ON_BOUNCE_SIZE = 16           -- How much the reticle grows during lock-on animation

-- ==============================================
-- RETICLE MANAGER (inspired by T4rg3t5)
-- ==============================================
local Reticle = {
    element = nil,
    currentTexture = nil,
    state = {
        visible = false,
        hasTarget = false,
        targetType = "none",  -- "none", "floor", "wall", "ceiling", "enemy", "item"
        previousTargetType = "none",
        distance = 0,
        isAnimating = false,
        animationTimer = 0,
        bounceSize = 0,
        bounceDirection = 1,  -- 1 = growing, -1 = shrinking
    }
}

function Reticle.getTexturePath(iconName)
    if settings.useFallbackTextures then
        return settings.FALLBACK_TEXTURE_PATH .. iconName .. '.dds'
    else
        return settings.RETICLE_TEXTURE_PATH .. iconName .. '.dds'
    end
end

function Reticle:getSize()
    local baseSize

    if not self.state.hasTarget then
        baseSize = settings.reticleIdleSize()
    else
        -- Closer = bigger
        baseSize = U.remapClamped(
            self.state.distance,
            settings.reticleMinDistance(), settings.reticleMaxDistance(),
            settings.reticleMaxSize(), settings.reticleMinSize()
        )
    end

    return baseSize + self.state.bounceSize
end

function Reticle:getColor()
    return settings.color(self.state.targetType)
end

function Reticle:init()
    if self.element then return end

    self.currentTexture = self.getTexturePath(settings.reticleIcon())

    local idleSize = settings.reticleIdleSize()
    self.element = ui.create {
        layer = "HUD",
        type = ui.TYPE.Image,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),  -- Center of screen
            size = util.vector2(idleSize, idleSize),
            resource = ui.texture { path = self.currentTexture },
            visible = false,
            color = settings.color("none"),
        }
    }

    debugPrint("ReticleManager initialized with icon:", settings.reticleIcon())
    debugPrint("Available icons:", table.concat(settings.iconNames, ", "), "| Using fallback:", settings.useFallbackTextures)
end

function Reticle:show()
    if not self.element then self:init() end
    if self.state.visible then return end

    self.element.layout.props.visible = true
    self.state.visible = true
    camera.showCrosshair(false)
    self.element:update()

    debugPrint("Reticle shown")
end

function Reticle:hide()
    if not self.element or not self.state.visible then return end

    self.element.layout.props.visible = false
    self.state.visible = false
    self.state.hasTarget = false
    self.state.targetType = "none"
    self.state.isAnimating = false
    self.state.bounceSize = 0
    camera.showCrosshair(true)
    self.element:update()

    debugPrint("Reticle hidden")
end

-- Lets save/load cleanup tell whether this mod hid the crosshair.
function Reticle:isVisible()
    return self.state.visible
end

function Reticle:startLockAnimation()
    if not settings.lockAnimation() then return end
    if self.state.isAnimating then return end

    self.state.isAnimating = true
    self.state.animationTimer = 0
    self.state.bounceSize = 0
    self.state.bounceDirection = 1

    debugPrint("Lock-on animation started")
end

function Reticle:updateAnimation(deltaSeconds)
    if not self.state.isAnimating then return end

    self.state.animationTimer = self.state.animationTimer + deltaSeconds

    if self.state.bounceDirection == 1 then
        self.state.bounceSize = self.state.bounceSize + (LOCK_ON_BOUNCE_SIZE * 2 * deltaSeconds / LOCK_ON_ANIMATION_DURATION)
        if self.state.bounceSize >= LOCK_ON_BOUNCE_SIZE then
            self.state.bounceSize = LOCK_ON_BOUNCE_SIZE
            self.state.bounceDirection = -1
        end
    else
        self.state.bounceSize = self.state.bounceSize - (LOCK_ON_BOUNCE_SIZE * 2 * deltaSeconds / LOCK_ON_ANIMATION_DURATION)
        if self.state.bounceSize <= 0 then
            self.state.bounceSize = 0
            self.state.isAnimating = false
            self.state.bounceDirection = 1
            debugPrint("Lock-on animation complete")
        end
    end
end

function Reticle:update(hasTarget, targetType, distance)
    if not self.element then return end

    local targetChanged = (hasTarget and not self.state.hasTarget) or
                         (hasTarget and targetType ~= self.state.previousTargetType)

    self.state.hasTarget = hasTarget
    self.state.targetType = targetType
    self.state.distance = distance or settings.maxRange()

    if targetChanged and hasTarget then
        self:startLockAnimation()
        self.state.previousTargetType = targetType
    end

    local desiredTexture = self.getTexturePath(settings.reticleIcon())
    if desiredTexture ~= self.currentTexture then
        self.currentTexture = desiredTexture
        self.element.layout.props.resource = ui.texture { path = self.currentTexture }
    end

    local size = self:getSize()
    self.element.layout.props.size = util.vector2(size, size)
    self.element.layout.props.color = self:getColor()

    self.element:update()
end

return Reticle

---@omw-context player

-- ==============================================
-- IMPORTS
-- ==============================================
-- ALL SCRIPTS
local async = require('openmw.async')
local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
-- PLAYER SCRIPTS ONLY
local ambient = require('openmw.ambient')
local camera = require('openmw.camera')
local input = require('openmw.input')
local ui = require('openmw.ui')
-- LOCAL SCRIPTS ONLY
local nearby = require('openmw.nearby')
local self = require('openmw.self')

-- LOCAL MODULES
local orient = require('scripts.OpenMWHookshot.hookshot_orient')
local hookshotMenu = require('scripts.OpenMWHookshot.hookshot_menu')
local settings = require('scripts.OpenMWHookshot.hookshot_settings')
local U = require('scripts.OpenMWHookshot.hookshot_util')
local Reticle = require('scripts.OpenMWHookshot.hookshot_reticle')
local Targeting = require('scripts.OpenMWHookshot.hookshot_targeting')
local Physics = require('scripts.OpenMWHookshot.hookshot_physics')
local Anim = require('scripts.OpenMWHookshot.playerAnim')

local isCarriableItem = U.isCarriableItem
local isActor = U.isActor
local isGrabbable = U.isGrabbable

local debugPrint = settings.debugPrint

---@class DubiousHookshotVisualsInterface
---@field updateRope fun(from: any, to: any): boolean
---@field endRope fun()
---@field handOrigin fun(): any

---@class HookshotSharedRayInterface
---@field requestDistance fun(distance: number)
---@field subscribe fun(key: string, callback: fun(result: any))

---@class HookshotInterfaces: openmw.interfaces
---@field DubiousHookshotVisuals DubiousHookshotVisualsInterface|nil
---@field SharedRay HookshotSharedRayInterface|nil

local I = require('openmw.interfaces')
---@cast I HookshotInterfaces

local Controls = I.Controls

local Player = types.Player

-- ==============================================
-- CONSTANTS
-- ==============================================
-- Hookshot collision mask: exclude water so hookshot works while swimming
local HOOKSHOT_PHY = nearby.COLLISION_TYPE.World
                   + nearby.COLLISION_TYPE.Door
                   + nearby.COLLISION_TYPE.HeightMap
                   + nearby.COLLISION_TYPE.Actor

local RAYCAST_THROTTLE = 3          -- Only raycast every N frames for targeting
local LANDING_DURATION = 0.4        -- How long the landing state lasts (physics settle time)
local RAPPEL_LEVITATION_MAGNITUDE = 10   -- Levitation effect magnitude (same as ladder mod)
local PULL_OFFSET = 50              -- Hardcoded offset for pull target position

-- Handoff: engine movement covers the last stretch after the drag releases.
local HANDOFF_DURATION = 0.6        -- Max length of the handoff window (seconds)
local HANDOFF_ARRIVAL = 24          -- Horizontal distance to target that ends the window early
local HANDOFF_GROUND_PROBE = 24     -- Downward probe length used to decide whether a jump would take

-- Rappel climb stops with the head this far below the anchor.
local RAPPEL_HEAD_CLEARANCE = 24
local PLAYER_HEIGHT = U.PLAYER_HEIGHT

local ROPE_PHASE_OUTBOUND = "OUTBOUND"
local ROPE_PHASE_SELF_PULL = "SELF_PULL"
local ROPE_PHASE_TARGET_PULL = "TARGET_PULL"
local ROPE_PHASE_HANGING = "HANGING"

-- ==============================================
-- STATE MANAGEMENT
-- ==============================================
local HookshotState = {
    IDLE = "IDLE",
    DRAWN = "DRAWN",
    FIRING = "FIRING",
    HANDOFF = "HANDOFF",      -- Drag released; engine movement covers the last stretch
    LANDING = "LANDING",
    HANGING = "HANGING",
    ITEM_MENU = "ITEM_MENU",  -- New state for item interaction menu
}

local state = {
    mode = HookshotState.IDLE,

    targeting = {
        impact = nil,
        range = nil,
        cameraPos = nil,
        cameraV = nil,
        cameraYaw = nil,
        cameraPitch = nil,
        surfaceType = nil,
        hitNormal = nil,
        lastRaycastFrame = 0,
        lastTargetType = "none", -- cached reticle color between throttled updates
    },

    landing = {
        timeRemaining = 0,
        targetYaw = nil,
    },

    handoff = {
        timeRemaining = 0,
        direction = nil,      -- Unit vector, horizontal, toward the aim point
        targetPos = nil,      -- Where we were headed, for the early-arrival test
        jumpPending = false,  -- One-shot: issue a jump on the first handoff frame
    },

    -- Resolved on draw and fire, not per frame.
    caps = {
        glove = false,
        itemTargeting = false,
    },

    hanging = {
        position = nil,
        yaw = nil,
        anchorPosition = nil,
        currentRopeLength = 0,
        levitationApplied = false,
        pitchOverride = 0,
        isMoving = false,
    },

    itemMenu = {
        item = nil,           -- The item being interacted with
        ragdoll = nil,        -- Reference to the ragdoll data for this item
    },

    -- Runtime only; save/load cancels an in-flight hook.
    rope = {
        active = false,
        phase = nil,
        launchPosition = nil,
        tipPosition = nil,
        anchorPosition = nil,
        target = nil,
        targetOffset = nil,
        pullsTarget = false,
        hitNormal = nil,
        approachDir = nil,
        playerYaw = nil,
        cameraPos = nil,
        cameraPitch = nil,
        travelElapsed = 0,
        travelDuration = 0,
    },

    -- Overrides this script owns, saved so onLoad can undo them.
    ownedOverrides = {
        combatControlsSuppressed = false,
        movementControlsOverridden = false,
    },
}

local frameCounter = 0
local pendingAnimReset = false

-- Forward declarations.
local abortActiveHook
local attachTravelingHook

-- ==============================================
-- HOOK TRAVEL AND ROPE VISUALS
-- ==============================================

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

-- Real vector3 or nil; a malformed visual interface cannot break gameplay.
local function copyVector3(value)
    if value == nil then return nil end

    local x, y, z = value.x, value.y, value.z
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then
        return nil
    end
    return util.vector3(x, y, z)
end

-- Acquired lazily: registered by a later manifest entry.
local function ropeInterfaceMethod(name)
    local visuals = I.DubiousHookshotVisuals
    if visuals == nil then return nil end

    local method = visuals[name]
    if type(method) ~= "function" then return nil end
    return method
end

-- Rope launch point. Hook timing uses it, so it never comes from the visual mod.
local function ropeShoulderOrigin()
    return copyVector3(U.actorShoulderOrigin(self))
        or (self.position + util.vector3(0, 0, U.PLAYER_HEIGHT * 0.81))
end

local function clearRopeState()
    local rope = state.rope
    rope.active = false
    rope.phase = nil
    rope.launchPosition = nil
    rope.tipPosition = nil
    rope.anchorPosition = nil
    rope.target = nil
    rope.targetOffset = nil
    rope.pullsTarget = false
    rope.hitNormal = nil
    rope.approachDir = nil
    rope.playerYaw = nil
    rope.cameraPos = nil
    rope.cameraPitch = nil
    rope.travelElapsed = 0
    rope.travelDuration = 0
end

local function endActiveRope()
    if state.rope.active then
        local endRope = ropeInterfaceMethod("endRope")
        if endRope then
            endRope()
        end
    end
    clearRopeState()
end

local function publishRope(endPosition)
    if not state.rope.active then return end

    local updateRope = ropeInterfaceMethod("updateRope")
    if not updateRope then return end

    local from = ropeShoulderOrigin()
    local to = copyVector3(endPosition)
    if not from or not to then return end

    updateRope(from, to)
end

local function validObjectPosition(object)
    if object == nil then return nil end

    if not object:isValid() then return nil end

    return copyVector3(object.position)
end

local function currentRopeAnchor()
    local rope = state.rope
    if rope.pullsTarget then
        local targetPosition = validObjectPosition(rope.target)
        if not targetPosition then return nil end
        return targetPosition + (rope.targetOffset or util.vector3(0, 0, 0))
    end
    return copyVector3(rope.anchorPosition)
end

local function beginHookTravel(spec)
    local hitPosition = copyVector3(spec.hitPosition)
    local approachDir = copyVector3(spec.approachDir)
    if not hitPosition or not approachDir then return false end

    -- A new shot owns the single rope slot.
    endActiveRope()

    local launchPosition = ropeShoulderOrigin()
    local targetOffset = nil
    if spec.pullsTarget then
        local targetPosition = validObjectPosition(spec.target)
        if not targetPosition then return false end
        targetOffset = hitPosition - targetPosition
    end

    local distance = (hitPosition - launchPosition):length()
    local travelSpeed = math.max(1, tonumber(settings.hookTravelSpeed()) or 4000)
    local rope = state.rope
    rope.active = true
    rope.phase = ROPE_PHASE_OUTBOUND
    rope.launchPosition = launchPosition
    rope.tipPosition = launchPosition
    rope.anchorPosition = hitPosition
    rope.target = spec.target
    rope.targetOffset = targetOffset
    rope.pullsTarget = spec.pullsTarget or false
    rope.hitNormal = spec.hitNormal
    rope.approachDir = approachDir
    rope.playerYaw = spec.playerYaw
    rope.cameraPos = spec.cameraPos
    rope.cameraPitch = spec.cameraPitch
    rope.travelElapsed = 0
    rope.travelDuration = distance / travelSpeed

    debugPrint("Hook outbound - distance =", distance,
               "speed =", travelSpeed,
               "duration =", rope.travelDuration)
    return true
end

local function updateActiveRope(deltaSeconds)
    local rope = state.rope
    if not rope.active then return end

    -- Fail-safe: only FIRING and HANGING keep a rope.
    if state.mode ~= HookshotState.FIRING
        and state.mode ~= HookshotState.HANGING
    then
        endActiveRope()
        return
    end

    local anchor = currentRopeAnchor()
    if not anchor then
        if state.mode == HookshotState.HANGING then
            -- Visual only; hanging continues.
            endActiveRope()
        else
            abortActiveHook("target_unavailable")
        end
        return
    end

    if rope.phase == ROPE_PHASE_OUTBOUND then
        rope.travelElapsed = rope.travelElapsed + math.max(deltaSeconds, 0)
        local progress = 1
        if rope.travelDuration > 0 then
            progress = math.min(1, rope.travelElapsed / rope.travelDuration)
        end

        -- Follows a moving target's live position.
        rope.tipPosition = rope.launchPosition
            + (anchor - rope.launchPosition) * progress

        if progress > 0 then
            publishRope(rope.tipPosition)
        end

        if progress >= 1 then
            attachTravelingHook(anchor)
        end
        return
    end

    rope.anchorPosition = anchor
    publishRope(anchor)
end

-- ==============================================
-- EQUIPMENT GATES
-- ==============================================
-- Called on draw and fire; the inventory can change while drawn.
local function refreshCapabilities()
    state.caps = settings.capabilities(self)
    Targeting.setCapabilities(state.caps)
    return state.caps
end

-- ==============================================
-- STATE MODE SETTER
-- ==============================================
local function setCombatControlsSuppressed(suppressed)
    Player.setControlSwitch(self, Player.CONTROL_SWITCH.Fighting, not suppressed)
    Player.setControlSwitch(self, Player.CONTROL_SWITCH.Magic, not suppressed)
    state.ownedOverrides.combatControlsSuppressed = suppressed
end

local function setMovementControlsOverridden(overridden)
    Controls.overrideMovementControls(overridden)
    state.ownedOverrides.movementControlsOverridden = overridden
end

-- Single choke point for state.mode, so playerAnim sees every transition.
local function setMode(newMode)
    if state.mode == newMode then return end

    -- The rope survives only while FIRING or HANGING.
    if state.rope.active
        and newMode ~= HookshotState.FIRING
        and newMode ~= HookshotState.HANGING
    then
        endActiveRope()
    end

    local oldMode = state.mode
    state.mode = newMode
    Anim.onStateChange(newMode, oldMode, state)

    -- Fire shares the Attack key, so combat is suppressed from DRAWN until IDLE.
    if newMode == HookshotState.DRAWN then
        setCombatControlsSuppressed(true)
    elseif newMode == HookshotState.IDLE then
        setCombatControlsSuppressed(false)
    end
end

abortActiveHook = function(reason)
    debugPrint("Cancelling active hook:", reason or "unknown")

    local rope = state.rope
    if rope.phase == ROPE_PHASE_TARGET_PULL and rope.target then
        Physics.removeByTarget(rope.target)
    elseif rope.phase == ROPE_PHASE_SELF_PULL then
        Physics.removeByTarget(self)
    end

    ambient.stopSoundFile(settings.sounds.fire)
    setMode(HookshotState.IDLE)
end

-- ==============================================
-- RETICLE TARGETING LOGIC
-- ==============================================
-- Reticle visibility and lock-on animation; no raycasting.
local function updateReticleVisibility(deltaSeconds)
    if state.mode ~= HookshotState.DRAWN then
        Reticle:hide()
        return
    end

    Reticle:show()
    Reticle:updateAnimation(deltaSeconds)
end

-- Runs at most once per RAYCAST_THROTTLE deliveries.
local function applyFreshHit(hitObject, hitPos, range)
    state.targeting.impact = {
        hit = true,
        hitPos = hitPos,
        hitObject = hitObject,
    }
    state.targeting.range = range

    -- Dedicated physics ray: SharedRay's hitNormal is unreliable.
    local hitNormal = nil
    if not hitObject or not isGrabbable(hitObject) then
        hitNormal = Targeting.probeSurfaceNormal(hitPos, state.targeting.cameraV)
        state.targeting.surfaceType = orient.classifySurface(hitNormal)
        state.targeting.hitNormal = hitNormal
    else
        state.targeting.surfaceType = nil
        state.targeting.hitNormal = nil
    end

    local targetType = Targeting.getTargetType(
        hitObject,
        state.targeting.surfaceType,
        hitPos,
        hitNormal,
        state.targeting.cameraPos,
        state.targeting.cameraPitch
    )
    state.targeting.lastTargetType = targetType
    Reticle:update(true, targetType, range)

    debugPrint("Target:", targetType, "Distance:", range)
end

local function clearHit()
    state.targeting.impact = nil
    state.targeting.range = nil
    state.targeting.surfaceType = nil
    state.targeting.hitNormal = nil
    state.targeting.lastTargetType = "none"
    Reticle:update(false, "none", nil)
end

-- SharedRay delivery. `result` is a live view; copy fields, never keep it.
local function onSharedRayResult(result)
    if state.mode ~= HookshotState.DRAWN then return end

    frameCounter = frameCounter + 1

    -- Full reclassification only every RAYCAST_THROTTLE deliveries.
    if frameCounter - state.targeting.lastRaycastFrame < RAYCAST_THROTTLE then
        if state.targeting.impact then
            Reticle:update(true, state.targeting.lastTargetType, state.targeting.range)
        else
            Reticle:update(false, "none", nil)
        end
        return
    end
    state.targeting.lastRaycastFrame = frameCounter

    state.targeting.cameraPos, state.targeting.cameraV, state.targeting.cameraYaw, state.targeting.cameraPitch = Targeting.getCameraDirData()

    local hit = result.hit
    local hitPos = result.hitPos
    local hitObject = result.hitObject
    local distance = result.distance

    if hit and hitPos and distance and distance <= settings.maxRange() then
        local range = distance

        -- A rendering ray can miss thin items and actors; check the aim cone.
        if not isGrabbable(hitObject) then
            local fallbackTarget, fallbackDist = Targeting.findGrabbableNearAim(
                state.targeting.cameraPos,
                state.targeting.cameraV,
                range + 100  -- Check slightly beyond the hit point
            )

            if fallbackTarget and fallbackDist < range then
                hitObject = fallbackTarget
                hitPos = fallbackTarget.position
                range = fallbackDist
                debugPrint("Using fallback target:", fallbackTarget.recordId)
            end
        end

        applyFreshHit(hitObject, hitPos, range)
    else
        -- No hit within range - still check for grabbables in range
        local fallbackTarget, fallbackDist = Targeting.findGrabbableNearAim(
            state.targeting.cameraPos,
            state.targeting.cameraV,
            settings.maxRange()
        )

        if fallbackTarget then
            state.targeting.impact = {
                hit = true,
                hitPos = fallbackTarget.position,
                hitObject = fallbackTarget,
            }
            state.targeting.range = fallbackDist
            state.targeting.surfaceType = nil
            state.targeting.hitNormal = nil

            local targetType = isActor(fallbackTarget) and "enemy" or "item"
            state.targeting.lastTargetType = targetType
            Reticle:update(true, targetType, fallbackDist)
            debugPrint("Fallback target (no raycast hit):", targetType, "Distance:", fallbackDist)
        else
            clearHit()
        end
    end
end

-- ==============================================
-- SHARED RAY ACTIVATION
-- ==============================================
-- In onActive, once the winning SharedRay copy is registered.
local function onActive()
    if not I.SharedRay then
        print("[HOOKSHOT] I.SharedRay interface not found - reticle targeting will not work. Make sure SharedRay_v2.lua is installed alongside this mod.")
        return
    end

    I.SharedRay.requestDistance(settings.maxRange())
    I.SharedRay.subscribe("OpenMWHookshot", onSharedRayResult)
end


-- ==============================================
-- RAGDOLL SEQUENCE MANAGEMENT
-- ==============================================
local function terminateHook(ragdoll)
    if not ragdoll then return end

    if not ragdoll.isFalling then
        ambient.stopSoundFile(settings.sounds.fire)
    end
end

-- Forward declaration for menu callback handler
local handleItemMenuAction

-- Forward declaration.
local beginHandoff

-- ==============================================
-- SEQUENCE COMPLETION HANDLER
-- ==============================================
-- Turns Physics.update() completion events into state transitions.
local function handleSequenceCompletion(event)
    local ragdoll = event.ragdoll

    if event.type == "ITEM_PULL_COMPLETE" then
        debugPrint("Item pull complete - opening item menu")
        ambient.stopSoundFile(settings.sounds.fire)

        state.itemMenu.item = ragdoll.target
        state.itemMenu.ragdoll = ragdoll
        setMode(HookshotState.ITEM_MENU)

        hookshotMenu.open(ragdoll.target, function(action)
            handleItemMenuAction(action, ragdoll)
        end)

    elseif event.type == "ITEM_DROP_COMPLETE" then
        debugPrint("Item drop complete - returning to IDLE state")
        if state.mode == HookshotState.FIRING or state.mode == HookshotState.ITEM_MENU then
            setMode(HookshotState.IDLE)
        end

    elseif event.type == "SELF_PULL_COMPLETE" then
        local landingData = event.landingData
        debugPrint("Self-pull complete, surface type:", landingData.surfaceType)

        if landingData.isHang then
            local distanceToTarget = (self.position - landingData.position):length()
            local arrivalThreshold = 100

            if distanceToTarget > arrivalThreshold then
                debugPrint("Blocked before reaching rappel point - distance:", distanceToTarget)
                ui.showMessage("Hookshot blocked!")
                setMode(HookshotState.LANDING)
                state.landing.timeRemaining = LANDING_DURATION
                state.landing.targetYaw = landingData.yaw
            else
                debugPrint("Entering HANGING state (distance to target:", distanceToTarget, ")")
                state.hanging.position = landingData.position
                state.hanging.yaw = landingData.yaw
                state.hanging.anchorPosition = landingData.anchorPosition or landingData.position
                state.hanging.currentRopeLength = 0
                state.hanging.levitationApplied = false
                state.hanging.pitchOverride = 0
                state.hanging.isMoving = false
                if state.rope.active then
                    state.rope.phase = ROPE_PHASE_HANGING
                    state.rope.anchorPosition = state.hanging.anchorPosition
                    state.rope.target = nil
                    state.rope.targetOffset = nil
                    state.rope.pullsTarget = false
                end
                -- Set before setMode so the first hang pose is idle.
                setMode(HookshotState.HANGING)

                local activeEffects = types.Actor.activeEffects(self)
                if activeEffects then
                    activeEffects:modify(RAPPEL_LEVITATION_MAGNITUDE, core.magic.EFFECT_TYPE.Levitate)
                    state.hanging.levitationApplied = true
                    debugPrint("Levitation applied for hanging state")
                end

                setMovementControlsOverridden(true)
                self.controls.yawChange = 0
                self.controls.pitchChange = 0

                setCombatControlsSuppressed(true)

                ui.showMessage("W to ascend, S to descend, Space to drop")
            end
        elseif event.handoff then
            -- Released short of the aim point: finish with engine movement.
            beginHandoff(event.handoff, landingData)
        else
            debugPrint("Entering LANDING state")
            setMode(HookshotState.LANDING)
            state.landing.timeRemaining = LANDING_DURATION
            state.landing.targetYaw = landingData.yaw
        end

        terminateHook(ragdoll)

    elseif event.type == "SEQUENCE_COMPLETE" then
        terminateHook(ragdoll)
        -- Actor pulls: drop the rope before ALL_COMPLETE.
        endActiveRope()

    elseif event.type == "ALL_COMPLETE" then
        if state.mode == HookshotState.FIRING then
            debugPrint("All ragdoll sequences completed - entering LANDING state")
            setMode(HookshotState.LANDING)
            state.landing.timeRemaining = LANDING_DURATION
            state.landing.targetYaw = nil
        end
    end
end

-- ==============================================
-- ITEM MENU ACTION HANDLER
-- ==============================================
handleItemMenuAction = function(action, ragdoll)
    debugPrint("Item menu action:", action)

    local item = state.itemMenu.item

    if action == 'take' then
        if item and item:isValid() then
            core.sendGlobalEvent('HookshotInventoryAction', {
                action = 'take',
                object = item,
                actor = self
            })
        end
        Physics.removeByTarget(item)
        setMode(HookshotState.IDLE)

    else
        -- Anything but take: let it fall. FIRING only if a drop was really queued,
        -- since only its completion event leaves FIRING.
        local dropping = ragdoll and Physics.addSequence(ragdoll, Physics.createDropSequence())
        if dropping then
            setMode(HookshotState.FIRING)  -- monitor the drop
        else
            debugPrint("Item drop could not be queued; returning to IDLE directly")
            setMode(HookshotState.IDLE)
        end
    end

    state.itemMenu.item = nil
    state.itemMenu.ragdoll = nil
end

-- ==============================================
-- LANDING AND HANGING STATE UPDATES
-- ==============================================
-- Forward declaration.
local releaseFromHang

local function updateLandingState(deltaSeconds)
    if state.mode ~= HookshotState.LANDING then return end

    -- Suppress input while teleport physics settles.
    self.controls.movement = 0
    self.controls.sideMovement = 0
    self.controls.jump = false

    state.landing.timeRemaining = state.landing.timeRemaining - deltaSeconds

    if state.landing.timeRemaining <= 0 then
        debugPrint("Landing state complete, returning to IDLE")
        setMode(HookshotState.IDLE)
        state.landing.timeRemaining = 0
        state.landing.targetYaw = nil
    end
end

-- ==============================================
-- GRAPPLE HANDOFF
-- ==============================================
-- The drag releases short of the aim point and engine movement finishes it.
-- See README. handoffVector: world-space target minus position.
beginHandoff = function(handoffVector, landingData)
    local aimPos = (landingData and landingData.groundPosition) or (self.position + handoffVector)

    -- Horizontal only; vertical is gravity's.
    local flat = util.vector3(handoffVector.x, handoffVector.y, 0)
    local flatLen = flat:length()
    if flatLen > 0.01 then
        state.handoff.direction = flat:normalize()
    else
        state.handoff.direction = nil
    end

    state.handoff.targetPos = aimPos
    state.handoff.timeRemaining = HANDOFF_DURATION

    -- Jump only if grounded.
    local groundProbe = nearby.castRay(
        self.position + util.vector3(0, 0, 8),
        self.position - util.vector3(0, 0, HANDOFF_GROUND_PROBE),
        { collisionType = HOOKSHOT_PHY, ignore = self }
    )
    state.handoff.jumpPending = groundProbe.hit or false

    setMode(HookshotState.HANDOFF)
    debugPrint("Handoff begun - remaining =", handoffVector:length(),
               "grounded =", tostring(state.handoff.jumpPending))
end

local function endHandoff()
    state.handoff.timeRemaining = 0
    state.handoff.direction = nil
    state.handoff.targetPos = nil
    state.handoff.jumpPending = false
    -- Straight to IDLE: LANDING would zero the momentum.
    setMode(HookshotState.IDLE)
end

local function updateHandoffState(deltaSeconds)
    if state.mode ~= HookshotState.HANDOFF then return end

    if state.handoff.jumpPending then
        self.controls.jump = true
        state.handoff.jumpPending = false
    end

    local dir = state.handoff.direction
    if dir then
        -- World direction into the actor's frame; the camera stays free.
        local yaw = self.rotation:getYaw()
        local sinYaw, cosYaw = math.sin(yaw), math.cos(yaw)
        self.controls.movement = dir.x * sinYaw + dir.y * cosYaw
        self.controls.sideMovement = dir.x * cosYaw - dir.y * sinYaw
        self.controls.run = true
    end

    -- Ends early once over the target.
    if state.handoff.targetPos then
        local toTarget = state.handoff.targetPos - self.position
        local flatDist = util.vector3(toTarget.x, toTarget.y, 0):length()
        if flatDist < HANDOFF_ARRIVAL then
            debugPrint("Handoff complete - arrived, flatDist =", flatDist)
            endHandoff()
            return
        end
    end

    state.handoff.timeRemaining = state.handoff.timeRemaining - deltaSeconds
    if state.handoff.timeRemaining <= 0 then
        debugPrint("Handoff complete - window expired")
        endHandoff()
    end
end

-- Track Jump trigger for rappel release (Jump is a built-in trigger)
local jumpPressedForRappel = false

local function updateHangingState(deltaSeconds)
    if state.mode ~= HookshotState.HANGING then return end

    -- W/S range actions, or the custom boolean actions.
    local moveUpBuiltin = input.getRangeActionValue('MoveForward') > 0
    local moveDownBuiltin = input.getRangeActionValue('MoveBackward') > 0
    local moveUpCustom = input.getBooleanActionValue('HookshotRappelUp')
    local moveDownCustom = input.getBooleanActionValue('HookshotRappelDown')
    local releaseCustom = input.getBooleanActionValue('HookshotRappelRelease')

    local moveUp = moveUpBuiltin or moveUpCustom
    local moveDown = moveDownBuiltin or moveDownCustom

    local releasePressed = jumpPressedForRappel or releaseCustom

    -- Guarded: the arguments are built even when debug is off.
    if settings.debugMode() then
        debugPrint(string.format("RAPPEL Up=%s Down=%s Release=%s (builtinUp=%.1f builtinDown=%.1f customUp=%s customDown=%s)",
            tostring(moveUp), tostring(moveDown), tostring(releasePressed),
            input.getRangeActionValue('MoveForward'), input.getRangeActionValue('MoveBackward'),
            tostring(moveUpCustom), tostring(moveDownCustom)))
    end

    if releasePressed then
        jumpPressedForRappel = false  -- Reset the Jump trigger flag
        debugPrint("Release detected in updateHangingState - releasing from hang")
        releaseFromHang()
        return
    end

    self.controls.sideMovement = 0
    self.controls.movement = 0

    local currentPos = self.position
    local anchorPos = state.hanging.anchorPosition
    if not anchorPos then
        debugPrint("ERROR: No anchor position in hanging state")
        return
    end

    local currentRopeLength = (anchorPos - currentPos):length()
    state.hanging.currentRopeLength = currentRopeLength

    if moveUp then
        debugPrint("moveUp detected, attempting to ascend")
        -- Pose follows the key, even when blocked.
        state.hanging.pitchOverride = -1.0
        state.hanging.isMoving = true

        -- Clamp the head, not the feet, against the anchor.
        local playerZ = currentPos.z
        local anchorZ = anchorPos.z
        local headZ = playerZ + PLAYER_HEIGHT
        local maxStep = (anchorZ - RAPPEL_HEAD_CLEARANCE) - headZ

        if maxStep <= 0 then
            debugPrint("At anchor height, cannot ascend further (headZ =", headZ, "anchorZ =", anchorZ, ")")
        else
            local step = math.min(settings.rappelClimbSpeed() * deltaSeconds, maxStep)

            -- Headroom for geometry other than the anchor.
            local headroom = nearby.castRay(
                currentPos + util.vector3(0, 0, PLAYER_HEIGHT * 0.5),
                currentPos + util.vector3(0, 0, PLAYER_HEIGHT + step + RAPPEL_HEAD_CLEARANCE),
                {
                    collisionType = HOOKSHOT_PHY,
                    ignore = self
                }
            )

            if headroom.hit then
                local allowed = (headroom.hitPos.z - RAPPEL_HEAD_CLEARANCE) - headZ
                step = math.min(step, math.max(allowed, 0))
                debugPrint("Headroom limited ascent, step =", step)
            end

            if step <= 0 then
                debugPrint("Blocked overhead, cannot ascend further")
            else
                local newPos = currentPos + util.vector3(0, 0, step)
                core.sendGlobalEvent('ragdollTeleport', { object = self.object, newPos = newPos })
                debugPrint("Ascending, step =", step)
            end
        end

    elseif moveDown then
        debugPrint("moveDown detected, attempting to descend")
        state.hanging.pitchOverride = 1.0
        state.hanging.isMoving = true

        if currentRopeLength >= settings.maxRange() then
            debugPrint("At max rope length, cannot descend further")
        else
            local groundCheck = nearby.castRay(
                currentPos,
                currentPos - util.vector3(0, 0, 100),
                {
                    collisionType = HOOKSHOT_PHY,
                    ignore = self
                }
            )

            if groundCheck.hit and (currentPos.z - groundCheck.hitPos.z) < 50 then
                debugPrint("Near ground, cannot descend further")
            else
                local step = settings.rappelClimbSpeed() * deltaSeconds
                if groundCheck.hit then
                    step = math.min(step, (currentPos.z - groundCheck.hitPos.z) - 50)
                end
                step = math.max(step, 0)
                local newPos = currentPos - util.vector3(0, 0, step)
                core.sendGlobalEvent('ragdollTeleport', { object = self.object, newPos = newPos })
                debugPrint("Descending, step =", step)
            end
        end

    else
        state.hanging.pitchOverride = 0
        state.hanging.isMoving = false
    end

    -- Per frame: the hang pose follows the keys, not a mode change.
    Anim.updateHanging(state.hanging)
end

local function clearHangingLevitation()
    if state.hanging.levitationApplied then
        local activeEffects = types.Actor.activeEffects(self)
        if activeEffects then
            activeEffects:modify(-RAPPEL_LEVITATION_MAGNITUDE, core.magic.EFFECT_TYPE.Levitate)
            debugPrint("Levitation cleared from hanging state")
        end
        state.hanging.levitationApplied = false
    end
end

releaseFromHang = function()
    if state.mode ~= HookshotState.HANGING then return end

    debugPrint("Releasing from hang")

    clearHangingLevitation()
    setMovementControlsOverridden(false)

    setCombatControlsSuppressed(false)

    setMode(HookshotState.LANDING)
    state.landing.timeRemaining = LANDING_DURATION
    state.landing.targetYaw = state.hanging.yaw

    state.hanging.position = nil
    state.hanging.yaw = nil
    state.hanging.anchorPosition = nil
    state.hanging.currentRopeLength = 0
    state.hanging.pitchOverride = 0
    state.hanging.isMoving = false

    ambient.playSoundFile(settings.sounds.toggle)
end


-- ==============================================
-- ON_UPDATE LOGIC
-- ==============================================
local function onUpdate(deltaSeconds)
    if pendingAnimReset then
        pendingAnimReset = false
        if state.mode == HookshotState.IDLE then Anim.forceReset() end
    end

    local isPaused = state.mode == HookshotState.ITEM_MENU
    local events = Physics.update(deltaSeconds, isPaused)
    for _, event in ipairs(events) do
        handleSequenceCompletion(event)
    end

    updateHandoffState(deltaSeconds)
    updateLandingState(deltaSeconds)
    updateHangingState(deltaSeconds)
    updateActiveRope(deltaSeconds)
    updateReticleVisibility(deltaSeconds)
end

local function onSave()
    -- The hook is not persisted; only what onLoad needs to undo overrides.
    return {
        version = 1,
        combatControlsSuppressed = state.ownedOverrides.combatControlsSuppressed,
        movementControlsOverridden = state.ownedOverrides.movementControlsOverridden,
        levitationApplied = state.hanging.levitationApplied,
        animationActive = Anim.isActive(),
        crosshairHidden = Reticle:isVisible(),
    }
end

local function onLoad(savedData)
    local saved = type(savedData) == "table" and savedData or {}

    -- Live flags too, in case onLoad runs on an existing instance.
    local restoreCombatControls = saved.combatControlsSuppressed == true
        or state.ownedOverrides.combatControlsSuppressed
    local restoreMovementControls = saved.movementControlsOverridden == true
        or state.ownedOverrides.movementControlsOverridden
    local removeLevitation = saved.levitationApplied == true
        or state.hanging.levitationApplied
    local resetAnimation = saved.animationActive == true or Anim.isActive()
    local restoreCrosshair = saved.crosshairHidden == true or Reticle:isVisible()

    ambient.stopSoundFile(settings.sounds.fire)

    if removeLevitation then
        local activeEffects = types.Actor.activeEffects(self)
        if activeEffects then
            activeEffects:modify(-RAPPEL_LEVITATION_MAGNITUDE, core.magic.EFFECT_TYPE.Levitate)
        end
    end
    state.hanging.levitationApplied = false

    if restoreMovementControls then
        setMovementControlsOverridden(false)
    end
    if restoreCombatControls then
        setCombatControlsSuppressed(false)
    end

    -- Deferred: the animation object may not exist while loading.
    pendingAnimReset = pendingAnimReset or resetAnimation
    state.mode = HookshotState.IDLE
    state.ownedOverrides.combatControlsSuppressed = false
    state.ownedOverrides.movementControlsOverridden = false
    state.hanging.position = nil
    state.hanging.yaw = nil
    state.hanging.anchorPosition = nil
    state.hanging.currentRopeLength = 0
    state.hanging.pitchOverride = 0
    state.hanging.isMoving = false
    Reticle:hide()
    if restoreCrosshair then
        -- A recreated Reticle cannot unhide the old crosshair itself.
        camera.showCrosshair(true)
    end
    clearRopeState()
end

-- ==============================================
-- HOOKSHOT ACTIONS
-- ==============================================
local function pullHookedObject(target, dirVector)
    if not target or not dirVector or not validObjectPosition(target) then
        return false
    end

    Physics.removeByTarget(target)

    local camZ = camera.getPosition().z
    local targetZ = isActor(target) and (camZ + self.position.z) / 2 or camZ

    local targetPos = util.vector3(
        self.position.x,
        self.position.y,
        targetZ
    ) + dirVector * PULL_OFFSET

    local isItem = isCarriableItem(target)
    debugPrint("Pulling object:", target.recordId, "isItem:", tostring(isItem))

    Physics.addRagdoll(Physics.createRagdollData(
        target,
        Physics.getBoundingData(target),
        { Physics.createPullSequence(targetPos, nil, nil, isItem) }
    ))
    return true
end

local function hookToWorldObject(hitPos, hitNormal, approachDir, playerYaw, cameraPos, cameraPitch)
    if not hitPos or not hitNormal or not approachDir then return false end

    local surfaceType = orient.classifySurface(hitNormal)

    -- Rappel needs clearance AND a ledge edge.
    local rappelEligible = Targeting.checkRappelClearance(hitPos, hitNormal)
                           and Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType)

    local landingData = orient.calculateLanding(hitPos, hitNormal, approachDir, playerYaw, rappelEligible)
    landingData.anchorPosition = hitPos

    -- Non-rappel grapples aim above the landing and release short; a hang must arrive.
    local handoffDistance = 0
    if not landingData.isHang then
        local rise = settings.handoffRise()
        if rise > 0 then
            landingData.position = landingData.position + util.vector3(0, 0, rise)
        end
        handoffDistance = settings.handoffDistance()
        landingData.groundPosition = landingData.position - util.vector3(0, 0, rise)
    end

    debugPrint("Hook to world:",
        "surface =", landingData.surfaceType,
        "isHang =", tostring(landingData.isHang),
        "isRappelPoint =", tostring(landingData.isRappelPoint),
        "rappelEligible =", tostring(rappelEligible),
        "handoff =", handoffDistance,
        "offset from hit =", (landingData.position - hitPos):length()
    )

    Physics.addRagdoll(Physics.createRagdollData(
        self,
        Physics.getBoundingData(self),
        { Physics.createSelfPullSequence(landingData.position, nil, nil, landingData, handoffDistance) }
    ))
    return true
end

-- Called once when the outbound tip arrives; pull physics starts here.
attachTravelingHook = function(anchor)
    local rope = state.rope
    if not rope.active or rope.phase ~= ROPE_PHASE_OUTBOUND then return end

    local attachedPosition = copyVector3(anchor)
    if not attachedPosition then
        abortActiveHook("invalid_anchor")
        return
    end

    rope.tipPosition = attachedPosition
    rope.anchorPosition = attachedPosition

    if rope.pullsTarget then
        if not validObjectPosition(rope.target) then
            abortActiveHook("target_lost_before_attachment")
            return
        end

        rope.phase = ROPE_PHASE_TARGET_PULL
        debugPrint("Hook attached - pulling target to player")
        if not pullHookedObject(rope.target, rope.approachDir) then
            abortActiveHook("target_pull_failed")
        end
        return
    end

    rope.phase = ROPE_PHASE_SELF_PULL
    debugPrint("Hook attached - pulling player to world")
    if not hookToWorldObject(
        attachedPosition,
        rope.hitNormal,
        rope.approachDir,
        rope.playerYaw,
        rope.cameraPos,
        rope.cameraPitch
    ) then
        abortActiveHook("self_pull_failed")
    end
end

-- ==============================================
-- HOOKSHOT STATE MANAGEMENT
-- ==============================================
local function drawHookshot()
    debugPrint("=== drawHookshot called ===")
    ambient.playSoundFile(settings.sounds.toggle)
    ambient.playSoundFile(settings.sounds.set)

    setMode(HookshotState.DRAWN)
    debugPrint("State changed to DRAWN")
end

local function deactivateHookshotDrawnState()
    debugPrint("=== deactivateHookshotDrawnState called ===")
    Reticle:hide()

    setMode(HookshotState.IDLE)
    debugPrint("State changed to IDLE")
end

local function fireHookshot()
    debugPrint("=== fireHookshot called ===")

    -- Every refusal returns before any sound.
    if not state.targeting.impact then
        ui.showMessage("No target in hookshot range")
        debugPrint("No target - aborting fire")
        return
    end

    local target = state.targeting.impact.hitObject
    local hitPos = state.targeting.impact.hitPos
    local approachDir = state.targeting.cameraV
    local playerYaw = state.targeting.cameraYaw or camera.getYaw()

    -- Re-resolved: the inventory can change while drawn.
    local caps = refreshCapabilities()

    if not caps.glove then
        ui.showMessage("You need to equip a hookshot")
        deactivateHookshotDrawnState()
        return
    end

    if isCarriableItem(target) and not caps.itemTargeting then
        ui.showMessage("Your hookshot can't draw items to you")
        debugPrint("Item targeting locked - aborting fire")
        return
    end

    local pullsTarget = isGrabbable(target)
    local hitNormal = nil
    debugPrint("Target found, isGrabbable =", pullsTarget)

    if not pullsTarget then
        hitNormal = Targeting.probeSurfaceNormal(hitPos, approachDir)
        local surfaceType = orient.classifySurface(hitNormal)
        debugPrint("Surface type:", surfaceType, "Normal:", orient.normalToString(hitNormal))
    end

    local travelStarted = beginHookTravel({
        target = target,
        hitPosition = hitPos,
        hitNormal = hitNormal,
        approachDir = approachDir,
        playerYaw = playerYaw,
        cameraPos = state.targeting.cameraPos,
        cameraPitch = state.targeting.cameraPitch,
        pullsTarget = pullsTarget,
    })
    if not travelStarted then
        ui.showMessage("Hookshot target is no longer available")
        debugPrint("Unable to begin outbound hook travel")
        return
    end

    ambient.playSoundFile(settings.sounds.fire)
    ambient.playSoundFile(settings.sounds.target)

    Reticle:hide()
    setMode(HookshotState.FIRING)
    debugPrint("State changed to FIRING (outbound)")
end

local function trySheathHookshot()
    if state.mode ~= HookshotState.DRAWN then return end

    ambient.playSoundFile(settings.sounds.toggle)
    deactivateHookshotDrawnState()
end

local function tryActivateHookshot()
    debugPrint("=== tryActivateHookshot called, current mode =", state.mode)

    if state.mode == HookshotState.DRAWN then
        debugPrint("Mode is DRAWN - sheathing hookshot")
        trySheathHookshot()
    elseif state.mode == HookshotState.IDLE then
        local caps = refreshCapabilities()
        if not caps.glove then
            debugPrint("Mode is IDLE - hookshot not equipped, ignoring activation")
            ui.showMessage("You need to equip a hookshot")
            return
        end
        debugPrint("Mode is IDLE - drawing hookshot (item targeting =", tostring(caps.itemTargeting), ")")
        drawHookshot()
    elseif state.mode == HookshotState.HANGING then
        debugPrint("Mode is HANGING - cannot use hookshot while hanging")
        ui.showMessage("Release from hang first (Space)")
    elseif state.mode == HookshotState.ITEM_MENU then
        debugPrint("Mode is ITEM_MENU - ignoring activation (menu is open)")
    else
        debugPrint("Mode is", state.mode, "- ignoring activation")
    end
end

-- ==============================================
-- INPUT HANDLERS (Trigger System)
-- ==============================================

input.registerTriggerHandler('HookshotActivate', async:callback(function()
    debugPrint("HookshotActivate trigger FIRED!")
    tryActivateHookshot()
end))

input.registerTriggerHandler('HookshotSheath', async:callback(function()
    debugPrint("HookshotSheath trigger FIRED!")
    trySheathHookshot()
end))

-- Fire on the Attack/Use action; called on change, so once per press.
input.registerActionHandler('Use', async:callback(function(value)
    if value and state.mode == HookshotState.DRAWN then
        debugPrint("Use (Attack) pressed while DRAWN - firing hookshot")
        fireHookshot()
    end
end))


-- Jump trigger handler for hang release (Space to drop - built-in fallback)
input.registerTriggerHandler('Jump', async:callback(function()
    if state.mode == HookshotState.HANGING then
        debugPrint("Jump trigger detected while hanging - setting release flag")
        jumpPressedForRappel = true
    end
end))

-- Esc or another menu leaves the item menu's Interface mode without a click.
local function onUiModeChanged(data)
    if state.mode ~= HookshotState.ITEM_MENU then return end
    if data.newMode ~= 'Interface' and hookshotMenu.isOpen() then
        hookshotMenu.cancel()
    end
end

return {
    engineHandlers = {
        onActive = onActive,
        onUpdate = onUpdate,
        onLoad = onLoad,
        onSave = onSave,
    },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
    },
}

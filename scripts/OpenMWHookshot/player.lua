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
-- Falling pose played on a hooked actor while it is dragged in. Duration is a
-- failsafe: the actor script cancels on its own, so a dead player script cannot
-- leave an NPC stuck in the pose.
-- Tether and swing tuning that is not worth a setting.
local TETHER_MIN_LENGTH = 120        -- Never ratchet below this, or the rope locks you in place
local SWING_DAMPING = 0.35           -- Per-second angular damping
local SWING_MIN_OMEGA = 0.25         -- Below this at the bottom the swing just hangs
local SWING_RELEASE_PAST = 0.20      -- Radians past the low point before release
local SWING_MAX_TIME = 6.0           -- Failsafe
-- How far below the last ground the player must be before a swing starts.
-- isOnGround alone is also false for an ordinary jump, and a jump under the
-- anchor became a 6 s pendulum hang ending in a launch. A jump comes back down
-- to the height it left; a ledge does not. 40 is reached ~0.14 s into a fall.
local SWING_START_DROP = 40
local LAUNCH_TIMEOUT = 2.5
local DART_MIN_MOVE = 2.0

local HOOKED_ACTOR_EVENT = "Dubious_HookShot_ActorHooked"
local ACTOR_FALL_DURATION = 1.5

local LANDING_DURATION = 0.4        -- How long the landing state lasts (physics settle time)
local RAPPEL_LEVITATION_MAGNITUDE = 10   -- Levitation effect magnitude (same as ladder mod)
local PULL_OFFSET = 50              -- Hardcoded offset for pull target position

-- Handoff: engine movement covers the last stretch after the drag releases.
local HANDOFF_DURATION = 0.8        -- Max length of the handoff window (seconds)
local HANDOFF_ARRIVAL = 10          -- Horizontal distance to target that ends the window early
local HANDOFF_GROUND_PROBE = 24     -- Downward probe length used to decide whether a jump would take

-- Rappel climb stops with the head this far below the anchor.
local RAPPEL_HEAD_CLEARANCE = 24
local PLAYER_HEIGHT = U.PLAYER_HEIGHT

local ROPE_PHASE_OUTBOUND = "OUTBOUND"
local ROPE_PHASE_SELF_PULL = "SELF_PULL"
local ROPE_PHASE_TARGET_PULL = "TARGET_PULL"
local ROPE_PHASE_HANGING = "HANGING"
local ROPE_PHASE_TETHER = "TETHER"

-- ==============================================
-- STATE MANAGEMENT
-- ==============================================
local HookshotState = {
    IDLE = "IDLE",
    DRAWN = "DRAWN",
    FIRING = "FIRING",
    HANDOFF = "HANDOFF",      -- Drag released; engine movement covers the last stretch
    TETHERED = "TETHERED",    -- Delayed firing: dart planted, rope held, player free
    SWINGING = "SWINGING",    -- Powered pendulum on a tethered rappel anchor
    LAUNCH = "LAUNCH",        -- Ballistic arc out of a swing release
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
        grapple = false,
        item = false,
        npc = false,
        special = false,
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

    -- Delayed firing. length ratchets down to the closest approach, so moving
    -- in shortens the rope and brings the break point with it.
    tether = {
        anchor = nil,
        length = 0,
        rappelAnchor = false,
        groundZ = nil,      -- height of the last ground stood on while tethered
    },

    -- Pendulum in the vertical plane through the anchor. theta is measured from
    -- straight down, right is the in-plane horizontal unit vector.
    swing = {
        anchor = nil,
        radius = 0,
        theta = 0,
        omega = 0,
        right = nil,
        pastBottom = 0,
        levitationApplied = false,
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
        delayed = false,
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

local dartLastPos = nil

-- The dart is an ordinary object the global script moves, because no Lua call
-- launches a projectile. It rides the same point the rope's far end is at.
local function publishDart(tipPosition, fromPosition)
    if not settings.dartVisible() then return end

    local to = copyVector3(tipPosition)
    if not to then return end

    if dartLastPos then
        local dx, dy, dz = to.x - dartLastPos.x, to.y - dartLastPos.y, to.z - dartLastPos.z
        if (dx * dx + dy * dy + dz * dz) <= (DART_MIN_MOVE * DART_MIN_MOVE) then return end
    end
    dartLastPos = to

    -- Point it along the rope. Sign of the pitch term is unverified in game.
    local rotation = nil
    local from = fromPosition and copyVector3(fromPosition)
    if from then
        local dir = to - from
        local flat = util.vector3(dir.x, dir.y, 0):length()
        if flat > 0.01 or math.abs(dir.z) > 0.01 then
            local yaw = math.atan2(dir.x, dir.y)
            local pitch = -math.atan2(dir.z, flat)
            rotation = util.transform.rotateZ(yaw) * util.transform.rotateX(pitch)
        end
    end

    core.sendGlobalEvent('HookshotDartUpdate', {
        owner = self.object,
        pos = to,
        rotation = rotation,
    })
end

local function endDart()
    if dartLastPos == nil then return end
    dartLastPos = nil
    core.sendGlobalEvent('HookshotDartEnd', { owner = self.object })
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
    rope.delayed = false
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
    endDart()
    clearRopeState()
end

-- The dart is published before the beam interface is consulted: it is a real
-- object, so it must not depend on the optional rope visual being installed.
local function publishRope(endPosition)
    if not state.rope.active then return end

    local from = ropeShoulderOrigin()
    local to = copyVector3(endPosition)
    if not from or not to then return end

    publishDart(to, from)

    local updateRope = ropeInterfaceMethod("updateRope")
    if not updateRope then return end
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
    rope.delayed = spec.delayed or false
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

    -- Fail-safe: only these states keep a rope.
    if state.mode ~= HookshotState.FIRING
        and state.mode ~= HookshotState.HANGING
        and state.mode ~= HookshotState.TETHERED
        and state.mode ~= HookshotState.SWINGING
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

-- ==============================================
-- PARKOURWIND FLOW
-- ==============================================
-- FLOW reads any not-grounded player as mid-jump, and while the hookshot
-- carries, swings or hangs the player that is all FLOW sees. Unasked it ran
-- its airborne ladder on them: the Jump that drops a hang chained into a FLOW
-- ledge grab, a long pull played Skydive and landed as a knockdown over the
-- LANDING pose. I.Flow.yield stands FLOW down while the hookshot holds the
-- player; absent FLOW, nothing happens.
--
-- Not TETHERED: the dart is planted but the player walks, jumps and vaults
-- freely, so FLOW is welcome there.
local FLOW_OWNER = 'Hookshot'
local FLOW_HOLDING = {
    [HookshotState.HANDOFF] = true, [HookshotState.SWINGING] = true,
    [HookshotState.LAUNCH] = true,  [HookshotState.LANDING] = true,
    [HookshotState.HANGING] = true,
}
local flowYielded = false

local function holdsPlayer()
    if FLOW_HOLDING[state.mode] then return true end
    -- FIRING covers a pull of an item toward a standing player too; only a
    -- self-pull moves the player.
    if state.mode == HookshotState.FIRING and state.rope.phase == ROPE_PHASE_SELF_PULL then
        return true
    end
    return state.ownedOverrides.movementControlsOverridden == true
end

-- `taking` forces a yield ahead of a hold that holdsPlayer cannot see yet:
-- the override write below. Idempotent, so it is called freely.
local function syncFlowYield(taking)
    local want = taking == true or holdsPlayer()
    if want == flowYielded then return end
    flowYielded = want
    local F = I.Flow
    if not (F and F.yield and F.resume) then return end
    if want then F.yield(FLOW_OWNER) else F.resume(FLOW_OWNER) end
end

local function setMovementControlsOverridden(overridden)
    -- BEFORE the write: the flag is shared, FLOW releases its own hold on it
    -- as it stands down, and that release must not land after ours.
    if overridden then syncFlowYield(true) end
    Controls.overrideMovementControls(overridden)
    state.ownedOverrides.movementControlsOverridden = overridden
end

-- Single choke point for state.mode, so playerAnim sees every transition.
local function setMode(newMode)
    if state.mode == newMode then return end

    -- The rope survives only while firing, hanging or tethered.
    if state.rope.active
        and newMode ~= HookshotState.FIRING
        and newMode ~= HookshotState.HANGING
        and newMode ~= HookshotState.TETHERED
        and newMode ~= HookshotState.SWINGING
    then
        endActiveRope()
    end

    local oldMode = state.mode
    state.mode = newMode
    syncFlowYield()
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
    if settings.debugMode() then Anim.verifyGroups() end

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

    elseif event.type == "LAUNCH_COMPLETE" then
        debugPrint("Launch arc complete - entering LANDING")
        setMode(HookshotState.LANDING)
        state.landing.timeRemaining = LANDING_DURATION
        state.landing.targetYaw = nil

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

-- ==============================================
-- TETHER AND SWING
-- ==============================================
local SWING_GRAVITY = 9.80665 * 400

local function applySwingLevitation()
    if state.swing.levitationApplied then return end
    local fx = types.Actor.activeEffects(self)
    if not fx then return end
    fx:modify(RAPPEL_LEVITATION_MAGNITUDE, core.magic.EFFECT_TYPE.Levitate)
    state.swing.levitationApplied = true
end

local function clearSwingLevitation()
    if not state.swing.levitationApplied then return end
    state.swing.levitationApplied = false
    local fx = types.Actor.activeEffects(self)
    if fx then
        fx:modify(-RAPPEL_LEVITATION_MAGNITUDE, core.magic.EFFECT_TYPE.Levitate)
    end
end

local function clearTetherState()
    state.tether.anchor = nil
    state.tether.length = 0
    state.tether.rappelAnchor = false
    state.tether.prevPos = nil
    state.tether.groundZ = nil
    state.swing.anchor = nil
    state.swing.right = nil
    state.swing.radius = 0
    state.swing.theta = 0
    state.swing.omega = 0
    state.swing.elapsed = 0
    state.swing.armed = false
end

local function breakTether(reason)
    debugPrint("Tether broken:", reason or "unknown")
    clearSwingLevitation()
    clearTetherState()
    ambient.stopSoundFile(settings.sounds.fire)
    ambient.playSoundFile(settings.sounds.toggle)
    -- IDLE is not in setMode's keep-list, so this retracts the rope and dart.
    setMode(HookshotState.IDLE)
end

local function beginTether(anchorPos, rappelEligible)
    local anchor = copyVector3(anchorPos)
    if not anchor then return false end

    local dist = (self.position - anchor):length()
    state.tether.anchor = anchor
    state.tether.length = math.max(dist, TETHER_MIN_LENGTH)
    state.tether.rappelAnchor = rappelEligible and true or false
    state.tether.prevPos = self.position
    state.tether.groundZ = self.position.z

    state.rope.phase = ROPE_PHASE_TETHER
    setMode(HookshotState.TETHERED)
    ui.showMessage("Rope attached - fire again to reel in")
    debugPrint("Tethered at length", state.tether.length,
               "rappelAnchor =", tostring(state.tether.rappelAnchor))
    return true
end

local function beginLaunch(velocity)
    clearSwingLevitation()
    clearTetherState()
    endActiveRope()
    Physics.removeByTarget(self)
    Physics.addRagdoll(Physics.createRagdollData(
        self,
        Physics.getBoundingData(self),
        { Physics.createLaunchSequence(velocity, LAUNCH_TIMEOUT) }
    ))
    setMode(HookshotState.LAUNCH)
    debugPrint("Launched at", velocity:length())
end

-- Offset from the anchor for a pendulum angle measured from straight down.
local function swingOffset(right, radius, theta)
    return right * (radius * math.sin(theta))
         + util.vector3(0, 0, -radius * math.cos(theta))
end

local function releaseSwing()
    local sw = state.swing
    if not sw.right then
        breakTether("swing_without_plane")
        return
    end

    -- Tangent is the derivative of the offset in theta, signed by travel.
    local tangent = sw.right * math.cos(sw.theta)
                  + util.vector3(0, 0, math.sin(sw.theta))
    if sw.omega < 0 then tangent = tangent * -1 end

    local flat = util.vector3(tangent.x, tangent.y, 0)
    if flat:length() < 0.01 then flat = sw.right end
    flat = flat:normalize()

    beginLaunch(flat * settings.swingSpeed()
                + util.vector3(0, 0, settings.swingBoost()))
end

local function beginSwing(deltaSeconds)
    local anchor = state.tether.anchor
    if not anchor then return end

    local toPlayer = self.position - anchor
    local radius = toPlayer:length()
    if radius < TETHER_MIN_LENGTH then return end

    -- The swing plane is the vertical plane through the anchor and the player.
    local flat = util.vector3(toPlayer.x, toPlayer.y, 0)
    if flat:length() < 1 then
        local yaw = camera.getYaw()
        flat = util.vector3(math.sin(yaw), math.cos(yaw), 0)
    end
    local right = flat:normalize()

    local below = math.max(-toPlayer.z, 0.001)
    local side = toPlayer:dot(right)

    local sw = state.swing
    sw.anchor = anchor
    sw.radius = radius
    sw.right = right
    sw.theta = math.atan2(side, below)
    sw.elapsed = 0
    sw.armed = false

    -- Seed from the motion the player already had, so running off a ledge
    -- carries into the arc instead of starting from rest. No velocity getter,
    -- so this is differenced from the previous tethered position -- which is
    -- one FRAME of travel, so it is divided by the frame time to make a
    -- velocity. Without that the carried speed was 1/60th of the run's at 60fps.
    sw.omega = 0
    local prev = state.tether.prevPos
    if prev and deltaSeconds and deltaSeconds > 0 then
        local moved = self.position - prev
        local tangent = right * math.cos(sw.theta)
                      + util.vector3(0, 0, math.sin(sw.theta))
        sw.omega = moved:dot(tangent) / (radius * deltaSeconds)
    end

    applySwingLevitation()
    setMode(HookshotState.SWINGING)
    debugPrint("Swing begun radius", radius, "theta", sw.theta, "omega", sw.omega)
end

local function updateSwingState(deltaSeconds)
    if state.mode ~= HookshotState.SWINGING then return end

    local sw = state.swing
    if not sw.anchor or not sw.right then
        breakTether("swing_state_lost")
        return
    end

    -- Position-driven, so player input must not fight it.
    self.controls.movement = 0
    self.controls.sideMovement = 0
    self.controls.jump = false

    sw.elapsed = sw.elapsed + deltaSeconds
    if sw.elapsed > SWING_MAX_TIME then
        releaseSwing()
        return
    end

    local alpha = -(SWING_GRAVITY / sw.radius) * math.sin(sw.theta)
                  - SWING_DAMPING * sw.omega
    sw.omega = sw.omega + alpha * deltaSeconds

    local prevTheta = sw.theta
    sw.theta = sw.theta + sw.omega * deltaSeconds

    -- Arm the release on the pass through the low point, but only with enough
    -- speed to be worth launching; otherwise let it keep swinging.
    if prevTheta * sw.theta <= 0 and math.abs(sw.omega) >= SWING_MIN_OMEGA then
        sw.armed = true
    end

    if sw.armed and math.abs(sw.theta) >= SWING_RELEASE_PAST then
        releaseSwing()
        return
    end

    local newPos = sw.anchor + swingOffset(sw.right, sw.radius, sw.theta)

    local blocked = nearby.castRay(self.position, newPos, {
        collisionType = HOOKSHOT_PHY,
        ignore = self,
    })
    if blocked.hit then
        debugPrint("Swing hit geometry - releasing")
        releaseSwing()
        return
    end

    core.sendGlobalEvent('ragdollTeleport', { object = self.object, newPos = newPos })
end

local function updateTetherState(deltaSeconds)
    if state.mode ~= HookshotState.TETHERED then return end

    local anchor = state.tether.anchor
    if not anchor then
        breakTether("no_anchor")
        return
    end

    local dist = (self.position - anchor):length()

    -- Ratchet: the closest approach becomes the new length, so moving in
    -- shortens the rope and brings the break point with it.
    if dist < state.tether.length then
        state.tether.length = math.max(dist, TETHER_MIN_LENGTH)
        debugPrint("Tether shortened to", state.tether.length)
    end

    if dist > state.tether.length + settings.tetherGrace() then
        ui.showMessage("The rope snaps!")
        breakTether("overextended")
        return
    end

    local grounded = types.Actor.isOnGround(self)
    if grounded then
        state.tether.groundZ = self.position.z
    end

    -- Airborne AND fallen below the last ground: off a ledge, not a jump.
    local groundZ = state.tether.groundZ or self.position.z
    if settings.swingEnabled()
        and state.tether.rappelAnchor
        and not grounded
        and self.position.z < groundZ - SWING_START_DROP
    then
        beginSwing(deltaSeconds)
        return
    end

    state.tether.prevPos = self.position
end

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
    updateTetherState(deltaSeconds)
    updateSwingState(deltaSeconds)
    updateLandingState(deltaSeconds)
    updateHangingState(deltaSeconds)
    updateActiveRope(deltaSeconds)
    updateReticleVisibility(deltaSeconds)
    -- Catches every way out of a hold, including the ones that do not pass
    -- through setMode (a rope phase ending, an override released).
    syncFlowYield()
end

local function onSave()
    -- The hook is not persisted; only what onLoad needs to undo overrides.
    return {
        version = 1,
        combatControlsSuppressed = state.ownedOverrides.combatControlsSuppressed,
        movementControlsOverridden = state.ownedOverrides.movementControlsOverridden,
        levitationApplied = state.hanging.levitationApplied
            or state.swing.levitationApplied,
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
        or state.swing.levitationApplied
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
    state.swing.levitationApplied = false
    clearTetherState()

    if restoreMovementControls then
        setMovementControlsOverridden(false)
    end
    if restoreCombatControls then
        setCombatControlsSuppressed(false)
    end

    -- Deferred: the animation object may not exist while loading.
    pendingAnimReset = pendingAnimReset or resetAnimation
    state.mode = HookshotState.IDLE
    syncFlowYield()
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
        if isActor(rope.target) then
            rope.target:sendEvent(HOOKED_ACTOR_EVENT, { duration = ACTOR_FALL_DURATION })
        end
        if not pullHookedObject(rope.target, rope.approachDir) then
            abortActiveHook("target_pull_failed")
        end
        return
    end

    if rope.delayed then
        local surfaceType = orient.classifySurface(rope.hitNormal)
        local rappelEligible = rope.hitNormal
            and Targeting.checkRappelClearance(attachedPosition, rope.hitNormal)
            and Targeting.checkLedgeEdge(attachedPosition, rope.hitNormal,
                                         rope.cameraPos, rope.cameraPitch, surfaceType)
        if beginTether(attachedPosition, rappelEligible) then return end
        abortActiveHook("tether_failed")
        return
    end

    rope.phase = ROPE_PHASE_SELF_PULL
    syncFlowYield()
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

-- Second fire press: stop holding and reel in from wherever the rope now is.
local function retractTether()
    local anchor = state.tether.anchor
    if not anchor then return end

    local rope = state.rope
    clearSwingLevitation()
    clearTetherState()

    rope.phase = ROPE_PHASE_SELF_PULL
    setMode(HookshotState.FIRING)
    syncFlowYield()
    ambient.playSoundFile(settings.sounds.fire)
    debugPrint("Tether retracting")

    if not hookToWorldObject(
        anchor,
        rope.hitNormal,
        rope.approachDir,
        rope.playerYaw,
        rope.cameraPos,
        rope.cameraPitch
    ) then
        abortActiveHook("tether_retract_failed")
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

    if isCarriableItem(target) and not caps.item then
        ui.showMessage("Your hookshot can't draw items to you")
        debugPrint("Item gate locked - aborting fire")
        return
    end

    if isActor(target) and not caps.npc then
        ui.showMessage("Your hookshot can't pull creatures")
        debugPrint("Npc gate locked - aborting fire")
        return
    end

    if not isGrabbable(target) and not caps.grapple then
        ui.showMessage("Your hookshot can't pull you to that")
        debugPrint("Grapple gate locked - aborting fire")
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

    -- Delayed firing is for world geometry: a dart planted in a moving actor
    -- is a different feature.
    local delayed = settings.delayedFiring() and not pullsTarget

    local travelStarted = beginHookTravel({
        target = target,
        delayed = delayed,
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
    if state.mode == HookshotState.TETHERED or state.mode == HookshotState.SWINGING then
        breakTether("sheathed")
        return
    end
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
        debugPrint("Mode is IDLE - drawing hookshot (grapple =", tostring(caps.grapple),
                   "item =", tostring(caps.item), "npc =", tostring(caps.npc), ")")
        drawHookshot()
    elseif state.mode == HookshotState.TETHERED or state.mode == HookshotState.SWINGING then
        debugPrint("Mode is", state.mode, "- cutting the tether")
        trySheathHookshot()
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
    if not value then return end

    if state.mode == HookshotState.DRAWN then
        debugPrint("Use (Attack) pressed while DRAWN - firing hookshot")
        fireHookshot()
    elseif state.mode == HookshotState.TETHERED then
        debugPrint("Use (Attack) pressed while TETHERED - reeling in")
        retractTether()
    elseif state.mode == HookshotState.SWINGING then
        debugPrint("Use (Attack) pressed while SWINGING - releasing early")
        releaseSwing()
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

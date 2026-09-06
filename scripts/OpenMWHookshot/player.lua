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

-- Aliases for util functions (preserves existing call sites)
local isCarriableItem = U.isCarriableItem
local isActor = U.isActor
local isGrabbable = U.isGrabbable

-- Convenience alias for debug printing
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

-- Shared interfaces table (I.SharedRay, I.Controls, ...)
local I = require('openmw.interfaces')
---@cast I HookshotInterfaces

-- Controls interface for movement override (like ladder mod)
local Controls = I.Controls

-- Player type for control switches (preferred over deprecated input.setControlSwitch)
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

-- Handoff: the window after the grapple drag releases, during which the
-- player finishes the approach under normal engine movement.
local HANDOFF_DURATION = 0.6        -- Max length of the handoff window (seconds)
local HANDOFF_ARRIVAL = 24          -- Horizontal distance to target that ends the window early
local HANDOFF_GROUND_PROBE = 24     -- Downward probe length used to decide whether a jump would take

-- Rappel: how far below the anchor the player's HEAD is allowed to climb.
-- This is measured against the head (position.z + PLAYER_HEIGHT), not the
-- feet - clamping the feet is what let the upper body punch through the
-- surface the hook is embedded in at the top of a climb.
local RAPPEL_HEAD_CLEARANCE = 24
local PLAYER_HEIGHT = U.PLAYER_HEIGHT

-- The hook's outbound flight is visual/gameplay state owned by Hookshot.
-- BeamFX only receives the two endpoints that result from this state.
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
    
    -- Targeting data
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
    
    -- Landing state data
    landing = {
        timeRemaining = 0,
        targetYaw = nil,
    },

    -- Handoff state data (the last 50-60 units of a non-rappel grapple)
    handoff = {
        timeRemaining = 0,
        direction = nil,      -- Unit vector, horizontal, toward the aim point
        targetPos = nil,      -- Where we were headed, for the early-arrival test
        jumpPending = false,  -- One-shot: issue a jump on the first handoff frame
    },

    -- Equipment gates, resolved once per draw/fire rather than per frame.
    -- See settings.capabilities() for why this isn't polled continuously.
    caps = {
        glove = false,
        itemTargeting = false,
    },
    
    -- Hanging state data
    hanging = {
        position = nil,
        yaw = nil,
        anchorPosition = nil,
        currentRopeLength = 0,
        levitationApplied = false,
        pitchOverride = 0,
        isMoving = false,
    },
    
    -- Item menu state data
    itemMenu = {
        item = nil,           -- The item being interacted with
        ragdoll = nil,        -- Reference to the ragdoll data for this item
    },

    -- Runtime-only hook/rope state. Nothing here is authoritative gameplay
    -- persistence: an in-flight hook is deliberately cancelled by save/load
    -- or reloadlua, while the BeamFX side self-expires if updates stop.
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

    -- These flags record only engine-side overrides that this script
    -- currently owns. They are serialized solely so onLoad/reloadlua can
    -- safely undo an interrupted hookshot without trampling another mod's
    -- controls.
    ownedOverrides = {
        combatControlsSuppressed = false,
        movementControlsOverridden = false,
    },
}

local frameCounter = 0

-- Forward declarations. Both are assigned after setMode()/the hook action
-- helpers, but updateActiveRope() can safely call them once module loading has
-- completed and engine updates begin.
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

-- Convert an arbitrary x/y/z value into a real util.vector3 before using it
-- in gameplay math. This also keeps a malformed optional visual interface
-- from ever breaking the hookshot.
local function copyVector3(value)
    if value == nil then return nil end

    local x, y, z = value.x, value.y, value.z
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then
        return nil
    end
    return util.vector3(x, y, z)
end

-- The rope interface is registered by a later PLAYER entry in the manifest,
-- so it must be acquired lazily rather than cached at module load time.
local function ropeInterfaceMethod(name)
    local visuals = I.DubiousHookshotVisuals
    if visuals == nil then return nil end

    local method = visuals[name]
    if type(method) ~= "function" then return nil end
    return method
end

-- Right-shoulder launch point for the rope.
--
-- This deliberately does NOT ask the beam interface for its handOrigin()
-- first. The launch point isn't only cosmetic: beginHookTravel() measures
-- the outbound distance from it and divides by hookTravelSpeed to get the
-- flight duration, so sourcing it from an optional visual mod meant hook
-- timing quietly changed depending on whether BeamFX was installed, and
-- changed again if that mod retuned its offset. U.actorShoulderOrigin is
-- the single source of truth; the consumer resolves to the same helper, so
-- the rendered beam still starts exactly where the gameplay says it does.
local function ropeShoulderOrigin()
    return copyVector3(U.actorShoulderOrigin(self))
        -- Fallback only for a malformed vector, not for a raise. The helper
        -- reads self's own agent bounds and rotation; if that can fail, the
        -- hookshot has bigger problems than a rope anchor and the error
        -- should surface rather than be papered over with a guessed offset.
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
            -- Called directly. This resolves to THIS MOD's own consumer
            -- script, not to BeamFX: the cross-mod boundary is downstream in
            -- beamfx_adapter.lua, which already guards the provider call.
            -- Wrapping here only hid our own faults a second time.
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

    -- isValid() is the API that exists precisely to answer "can I still
    -- read this object", and it does not raise. Once it passes, reading
    -- .position is safe, so neither call needs a guard - the grappled
    -- target being deleted mid-pull is already handled by the check.
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

    -- A new shot owns the single rope slot. This is idempotent and also
    -- removes any stale visual left by an interrupted previous shot.
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

    -- FIRING owns outbound/attached pulls; HANGING deliberately retains the
    -- fixed anchor. Every other state should already have retracted via
    -- setMode(), but this guard keeps the visual fail-safe if a future path
    -- bypasses that choke point.
    if state.mode ~= HookshotState.FIRING
        and state.mode ~= HookshotState.HANGING
    then
        endActiveRope()
        return
    end

    local anchor = currentRopeAnchor()
    if not anchor then
        if state.mode == HookshotState.HANGING then
            -- Do not alter hanging gameplay merely because its optional
            -- visual data became unusable.
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

        -- For item/actor targets, anchor may move during flight. Interpolating
        -- against its live position preserves a bounded arrival time while
        -- making the hook visually follow the target rather than miss and snap.
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

    -- Once attached, shrinking is automatic: the near endpoint follows the
    -- player's hand while this far endpoint stays on the world anchor or live
    -- pulled object.
    rope.anchorPosition = anchor
    publishRope(anchor)
end

-- ==============================================
-- EQUIPMENT GATES
-- ==============================================
-- One equipment scan, cached into state.caps and pushed down into the
-- targeting module so the reticle and the fire path agree about what's
-- unlocked. Called on draw and again on fire (the inventory can be opened
-- while drawn, so a stale cache would otherwise last the whole aim).
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

-- Single choke point for changing state.mode. Every place in this file that
-- used to write state.mode directly now calls setMode() instead, so
-- playerAnim.lua always finds out about a transition (old -> new) and can
-- pick the right full-body animation without this file needing to know
-- anything about animation groups, priorities, or blend masks.
local function setMode(newMode)
    if state.mode == newMode then return end

    -- The rope survives only while actively firing/pulling or while hanging.
    -- Keeping this policy at the state-transition choke point makes every
    -- current and future cancellation/landing/menu/handoff path retract it.
    if state.rope.active
        and newMode ~= HookshotState.FIRING
        and newMode ~= HookshotState.HANGING
    then
        endActiveRope()
    end

    local oldMode = state.mode
    state.mode = newMode
    Anim.onStateChange(newMode, oldMode, state)

    -- Fire now shares the base game's Attack/Use key (see the 'Use'
    -- action handler below) rather than having its own dedicated key, so
    -- normal weapon swings/spellcasting need to be suppressed for the
    -- whole time the hookshot is drawn/active - otherwise an attack press
    -- would both fire the hookshot AND trigger whatever's readied.
    -- HANGING already disables both explicitly on its own (kept as-is,
    -- since releaseFromHang() re-enables them immediately on release
    -- rather than waiting for IDLE) - this just extends the same
    -- suppression to cover DRAWN/FIRING/LANDING too, and guarantees
    -- restoration at IDLE regardless of which path got there.
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
-- Cosmetic-only, runs every frame regardless of raycast timing: shows/hides
-- the reticle and advances its lock-on animation. No raycasting happens
-- here - that's driven by the shared ray delivery below.
local function updateReticleVisibility(deltaSeconds)
    if state.mode ~= HookshotState.DRAWN then
        Reticle:hide()
        return
    end

    Reticle:show()
    Reticle:updateAnimation(deltaSeconds)
end

-- Applies a fresh hit (from the shared ray or the grabbable-fallback cone
-- search) to state.targeting and updates the reticle. Runs at most once
-- every RAYCAST_THROTTLE shared-ray deliveries.
local function applyFreshHit(hitObject, hitPos, range)
    state.targeting.impact = {
        hit = true,
        hitPos = hitPos,
        hitObject = hitObject,
    }
    state.targeting.range = range

    -- Probe surface type for world geometry. This stays a dedicated short
    -- physics ray (nearby.castRay, ~200 units) rather than trusting the
    -- shared ray's hitNormal, which SharedRay's own docs call unreliable -
    -- accurate normals matter here for floor/wall/ceiling classification.
    local hitNormal = nil
    if not hitObject or not isGrabbable(hitObject) then
        hitNormal = Targeting.probeSurfaceNormal(hitPos, state.targeting.cameraV)
        state.targeting.surfaceType = orient.classifySurface(hitNormal)
        state.targeting.hitNormal = hitNormal
    else
        state.targeting.surfaceType = nil
        state.targeting.hitNormal = nil
    end

    -- getTargetType() runs the rappel-clearance/ledge-edge checks (their own
    -- short physics rays), so this only happens on a throttled tick now,
    -- not on every single cached-reuse frame in between.
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

-- Delivered by I.SharedRay every frame (async, ~1 frame of camera lag) once
-- subscribed in onActive(). `result` is a live view owned by SharedRay and
-- gets mutated again next frame, so any field we want to keep has to be
-- copied out before this function returns - never stash `result` itself.
local function onSharedRayResult(result)
    if state.mode ~= HookshotState.DRAWN then return end

    frameCounter = frameCounter + 1

    -- Throttle full reclassification (surface probe + rappel/ledge checks).
    -- Between throttled ticks, just redraw the reticle with the last
    -- classification instead of recomputing it every frame.
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

    -- Copy what we need from the live result right away.
    local hit = result.hit
    local hitPos = result.hitPos
    local hitObject = result.hitObject
    local distance = result.distance

    if hit and hitPos and distance and distance <= settings.maxRange() then
        local range = distance

        -- FALLBACK: If the ray hit world geometry (not a grabbable), check if
        -- there's actually an item/actor near where we're aiming that a
        -- rendering ray can miss (e.g. very thin collision meshes).
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
-- Subscribing/parameterizing here (rather than at file scope) matters:
-- multiple mods can bundle their own copy of SharedRay_v2.lua, and only
-- the highest version actually registers itself under I.SharedRay (see
-- that file's own version guard). onActive() runs after that has settled,
-- so I.SharedRay is guaranteed to be the winning copy by the time we touch it.
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
local function dropObject(ragdoll)
    if not ragdoll or not ragdoll.target then return end

    -- Clear old sequences to prevent conflicts
    ragdoll.seqs = {}

    -- Use physics drop for everything (items and actors)
    Physics.addRagdoll(Physics.createRagdollData(
        ragdoll.target,
        ragdoll.boundingData,
        { Physics.createDropSequence() },
        { isFalling = true }
    ))
end

local function terminateHook(ragdoll)
    if not ragdoll then return end

    if not ragdoll.isFalling then
        ambient.stopSoundFile(settings.sounds.fire)
    end
end

-- Forward declaration for menu callback handler
local handleItemMenuAction

-- Forward declaration: defined with the other state updates below, but
-- called from handleSequenceCompletion above it.
local beginHandoff

-- ==============================================
-- SEQUENCE COMPLETION HANDLER
-- ==============================================
-- Processes completion events returned by Physics.update().
-- Handles state transitions; physics bookkeeping is done by the physics module.
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
                -- Fields above are set before setMode() so playerAnim.lua sees
                -- a clean isMoving=false hang pose the instant HANGING starts.
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
            -- Clean release short of the aim point: cover the rest with a
            -- jump plus normal air movement instead of more teleporting.
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
        -- Actor pulls use the generic completion event. Do not leave their
        -- rope visible for the bookkeeping frame before ALL_COMPLETE arrives.
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
        -- Just take the item into inventory
        if item and item:isValid() then
            core.sendGlobalEvent('HookshotInventoryAction', {
                action = 'take',
                object = item,
                actor = self
            })
        end
        -- Remove from ragdoll system
        Physics.removeByTarget(item)
        setMode(HookshotState.IDLE)

    elseif action == 'drop' then
        -- Drop the item with gravity
        if ragdoll then
            Physics.addSequence(ragdoll, Physics.createDropSequence())
        end
        setMode(HookshotState.FIRING)  -- Back to firing to monitor the drop

    else
        -- 'cancel' or unknown - just drop the item
        if ragdoll then
            Physics.addSequence(ragdoll, Physics.createDropSequence())
        end
        setMode(HookshotState.FIRING)
    end
    
    -- Clear menu state
    state.itemMenu.item = nil
    state.itemMenu.ragdoll = nil
end

-- ==============================================
-- LANDING AND HANGING STATE UPDATES
-- ==============================================
-- Forward declaration (releaseFromHang is defined later but called from updateHangingState)
local releaseFromHang

local function updateLandingState(deltaSeconds)
    if state.mode ~= HookshotState.LANDING then return end
    
    -- During landing, suppress player movement to let physics settle
    -- This prevents fighting between player input and physics engine
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
-- The drag stops 50-60 units short of the aim point (which itself sits
-- 50-60 units above the surface). The remainder is covered by the engine:
-- a jump if the player is standing on something, gravity plus air steering
-- if they're already airborne.
--
-- WHY NOT JUST TELEPORT THE LAST BIT: there is no Lua call to set an
-- actor's velocity in OpenMW, so a teleported approach arrives with zero
-- engine momentum and has to be stopped by the collision cage right at
-- the destination - which is exactly where the cage is most likely to
-- shove the player into or through the surface. Releasing early means the
-- final approach is ordinary engine movement that other movement mods can
-- see and react to.
--
-- handoffVector is world-space target-minus-position at release time.
beginHandoff = function(handoffVector, landingData)
    local aimPos = (landingData and landingData.groundPosition) or (self.position + handoffVector)

    -- Steer horizontally only. The vertical component is gravity's job -
    -- feeding it into controls.movement would just fight the engine.
    local flat = util.vector3(handoffVector.x, handoffVector.y, 0)
    local flatLen = flat:length()
    if flatLen > 0.01 then
        state.handoff.direction = flat:normalize()
    else
        -- Straight up or straight down: nothing to steer toward, so just
        -- hold still and let gravity resolve it.
        state.handoff.direction = nil
    end

    state.handoff.targetPos = aimPos
    state.handoff.timeRemaining = HANDOFF_DURATION

    -- A jump only takes if the engine thinks we're grounded. Probe once
    -- rather than writing controls.jump blindly every frame.
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
    -- Straight to IDLE, NOT through LANDING: LANDING exists to zero out
    -- movement so teleport-driven physics can settle, which is the exact
    -- opposite of what a handoff wants. Suppressing input here would kill
    -- the momentum we just spent the handoff building.
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
        -- controls.movement/sideMovement are in the ACTOR's frame, but the
        -- direction we want is in world space, so rotate it by the actor's
        -- yaw. Doing this instead of forcing the player to face the target
        -- keeps the camera completely free during the approach.
        local yaw = self.rotation:getYaw()
        local sinYaw, cosYaw = math.sin(yaw), math.cos(yaw)
        self.controls.movement = dir.x * sinYaw + dir.y * cosYaw
        self.controls.sideMovement = dir.x * cosYaw - dir.y * sinYaw
        self.controls.run = true
    end

    -- End early once we're over the target horizontally, so the player
    -- gets their controls back the moment the grapple has done its job
    -- rather than at a fixed timer.
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
    
    -- Rappel controls: Check both built-in actions AND custom actions
    -- Built-in: MoveForward/MoveBackward are Range actions (W/S keys)
    -- Custom: HookshotRappelUp/Down/Release are Boolean actions
    local moveUpBuiltin = input.getRangeActionValue('MoveForward') > 0
    local moveDownBuiltin = input.getRangeActionValue('MoveBackward') > 0
    local moveUpCustom = input.getBooleanActionValue('HookshotRappelUp')
    local moveDownCustom = input.getBooleanActionValue('HookshotRappelDown')
    local releaseCustom = input.getBooleanActionValue('HookshotRappelRelease')
    
    local moveUp = moveUpBuiltin or moveUpCustom
    local moveDown = moveDownBuiltin or moveDownCustom
    
    -- Release: Jump trigger OR custom rappel release action
    local releasePressed = jumpPressedForRappel or releaseCustom
    
    -- Explicit debugMode() guard, not just debugPrint(...) - string.format
    -- plus these two extra getRangeActionValue() calls would otherwise run
    -- every single frame while hanging even with debug mode off, since Lua
    -- evaluates a function's arguments before the function (debugPrint)
    -- gets a chance to discard them.
    if settings.debugMode() then
        debugPrint(string.format("RAPPEL Up=%s Down=%s Release=%s (builtinUp=%.1f builtinDown=%.1f customUp=%s customDown=%s)",
            tostring(moveUp), tostring(moveDown), tostring(releasePressed),
            input.getRangeActionValue('MoveForward'), input.getRangeActionValue('MoveBackward'),
            tostring(moveUpCustom), tostring(moveDownCustom)))
    end
    
    -- Check for release action
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
        -- Animation follows the key being held, independent of whether the
        -- climb is actually blocked below.
        state.hanging.pitchOverride = -1.0
        state.hanging.isMoving = true

        -- APEX CLIPPING FIX. The old limit was on the player's FEET
        -- (playerZ >= anchorZ - 64), which let the head - 128 units above
        -- the feet - climb 64 units PAST the anchor and into the surface
        -- the hook is embedded in. Clamping the head instead costs nothing
        -- and removes the penetration entirely.
        local playerZ = currentPos.z
        local anchorZ = anchorPos.z
        local headZ = playerZ + PLAYER_HEIGHT
        local maxStep = (anchorZ - RAPPEL_HEAD_CLEARANCE) - headZ

        if maxStep <= 0 then
            debugPrint("At anchor height, cannot ascend further (headZ =", headZ, "anchorZ =", anchorZ, ")")
        else
            local step = math.min(settings.rappelClimbSpeed() * deltaSeconds, maxStep)

            -- Second guard, for geometry that ISN'T the anchor: an overhang,
            -- a beam, the lip of the ledge you're climbing past. One ray per
            -- ascending frame, mirroring the groundCheck the descend branch
            -- already does.
            local headroom = nearby.castRay(
                currentPos + util.vector3(0, 0, PLAYER_HEIGHT * 0.5),
                currentPos + util.vector3(0, 0, PLAYER_HEIGHT + step + RAPPEL_HEAD_CLEARANCE),
                {
                    collisionType = HOOKSHOT_PHY,
                    ignore = self
                }
            )

            if headroom.hit then
                -- Stop with the head RAPPEL_HEAD_CLEARANCE below whatever
                -- we found, never past it.
                local allowed = (headroom.hitPos.z - RAPPEL_HEAD_CLEARANCE) - headZ
                step = math.min(step, math.max(allowed, 0))
                debugPrint("Headroom limited ascent, step =", step)
            end

            if step <= 0 then
                debugPrint("Blocked overhead, cannot ascend further")
            else
                -- Move straight up by position, not by faking a look-up-and-walk-
                -- forward direction - this keeps the camera 100% free while
                -- climbing, since self.controls.pitchChange/yawChange are never
                -- touched here.
                local newPos = currentPos + util.vector3(0, 0, step)
                -- self.object, not self: `self` is the SelfObject, a distinct
                -- type from the GObject an event payload should carry. The
                -- global handler calls :isValid() and :teleport() on it.
                core.sendGlobalEvent('ragdollTeleport', { object = self.object, newPos = newPos })
                debugPrint("Ascending, step =", step)
            end
        end
        
    elseif moveDown then
        debugPrint("moveDown detected, attempting to descend")
        -- Same idea: animation tracks the key, not whether descent is blocked.
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

    -- Refresh the hang pose (idle/up/down) every frame - it's driven by
    -- moveUp/moveDown (the raw key state) above, not by a HookshotState
    -- transition, so this can't live in setMode().
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

-- Assign to forward-declared variable
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
    -- Run physics and process completion events
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
    -- The hook itself is deliberately not persisted. Save only enough
    -- ownership data to undo engine-side changes if the save/reload happened
    -- in the middle of a draw, pull, or hang.
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

    -- Include the live flags as well as the serialized flags. That keeps this
    -- cleanup correct whether OpenMW recreated the Lua module or invoked
    -- onLoad on an existing instance (for example during development reloads).
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

    -- Cancel held poses and all local transient state without emitting an end
    -- event during load. The global BeamFX adapter resets independently.
    if resetAnimation then
        Anim.forceReset()
    end
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
        -- A recreated Reticle module has no UI element for hide() to update,
        -- but the engine-side crosshair can still be hidden by the old one.
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

    -- Check if this is an item that will need the menu after pull
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
    
    -- Classify the surface type for ledge edge check
    local surfaceType = orient.classifySurface(hitNormal)
    
    -- Check if this is a rappel-eligible surface (for fun mode)
    -- Must pass BOTH checks: clearance AND ledge edge detection
    local rappelEligible = Targeting.checkRappelClearance(hitPos, hitNormal)
                           and Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType)
    
    local landingData = orient.calculateLanding(hitPos, hitNormal, approachDir, playerYaw, rappelEligible)
    landingData.anchorPosition = hitPos

    -- Non-rappel grapples arc in ABOVE the landing point and release short
    -- of it. A hang has to actually arrive at its hang position (the whole
    -- state depends on being within arrivalThreshold of it), so rappel
    -- targets keep the old drag-all-the-way behaviour.
    local handoffDistance = 0
    if not landingData.isHang then
        local rise = settings.handoffRise()
        if rise > 0 then
            landingData.position = landingData.position + util.vector3(0, 0, rise)
        end
        handoffDistance = settings.handoffDistance()
        -- Remember the un-raised point so the handoff can steer at the
        -- surface rather than at the empty air above it.
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

-- The outbound phase calls this exactly once when its virtual tip reaches the
-- target. Only now do we start the pre-existing pull physics, making the
-- visible extension and reel-in two distinct phases.
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

    -- EVERY denial path returns before the first playSoundFile() below.
    -- Sound is feedback for something HAPPENING; a refused fire should be
    -- silent (or get its own distinct cue), not borrow the arm/aim sound.
    if not state.targeting.impact then
        ui.showMessage("No target in hookshot range")
        debugPrint("No target - aborting fire")
        return
    end
    
    local target = state.targeting.impact.hitObject
    local hitPos = state.targeting.impact.hitPos
    local approachDir = state.targeting.cameraV
    local playerYaw = state.targeting.cameraYaw or camera.getYaw()

    -- Re-resolve the gates here rather than trusting the value cached at
    -- draw time: the inventory can be opened and an item unequipped while
    -- the hookshot is still drawn.
    local caps = refreshCapabilities()

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

    -- Direct DRAWN -> FIRING transition: the old helper passed through IDLE,
    -- briefly stopping the pose and re-enabling combat controls for the pull.
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
        -- Gate check BEFORE any audio. drawHookshot() owns the arm/aim
        -- sounds, so returning here leaves the denial silent apart from the
        -- on-screen message - the sound now only ever means "the hookshot
        -- actually came up".
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
-- All keybindings are handled via triggers registered with inputBinding settings
-- This allows users to rebind keys through OpenMW's Lua Scripts menu

print("[HOOKSHOT] Registering trigger handlers...")

-- Hookshot activate trigger handler
input.registerTriggerHandler('HookshotActivate', async:callback(function()
    debugPrint("HookshotActivate trigger FIRED!")
    tryActivateHookshot()
end))
print("[HOOKSHOT] Registered handler for HookshotActivate")

-- Hookshot sheath trigger handler
input.registerTriggerHandler('HookshotSheath', async:callback(function()
    debugPrint("HookshotSheath trigger FIRED!")
    trySheathHookshot()
end))
print("[HOOKSHOT] Registered handler for HookshotSheath")

-- Fire: shares the base game's Attack/Use key instead of a dedicated
-- binding. registerActionHandler calls back only when the value CHANGES,
-- so this fires once per press (not continuously while the button is
-- held) - same feel as the old single-key draw-then-fire toggle, just on
-- a different key. Only acts while DRAWN; setMode() disables the
-- Fighting/Magic control switches for that whole window so this can't
-- also trigger a normal weapon swing or spell.
input.registerActionHandler('Use', async:callback(function(value)
    if value and state.mode == HookshotState.DRAWN then
        debugPrint("Use (Attack) pressed while DRAWN - firing hookshot")
        fireHookshot()
    end
end))
print("[HOOKSHOT] Registered handler for Use (Fire)")

-- Note: Rappel Up/Down/Release are now Boolean Actions, not Triggers
-- They are read directly via getBooleanActionValue in updateHangingState

-- Jump trigger handler for hang release (Space to drop - built-in fallback)
input.registerTriggerHandler('Jump', async:callback(function()
    if state.mode == HookshotState.HANGING then
        debugPrint("Jump trigger detected while hanging - setting release flag")
        jumpPressedForRappel = true
    end
end))

print("[HOOKSHOT] All trigger handlers registered")

-- ==============================================
-- MODULE EXPORTS
-- ==============================================
return {
    engineHandlers = {
        onActive = onActive,
        onUpdate = onUpdate,
        onLoad = onLoad,
        onSave = onSave,
        -- No longer need onKeyPress/onKeyRelease - all handled via triggers
    }
}

---@omw-context player

--[[
    playerAnim.lua
    Full-body animation controller for the hookshot mod.

    This module owns ALL animation calls for the mod. player.lua knows
    nothing about animation groups, priorities, or blend masks - it just
    tells this module when HookshotState changes (via Anim.onStateChange)
    and, once per frame while hanging, what the hang movement looks like
    (via Anim.updateHanging). Everything else lives here.

    HOOKUP (already done in player.lua, described here for reference):
      1. `local Anim = require('scripts.OpenMWHookshot.playerAnim')`
      2. A single setMode(newMode) helper wraps every state.mode write and
         calls Anim.onStateChange(newMode, oldMode, state).
      3. updateHangingState() calls Anim.updateHanging(state.hanging) once
         per frame, since the up/down/idle hang pose changes with movement
         input without a HookshotState transition happening.
]]--

local I = require('openmw.interfaces')
local anim = require('openmw.animation')
local self = require('openmw.self')

local Anim = {}

-- ==============================================
-- CONFIGURATION
-- ==============================================
local GROUPS = {
    DRAWN     = "hookaim",     -- held while aiming (HookshotState.DRAWN)
    HANDOFF   = "hookoff",
    HANG_IDLE = "hookhang",    -- hanging still
    HANG_UP   = "hookhangup",  -- ascending the rope
    HANG_DOWN = "hookhangdwn", -- descending the rope
}

local FIRING_GROUPS = {
    enemy   = "hookshoot",
    item    = "hookitem",
    default = "hookgo", -- wall, floor, ceiling, rappel, none
}

-- Full body: every hookshot pose overrides the whole skeleton so it reads
-- clearly instead of blending oddly with locomotion/idle.
local FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Weapon,
}
local FULLBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.LowerBody

-- Upper body: legs stay under normal control (LowerBody deliberately
-- omitted from both tables below) so aiming doesn't stomp locomotion.
-- FIX: RightArm was PRIORITY.Scripted while LeftArm/Torso were
-- PRIORITY.Weapon in the same playBlendedAnimation call. INTENTIONAL
local UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
}
local UPPERBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm

-- Which blend mask each group is actually played with.
--
-- releaseGroup() needs this: the release reissues the SAME group, so it has
-- to reissue on exactly the bones that pose owned. Reissuing an upper-body
-- pose (DRAWN, HANDOFF) at FULLBODY_BLEND_MASK would grab LowerBody for a
-- pose that never held it. That mask mismatch is the real defect the
-- anim.cancel() rewrite was reaching for - this table fixes it directly,
-- without needing cancel() at all.
local GROUP_BLEND_MASK = {
    [GROUPS.DRAWN]     = UPPERBODY_BLEND_MASK,
    [GROUPS.HANDOFF]   = UPPERBODY_BLEND_MASK,
    [GROUPS.HANG_IDLE] = FULLBODY_BLEND_MASK,
    [GROUPS.HANG_UP]   = FULLBODY_BLEND_MASK,
    [GROUPS.HANG_DOWN] = FULLBODY_BLEND_MASK,
}
for _, group in pairs(FIRING_GROUPS) do
    GROUP_BLEND_MASK[group] = FULLBODY_BLEND_MASK
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
-- Tracks whatever group we last told the engine to play, so redundant
-- calls (e.g. two HANGING frames in a row with the same pose) don't
-- restart/stutter the animation.
local currentGroup = nil

-- ==============================================
-- LOW-LEVEL HELPERS
-- ==============================================
-- Set true to release poses with animation.cancel() instead of the
-- Default-priority reissue below.
--
-- OFF BY DEFAULT because cancel() is the prime suspect for the animation
-- blackout: it is the only call in this file that can raise, and the
-- symptoms on both sides of the fix line up exactly with it raising. When
-- releaseGroup() threw from stopAnim() the pose simply never stopped and
-- looped forever; once the release moved into playPose() (ahead of the
-- play, to close the pose leak) the throw also skipped the new pose and
-- left currentGroup pointing at a pose that was no longer really playing,
-- so the next transition early-returned on `currentGroup == group` and
-- nothing played again at all.
--
-- Flip this back to true only after confirming animation.cancel's presence
-- and exact signature for this OpenMW build in Cod3x. The reissue path
-- below needs no such confirmation - it uses the same
-- I.AnimationController.playBlendedAnimation call the poses already use.
local USE_ANIMATION_CANCEL = false

local function releaseGroup(group)
    if not group then return end

    if USE_ANIMATION_CANCEL then
        -- animation.cancel() removes the group from the active animation
        -- list outright, regardless of the blend mask it was played with.
        -- Plain openmw.animation module call (not on I.AnimationController),
        -- only works on self, hence the require above.
        anim.cancel(self, group)
        return
    end

    -- Reissue the SAME group at Default priority with loops = 0 and
    -- autoDisable = true, and let it end on its own. This is what the
    -- pre-merge version did, and it's the documented way to end a held
    -- blended pose: animation.clearAnimationQueue() does NOT affect
    -- playBlended animations, so there's nothing to clear.
    --
    -- Mask comes from GROUP_BLEND_MASK so the release only ever touches the
    -- bones the pose actually owned.
    I.AnimationController.playBlendedAnimation(group, {
        priority = anim.PRIORITY.Default,
        blendMask = GROUP_BLEND_MASK[group] or FULLBODY_BLEND_MASK,
        loops = 0,
        autoDisable = true,
    })
end

-- Starts `group` as the single pose this module owns, releasing whatever
-- pose it was previously holding.
--
-- THE RELEASE IS THE WHOLE POINT OF THIS HELPER. Every pose here is played
-- with loops = -1, forceLoop = true, autoDisable = false, so it runs until
-- something explicitly cancels it. playLoop/playLoopAlt used to just
-- overwrite currentGroup and leave the outgoing group running - the engine
-- kept looping it forever, and stopAnim() could no longer name it to
-- cancel it because currentGroup had already moved on.
--
-- That leak was invisible while fireHookshot() routed DRAWN -> IDLE ->
-- FIRING, because IDLE hits stopAnim() in between. The rope rewrite made
-- that transition direct (DRAWN -> FIRING), which exposed it. The same
-- applies to FIRING -> HANDOFF, FIRING -> HANGING, and every hang sub-pose
-- swap in Anim.updateHanging, which have always switched pose-to-pose.
--
-- Both play paths go through here specifically so the release can never be
-- present in one and forgotten in the other.
local function playPose(group, priority, blendMask)
    if not group then return end
    if currentGroup == group then return end -- already playing this pose

    -- ORDER MATTERS: bookkeeping first, then start the new pose, then
    -- release the outgoing one. Nothing here is wrapped in pcall - if
    -- playBlendedAnimation can raise then the play below raises too, and
    -- guarding only the release would hide a real fault while leaving the
    -- pose system half-broken.
    --
    -- The ordering gives the same protection structurally: currentGroup is
    -- already correct and the new pose is already started before the
    -- release is attempted, so a raise there can neither block the incoming
    -- pose nor strand currentGroup on a pose that is no longer playing.
    local outgoing = currentGroup
    currentGroup = group

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start",
        stopKey = "stop",
        priority = priority,
        blendMask = blendMask,
        loops = -1,
        forceLoop = true,
        autoDisable = false,
    })

    -- Different group name, so this can never end the pose just started.
    -- The incoming pose holds Weapon priority on the shared bone groups, so
    -- the outgoing one losing to Default takes effect cleanly.
    if outgoing then
        releaseGroup(outgoing)
    end
end

-- Full-body pose: overrides locomotion too (includes LowerBody).
local function playLoop(group)
    playPose(group, FULLBODY_PRIORITY, FULLBODY_BLEND_MASK)
end

-- Upper-body pose: legs stay under normal locomotion control.
local function playLoopAlt(group)
    playPose(group, UPPERBODY_PRIORITY, UPPERBODY_BLEND_MASK)
end

-- Hands the bone groups this file owns back to normal animation.
local function stopAnim()
    if not currentGroup then return end

    -- Cleared BEFORE the release, not after, and deliberately not guarded.
    -- A stale name here is worse than a leaked pose: every later transition
    -- would early-return on `currentGroup == group` and no pose would ever
    -- start again. Clearing first removes that failure mode without hiding
    -- the error, which still propagates to openmw.log where it belongs.
    local group = currentGroup
    currentGroup = nil

    releaseGroup(group)
end

-- ==============================================
-- HANGING SUB-POSE SELECTION
-- ==============================================
-- Called once per frame while HANGING (from updateHangingState in
-- player.lua) so the pose tracks W/S (ascend/descend) in real time.
-- hangingData is player.lua's state.hanging table:
--   isMoving      - bool, true while ascending or descending
--   pitchOverride - the pitchChange value updateHangingState just set;
--                   negative while ascending, positive while descending
function Anim.updateHanging(hangingData)
    if not hangingData or not hangingData.isMoving then
        playLoop(GROUPS.HANG_IDLE)
        return
    end

    if (hangingData.pitchOverride or 0) < 0 then
        playLoop(GROUPS.HANG_UP)
    else
        playLoop(GROUPS.HANG_DOWN)
    end
end

-- ==============================================
-- PUBLIC API
-- ==============================================
-- Called from player.lua's setMode() on every HookshotState transition.
-- newState/oldState are the HookshotState.* strings; hookshotState is
-- player.lua's whole `state` table (only state.hanging is used here).
function Anim.onStateChange(newState, oldState, hookshotState)
    if newState == "DRAWN" then
        playLoopAlt(GROUPS.DRAWN)

    elseif newState == "FIRING" then
        local targeting = hookshotState and hookshotState.targeting
        local targetType = targeting and targeting.lastTargetType
        playLoop(FIRING_GROUPS[targetType] or FIRING_GROUPS.default)

    elseif newState == "HANDOFF" then
        -- Upper-body only, and the dedicated hookoff clip - not full-body
        -- DRAWN. updateHandoffState() in player.lua actively drives
        -- self.controls.movement/sideMovement/jump during this state (the
        -- player is really running/jumping the last stretch under normal
        -- engine movement); a full-body pose would fight that every frame.
        -- GROUPS.HANDOFF ("hookoff") was already defined but never actually
        -- used - this was calling playLoop(GROUPS.DRAWN) instead.
        playLoopAlt(GROUPS.HANDOFF)

    elseif newState == "HANGING" then
        local hangingData = hookshotState and hookshotState.hanging
        Anim.updateHanging(hangingData)

    else
        -- IDLE, LANDING, ITEM_MENU: no hookshot pose active.
        stopAnim()
    end
end

function Anim.isActive()
    return currentGroup ~= nil
end

-- reloadlua recreates this module and loses currentGroup, while the engine can
-- still be holding the blended loop. Explicitly release every Hookshot-owned
-- group so load cleanup does not depend on that Lua bookkeeping surviving.
-- Was missing HANDOFF and the FIRING_GROUPS variants entirely - only the
-- single group actually recorded in currentGroup matters for correctness
-- (releaseGroup on a group that isn't active is a harmless no-op), but
-- listing every group this file can ever play keeps this future-proof
-- against exactly the kind of gap that left HANDOFF/FIRING variants out
-- the first time.
function Anim.forceReset()
    -- Cleared first so the reset is complete even if a release raises.
    currentGroup = nil

    releaseGroup(GROUPS.DRAWN)
    releaseGroup(GROUPS.HANDOFF)
    releaseGroup(GROUPS.HANG_IDLE)
    releaseGroup(GROUPS.HANG_UP)
    releaseGroup(GROUPS.HANG_DOWN)
    for _, group in pairs(FIRING_GROUPS) do
        releaseGroup(group)
    end
end

return Anim

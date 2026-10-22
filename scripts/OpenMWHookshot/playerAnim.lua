---@omw-context player
-- Full-body animation controller. The only file that names animation groups.
-- player.lua calls Anim.onStateChange on every mode change and
-- Anim.updateHanging once per frame while hanging.

local I = require('openmw.interfaces')
local anim = require('openmw.animation')
local self = require('openmw.self')

local Anim = {}

local GROUPS = {
    DRAWN     = "hookaim",
    HANDOFF   = "hookoff",
    HANG_IDLE = "hookhang",
    HANG_UP   = "hookhangup",
    HANG_DOWN = "hookhangdwn",
}

local FIRING_GROUPS = {
    enemy   = "hookshoot",
    item    = "hookitem",
    default = "hookgo", -- wall, floor, ceiling, rappel, none
}

-- Playback speed per group. Clip lengths are fixed in the .kf; these fit them
-- to how long each state actually lasts. Under 1 stretches, over 1 compresses.
local SPEED = {
    hookaim     = 0.8,  -- 0.833s held aim loop
    hookshoot   = 1.0,  -- 0.500s
    hookitem    = 1.0,  -- 0.667s
    hookgo      = 1.0,  -- 0.667s
    hookoff     = 1.5,  -- 1.000s clip over a ~0.32s handoff window
    hookhang    = 0.4,  -- 0.167s loop, 6Hz at speed 1
    hookhangup  = 0.5,  -- 0.333s loop
    hookhangdwn = 0.5,  -- 0.333s loop
}

-- PRIORITIES. The right arm is the firing arm, so it takes the highest value in
-- both tuples and wins its bone group outright.
--
-- Both tuples were uniform Weapon, which is the shape to avoid: Animation::play
-- erases every other state whose AnimPriority compares equal on all four bone
-- groups (mwrender/animation.cpp:905-911, operator== in animationpriority.hpp
-- :19-25), so a uniform tuple is DELETED by any animation sharing it rather than
-- merely outranked. Uniform Weapon was also FLOW's tuple until recently, so the
-- two mods deleted each other's poses when installed together.
--
-- Values are chosen from the per-group gaps the engine leaves. Only states whose
-- blend mask CONTAINS a group compete for it (animation.cpp:1138), and "shield"
-- and "torch" are LeftArm-masked, so the uncontested values are LowerBody 7/8/10,
-- Torso 8/10, RightArm 8/10 -- and nothing on LeftArm above Hit. See
-- RESEARCH.md 1.29.
local FULLBODY_PRIORITY = {
    -- Torch(10): the only free value above Knockdown(9), so the firing arm reads
    -- through anything. Nothing competes here -- torch itself is LeftArm-masked.
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Torch,
    -- Left stays at Weapon, below shield(8) and torch(10), so a torch or shield
    -- still wins the off hand.
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    -- Block(8) instead of Weapon(7): it was tying the drawn-weapon animation,
    -- which resetActiveGroups breaks with a strict <, i.e. by map order. Free.
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Block,
    -- Unchanged. Free, above Movement(5) and Hit(6), below Knockdown(9).
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Weapon,
}
local FULLBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.LowerBody

-- Upper body only: legs stay under locomotion.
local UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Torch,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Block,
    -- Named rather than left out. getPriorityArgument fills unnamed groups with
    -- Priority_Default (mwlua/animationbindings.cpp:60-71), so the tuple was
    -- already {Default, Weapon, Weapon, Weapon} -- one step from the engine's own
    -- drawn-weapon {WeaponLowerBody, Weapon, Weapon, Weapon}. The mask excludes
    -- LowerBody so this value is never read for arbitration, only for the
    -- equality test above; stating it keeps that visible.
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Default,
}
local UPPERBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm

local currentGroup = nil
-- Recorded alongside the name so the live pose can be replayed exactly as it was
-- issued, without this file needing to know which hookshot state produced it.
local currentPriority = nil
local currentBlendMask = nil

local function releaseGroup(group)
    if group then anim.cancel(self, group) end
end

-- Order: bookkeeping, play, then release the outgoing pose.
local function playPose(group, priority, blendMask)
    if not group then return end
    -- The cached name is not enough on its own. A model rebuild clears every
    -- animation state (Animation::clearAnimSources -> mStates.clear()) and tells
    -- Lua nothing, so currentGroup can name a pose that is no longer playing.
    -- animation.isPlaying reads mStates directly (animation.cpp:1209-1215), which
    -- is what makes a pose re-asserted per frame -- the hang pose -- self-healing.
    if currentGroup == group and anim.isPlaying(self, group) then return end

    local outgoing = currentGroup
    currentGroup = group
    currentPriority = priority
    currentBlendMask = blendMask

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start",
        stopKey = "stop",
        priority = priority,
        blendMask = blendMask,
        speed = SPEED[group] or 1,
        loops = 0,
        forceLoop = true,
        autoDisable = false,
    })

    -- Only when it is a DIFFERENT pose. Re-asserting the same group after a
    -- rebuild makes outgoing == group, and releasing it here would cancel the
    -- state that was just played. The old name-only guard hid this by making a
    -- same-group call impossible.
    if outgoing ~= group then releaseGroup(outgoing) end
end

-- ---------------------------------------------------------------------------
-- MODEL REBUILDS
-- ---------------------------------------------------------------------------
--
-- Two of the five states hold a pose for as long as the player likes: DRAWN while
-- aiming, and HANGING while suspended. A rebuild drops both, and the guard above
-- only heals the ones something re-asserts -- HANGING, via player.lua's per-frame
-- updateHanging. DRAWN is set once from setMode, so nothing comes back for it
-- unless it is told, which is what AnimRefresh is for.
--
-- Read at call time, never cached at load: interface publication is decided by
-- load order (scriptscontainer.cpp:283), so AnimRefresh may publish after this
-- file has run. Absent entirely, HANGING still heals itself and DRAWN behaves as
-- it did before -- so this is an enhancement, not a dependency.
local ANIMREFRESH_KEY = "OpenMWHookshot"
local subscribed = false

-- Returns false only when a pose was lost and could NOT be restored, which is
-- AnimRefresh's signal to deliver again on its retry schedule.
function Anim.reissue()
    local group = currentGroup
    if not group then return true end                     -- nothing to protect
    if anim.isPlaying(self, group) then return true end   -- nothing was lost
    playPose(group, currentPriority, currentBlendMask)
    return anim.isPlaying(self, group)
end

local function subscribeRefresh()
    if subscribed then return end
    local service = I.AnimRefresh
    if not service then return end
    subscribed = true
    -- verify asks for one follow-up check after each boundary. Measured: a second
    -- rebuild follows the first within 2s often enough to matter (p90 1.78s), and
    -- an indefinitely held pose is exactly what that window costs.
    service.subscribe(ANIMREFRESH_KEY, function()
        if not Anim.reissue() then return false end
    end, { verify = true })
end

local function unsubscribeRefresh()
    if not subscribed then return end
    subscribed = false
    local service = I.AnimRefresh
    if service then service.unsubscribe(ANIMREFRESH_KEY) end
end

-- ---------------------------------------------------------------------------

local function playLoop(group)
    playPose(group, FULLBODY_PRIORITY, FULLBODY_BLEND_MASK)
    subscribeRefresh()
end

local function playLoopAlt(group)
    playPose(group, UPPERBODY_PRIORITY, UPPERBODY_BLEND_MASK)
    subscribeRefresh()
end

-- Cleared before the release so a stale name can never block later poses.
local function stopAnim()
    unsubscribeRefresh()
    if not currentGroup then return end
    local group = currentGroup
    currentGroup = nil
    currentPriority = nil
    currentBlendMask = nil
    releaseGroup(group)
end

-- hangingData: player.lua's state.hanging. pitchOverride < 0 ascending, > 0 descending.
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

function Anim.onStateChange(newState, oldState, hookshotState)
    if newState == "DRAWN" then
        playLoopAlt(GROUPS.DRAWN)

    elseif newState == "FIRING" then
        local targeting = hookshotState and hookshotState.targeting
        local targetType = targeting and targeting.lastTargetType
        playLoop(FIRING_GROUPS[targetType] or FIRING_GROUPS.default)

    elseif newState == "HANDOFF" then
        -- Upper body: the player is really moving during the handoff.
        playLoopAlt(GROUPS.HANDOFF)

    elseif newState == "HANGING" then
        local hangingData = hookshotState and hookshotState.hanging
        Anim.updateHanging(hangingData)

    else
        stopAnim()
    end
end

function Anim.isActive()
    return currentGroup ~= nil
end

-- Releases every group this file can play; currentGroup does not survive reloadlua.
function Anim.forceReset()
    unsubscribeRefresh()
    currentGroup = nil
    currentPriority = nil
    currentBlendMask = nil
    for _, group in pairs(GROUPS) do
        releaseGroup(group)
    end
    for _, group in pairs(FIRING_GROUPS) do
        releaseGroup(group)
    end
end

-- Startup probe: a missing group or key is silent in the engine.
local verified = false

function Anim.verifyGroups()
    if verified then return end
    verified = true

    if not anim.hasGroup then
        print("[HOOKSHOT][anim] animation.hasGroup unavailable - skipping probe")
        return
    end

    local names = {}
    for _, group in pairs(GROUPS) do names[#names + 1] = group end
    for _, group in pairs(FIRING_GROUPS) do names[#names + 1] = group end
    table.sort(names)

    for i = 1, #names do
        local group = names[i]
        if not anim.hasGroup(self, group) then
            print(string.format("[HOOKSHOT][anim] %-12s MISSING GROUP (no pose)", group))
        elseif not anim.getTextKeyTime then
            print(string.format("[HOOKSHOT][anim] %-12s group OK (keys unchecked)", group))
        else
            local bad = {}
            for _, key in ipairs({ "start", "stop" }) do
                if not anim.getTextKeyTime(self, group .. ": " .. key) then
                    bad[#bad + 1] = key
                end
            end
            if #bad == 0 then
                print(string.format("[HOOKSHOT][anim] %-12s OK  speed=%.2f",
                    group, SPEED[group] or 1))
            else
                print(string.format("[HOOKSHOT][anim] %-12s MISSING KEY(S): %s",
                    group, table.concat(bad, ", ")))
            end
        end
    end
end

return Anim

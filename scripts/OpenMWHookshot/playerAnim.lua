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

local FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Weapon,
}
local FULLBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.LowerBody

-- Upper body only: legs stay under locomotion.
local UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
}
local UPPERBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm

local currentGroup = nil

local function releaseGroup(group)
    if group then anim.cancel(self, group) end
end

-- Order: bookkeeping, play, then release the outgoing pose.
local function playPose(group, priority, blendMask)
    if not group then return end
    if currentGroup == group then return end

    local outgoing = currentGroup
    currentGroup = group

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start",
        stopKey = "stop",
        priority = priority,
        blendMask = blendMask,
        loops = 0,
        forceLoop = true,
        autoDisable = false,
    })

    releaseGroup(outgoing)
end

local function playLoop(group)
    playPose(group, FULLBODY_PRIORITY, FULLBODY_BLEND_MASK)
end

local function playLoopAlt(group)
    playPose(group, UPPERBODY_PRIORITY, UPPERBODY_BLEND_MASK)
end

-- Cleared before the release so a stale name can never block later poses.
local function stopAnim()
    if not currentGroup then return end
    local group = currentGroup
    currentGroup = nil
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
    currentGroup = nil
    for _, group in pairs(GROUPS) do
        releaseGroup(group)
    end
    for _, group in pairs(FIRING_GROUPS) do
        releaseGroup(group)
    end
end

return Anim

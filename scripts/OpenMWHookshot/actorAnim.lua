---@omw-context local
-- Plays the dragged-in pose on an actor the player has hooked. Registered for
-- NPC and CREATURE; event handler only, no per-frame work.

local anim = require('openmw.animation')
local async = require('openmw.async')
local self = require('openmw.self')

local GROUP = "hsfalling"
local MAX_DURATION = 3.0

-- Non-uniform: a tuple equal on all four bone groups is deleted by any
-- animation sharing it rather than outranked.
local PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Block,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Torch,
}
local BLEND_MASK = anim.BLEND_MASK.LowerBody + anim.BLEND_MASK.Torso
                 + anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.RightArm

local playing = false
local generation = 0

local function stop()
    if not playing then return end
    playing = false
    anim.cancel(self, GROUP)
end

local function onActorHooked(data)
    -- Missing group is a silent no-pose, so skip rather than suppress the
    -- actor's own animation. Creatures and any skeleton without the .kf land here.
    if not anim.hasGroup or not anim.hasGroup(self, GROUP) then return end

    local duration = tonumber(data and data.duration) or MAX_DURATION
    if duration ~= duration or duration <= 0 then return end
    if duration > MAX_DURATION then duration = MAX_DURATION end

    generation = generation + 1
    local mine = generation

    if not playing then
        playing = true
        anim.playBlended(self, GROUP, {
            startKey = "loop start",
            stopKey = "loop stop",
            priority = PRIORITY,
            blendMask = BLEND_MASK,
            loops = 0,
            forceLoop = true,
            autoDisable = false,
        })
    end

    async:newUnsavableSimulationTimer(duration, function()
        if generation == mine then stop() end
    end)
end

return {
    eventHandlers = {
        Dubious_HookShot_ActorHooked = onActorHooked,
        Dubious_HookShot_ActorReleased = stop,
    },
    engineHandlers = {
        onSave = function() stop() end,
    },
}

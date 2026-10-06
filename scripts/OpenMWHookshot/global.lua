---@omw-context global

local types = require('openmw.types')
local I = require('openmw.interfaces')

local function teleportHandler(data)
    if not data.object or not data.newPos then
        print("[HOOKSHOT GLOBAL] ERROR: Missing object or newPos")
        return
    end

    if not data.object:isValid() then
        print("[HOOKSHOT GLOBAL] ERROR: Object is not valid")
        return
    end

    if not data.object.cell then
        print("[HOOKSHOT GLOBAL] ERROR: Object has no cell")
        return
    end

    data.object:teleport(data.object.cell, data.newPos,
        data.rotation and { rotation = data.rotation } or nil)
end

local function inventoryActionHandler(data)
    local item = data.object
    local actor = data.actor
    local action = data.action

    if not item or not item:isValid() then
        print("[HOOKSHOT GLOBAL] ERROR: Invalid item in inventoryActionHandler")
        return
    end

    if not actor or not actor:isValid() then
        print("[HOOKSHOT GLOBAL] ERROR: Invalid actor in inventoryActionHandler")
        return
    end

    if action == 'take' then
        local isStolen = false
        local factionId = nil

        if item.owner then
            if item.owner.recordId then
                isStolen = true
            end
            if item.owner.factionId then
                factionId = item.owner.factionId
                isStolen = true
            end
        end

        local itemValue = 0
        if item.type and item.type.record then
            local record = item.type.record(item)
            if record then
                itemValue = record.value or 0
            end
        end

        item:moveInto(types.Actor.inventory(actor))

        -- Owned items: report theft; I.Crimes checks witnesses.
        if isStolen and I.Crimes then
            -- No victim: world items have no NPC to pass.
            I.Crimes.commitCrime(actor, {
                type = types.Player.OFFENSE_TYPE.Theft,
                arg = itemValue,
                faction = factionId,
            })
        end
    end
end

return {
    eventHandlers = {
        ragdollTeleport = teleportHandler,
        HookshotInventoryAction = inventoryActionHandler
    }
}

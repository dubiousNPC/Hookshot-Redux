---@omw-context global

local core = require('openmw.core')
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
    
    -- Match Real Telekinesis pattern exactly
    if data.rotation then
        data.object:teleport(data.object.cell.name, data.newPos, data.rotation)
    else
        data.object:teleport(data.object.cell.name, data.newPos)
    end
end

-- Handler for item menu actions (take)
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

    print("[HOOKSHOT GLOBAL] Inventory action:", action, "for item:", item.recordId)

    if action == 'take' then
        -- Check if this is stealing (item has an owner)
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
        
        -- Get item value for crime calculation
        local itemValue = 0
        local itemName = "Item"
        if item.type and item.type.record then
            -- Guarded by the `item.type and item.type.record` check above,
            -- so this is a plain call on a type that advertises the method.
            local record = item.type.record(item)
            if record then
                itemValue = record.value or 0
                itemName = record.name or itemName
            end
        end
        
        -- Move item to player inventory
        item:moveInto(types.Actor.inventory(actor))
        print("[HOOKSHOT GLOBAL] Moved", itemName, "to inventory")
        
        -- If stolen, report the crime using I.Crimes interface
        -- This will check for witnesses and apply bounty if seen
        if isStolen and I.Crimes then
            print("[HOOKSHOT GLOBAL] Item is owned - reporting theft, value:", itemValue)
            
            -- I.Crimes.commitCrime(player, options)
            -- player: the player GameObject committing the crime
            -- options.type: from types.Player.OFFENSE_TYPE
            -- options.arg: bounty value for theft
            -- options.faction: faction ID string (optional)
            -- options.victim: victim GameObject (optional) - we don't have this for world items
            -- Called directly. I.Crimes is a core OpenMW interface, already
            -- nil-checked above, and a raise here would mean the call itself
            -- is wrong - which is exactly the kind of fault that needs to
            -- reach openmw.log rather than be reported as a print and
            -- swallowed. The item has already been moved at this point, so a
            -- raise costs the bounty, not the item.
            local result = I.Crimes.commitCrime(actor, {
                type = types.Player.OFFENSE_TYPE.Theft,
                arg = itemValue,
                faction = factionId,  -- Can be nil, faction ID as string
                -- victim is omitted - we don't have the actual NPC GameObject
            })

            if result and result.wasCrimeSeen then
                print("[HOOKSHOT GLOBAL] Theft was witnessed!")
            else
                print("[HOOKSHOT GLOBAL] Theft went unnoticed")
            end
        end
    end
end

return {
    eventHandlers = {
        ragdollTeleport = teleportHandler,
        HookshotInventoryAction = inventoryActionHandler
    }
}

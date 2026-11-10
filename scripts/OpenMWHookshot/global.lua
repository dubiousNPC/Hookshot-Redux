---@omw-context global

local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

-- ==============================================
-- HOOK DART
-- ==============================================
-- There is no Lua call to launch a projectile, so the dart is an ordinary
-- object this script moves. One per player, created on the first update and
-- removed on the last.
--
-- KEPT OUT OF SAVES BY HAND. This used to set `dart.saveState = false`, which
-- is not a property in OpenMW 0.52: the write raised "sol: cannot write to a
-- readonly property" on EVERY update (after the teleport, so the dart still
-- moved, with an error per frame in the log). Nothing in the Lua API stops an
-- object being saved, so a save taken while tethered stored the dart and the
-- load left it hanging in the world. Instead the live darts go into this
-- script's own save data and are removed on load.
--
-- KEYED BY THE OWNER'S id, NOT THE OBJECT. Each event hands this script its
-- own userdata for the player, so a table keyed by the object missed on the
-- end event: the dart was never removed (measured in OpenMW 0.52: found=false
-- with one dart tracked, after every hang). It stayed in the world as a
-- pickup, and the aim cone preferred it as an item target over the surface
-- being aimed at, so the next shot pulled the old dart instead of hooking.
local DART_RECORD = "dbs_hookshot_dart"
local darts = {}   -- owner.id -> dart

local function dartFor(owner, cell, pos, rotation)
    local key = owner.id
    local dart = darts[key]
    if dart and not dart:isValid() then
        darts[key] = nil
        dart = nil
    end

    if not dart then
        dart = world.createObject(DART_RECORD)
        if not dart then return nil end
        darts[key] = dart
    end

    if rotation then
        dart:teleport(cell, pos, rotation)
    else
        dart:teleport(cell, pos)
    end
    return dart
end

local function dartUpdateHandler(data)
    if not data or not data.owner or not data.pos then return end
    if not data.owner:isValid() then return end

    local cell = data.owner.cell
    if not cell then return end

    dartFor(data.owner, cell.name, data.pos, data.rotation)
end

local function dartEndHandler(data)
    if not data or not data.owner then return end
    local dart = darts[data.owner.id]
    darts[data.owner.id] = nil
    if dart and dart:isValid() then
        dart:remove()
    end
end

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

-- A dart in flight or planted at save time is stored with the save like any
-- object; remove it on load, since the tether that owned it is not restored.
local function onSave()
    local live = {}
    for _, dart in pairs(darts) do
        if dart:isValid() then live[#live + 1] = dart end
    end
    return { darts = live }
end

local function onLoad(data)
    for _, dart in ipairs(data and data.darts or {}) do
        if dart:isValid() then dart:remove() end
    end
end

return {
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        ragdollTeleport = teleportHandler,
        HookshotInventoryAction = inventoryActionHandler,
        HookshotDartUpdate = dartUpdateHandler,
        HookshotDartEnd = dartEndHandler,
    }
}

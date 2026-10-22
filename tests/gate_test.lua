-- Exercises settings.capabilities() across the whitelist matrix.
-- arg[1] = path to hookshot_settings.lua
local SETTINGS = arg[1]

local store = {}            -- section key -> { settingKey -> value }
local equipped = {}         -- recordId -> true

-- Models the engine: a set fires every subscriber, which is the only way a
-- settingsCache mirror stays current.
local sections = {}
local function section(name)
    if sections[name] then return sections[name] end
    store[name] = store[name] or {}
    local t = store[name]
    local subs = {}
    local sec
    sec = {
        get = function(_, k) return t[k] end,
        set = function(_, k, v)
            t[k] = v
            for _, fn in ipairs(subs) do fn(name, k) end
        end,
        asTable = function() local c = {} for k, v in pairs(t) do c[k] = v end return c end,
        subscribe = function(_, fn) subs[#subs + 1] = fn end,
    }
    sections[name] = sec
    return sec
end

package.loaded['openmw.interfaces'] = {
    Settings = {
        registerPage = function() end,
        registerGroup = function(g)
            local sec = section(g.key)
            for _, st in ipairs(g.settings or {}) do sec:set(st.key, st.default) end
        end,
        registerRenderer = function() end,
    },
}
package.loaded['openmw.storage'] = { playerSection = section, globalSection = section }
package.loaded['openmw.input'] = {
    registerTrigger = function() end,
    registerAction = function() end,
    ACTION_TYPE = { Boolean = 1 },
}
package.loaded['openmw.util'] = { color = { hex = function() return {} end } }
package.loaded['openmw.vfs'] = { pathsWithPrefix = function() return function() return nil end end }
package.loaded['openmw.types'] = {
    Actor = {
        getEquipment = function()
            local out = {}
            local i = 1
            for id in pairs(equipped) do out[i] = { recordId = id }; i = i + 1 end
            return out
        end,
    },
}
package.loaded['openmw.self'] = {}
package.loaded['openmw.async'] = { callback = function(_, f) return f end }

local settings = assert(loadfile(SETTINGS))()

local GATES = "Settings_OpenMW_Hookshot_Gates"
local function setGate(key, ids)
    local set = nil
    if ids then
        set = {}
        for _, id in ipairs(ids) do set[id] = true end
    end
    section(GATES):set(key, set)
end

local function equip(...)
    equipped = {}
    for _, id in ipairs({ ... }) do equipped[id:lower()] = true end
end

local pass, fail = 0, 0
local function check(label, caps, want)
    local bad = {}
    for k, v in pairs(want) do
        if caps[k] ~= v then
            bad[#bad + 1] = ("%s=%s want %s"):format(k, tostring(caps[k]), tostring(v))
        end
    end
    if #bad == 0 then
        pass = pass + 1
        print(("  PASS  %s"):format(label))
    else
        fail = fail + 1
        print(("  FAIL  %s  -> %s"):format(label, table.concat(bad, ", ")))
    end
end

print("defaults: every list empty, so any hookshot does everything")
setGate("GATE_GRAPPLE", nil); setGate("GATE_ITEM", nil)
setGate("GATE_NPC", nil); setGate("GATE_SPECIAL", nil)
equip("dbs_hookshot_ar")
check("basic glove", settings.capabilities(), {
    glove = true, grapple = true, item = true, npc = true, special = false })
equip()
check("nothing equipped", settings.capabilities(), {
    glove = false, grapple = false, item = false, npc = false })

print("\nper-function whitelists")
setGate("GATE_ITEM", { "dbs_hookshot_adv" })
equip("dbs_hookshot_ar")
check("basic glove, item locked to adv", settings.capabilities(), {
    glove = true, grapple = true, item = false, npc = true })
equip("dbs_hookshot_adv")
check("adv glove, item unlocked", settings.capabilities(), {
    glove = true, grapple = true, item = true, npc = true })

setGate("GATE_NPC", { "dbs_hs_mandalore" })
equip("dbs_hookshot_adv")
check("adv: npc locked to mandalore", settings.capabilities(), {
    grapple = true, item = true, npc = false })
equip("dbs_hs_mandalore")
check("mandalore: npc only", settings.capabilities(), {
    grapple = true, item = false, npc = true })

print("\nSpecial overrides every list")
setGate("GATE_SPECIAL", { "dbs_hookshot_adv" })
equip("dbs_hookshot_adv")
check("adv is Special", settings.capabilities(), {
    glove = true, grapple = true, item = true, npc = true, special = true })

print("\na whitelisted non-glove id is usable on its own")
setGate("GATE_GRAPPLE", nil); setGate("GATE_ITEM", nil)
setGate("GATE_NPC", nil); setGate("GATE_SPECIAL", nil)
setGate("GATE_GRAPPLE", { "some_other_mod_glove" })
equip("some_other_mod_glove")
check("custom id grants grapple and draw", settings.capabilities(), {
    glove = true, grapple = true })
check("custom id does not grant item/npc", settings.capabilities(), {
    item = false, npc = false })

print("\ncase insensitivity")
setGate("GATE_GRAPPLE", nil)
setGate("GATE_ITEM", { "DBS_Hookshot_Adv" })
equip("dbs_hookshot_adv")
check("mixed-case list entry matches", settings.capabilities(), { item = true })

print("\nempty-but-present table counts as empty")
section(GATES):set("GATE_ITEM", {})
equip("dbs_hookshot_ar")
check("{} inherits the glove gate", settings.capabilities(), { item = true })

section(GATES):set("GATE_ITEM", { ["dbs_hookshot_adv"] = false })
check("all-false entries count as empty", settings.capabilities(), { item = true })

print("\ncached accessors track a live set()")
local BASIC = "Settings_OpenMW_Hookshot_Basic"
check("seeded from defaults", { v = settings.maxRange() ~= nil }, { v = true })
section(BASIC):set("MAX_HOOKSHOT_RANGE", 3333)
check("maxRange after set", { v = settings.maxRange() }, { v = 3333 })
section(BASIC):set("DEBUG_MODE", true)
check("debugMode after set", { v = settings.debugMode() }, { v = true })
local HANDOFF = "Settings_OpenMW_Hookshot_Handoff"
section(HANDOFF):set("HANDOFF_DISTANCE", 120)
check("handoffDistance after set", { v = settings.handoffDistance() }, { v = 120 })

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

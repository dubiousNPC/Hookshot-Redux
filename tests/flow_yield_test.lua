-- Hookshot <-> Parkourwind FLOW: the hookshot stands FLOW down (I.Flow.yield)
-- for exactly as long as it carries, swings or hangs the player, and yields
-- BEFORE it writes the shared movement-override flag.
-- arg[1] = stub path, arg[2] = player.lua path
local S = assert(loadfile(arg[1]))()
local v3 = S.v3

local realPrint = print
print = function() end

local pass, fail = 0, 0
local function check(label, ok, got)
    if ok then pass = pass + 1 else fail = fail + 1 end
    realPrint(("  %s  %-60s %s"):format(ok and "PASS" or "FAIL", label, tostring(got)))
end

-- FLOW, as far as the hookshot can see it, plus the shared override flag:
-- one ordered log of both, so the order of a yield and a write is checkable.
local I = package.loaded['openmw.interfaces']
local log, owners = {}, {}
I.Flow = {
    yield = function(o) owners[o] = true; log[#log + 1] = "yield" end,
    resume = function(o) owners[o] = nil; log[#log + 1] = "resume" end,
}
local override = false
I.Controls.overrideMovementControls = function(b) override = b; log[#log + 1] = "override " .. tostring(b) end
local function yielded() return owners.Hookshot == true end

local mod = assert(loadfile(arg[2]))()
local H = mod.engineHandlers
local TETHER = "Settings_OpenMW_Hookshot_Tether"
local BASIC = "Settings_OpenMW_Hookshot_Basic"
local GATES = "Settings_OpenMW_Hookshot_Gates"
local function set(sec, k, v) S.section(sec):set(k, v) end
local DT = 1 / 60
local function frames(n) for _ = 1, n do S.time = S.time + DT; H.onUpdate(DT) end end

local function wallRays(from, to)
    local len = (to - from):length()
    if len > 150 and len < 260 then
        return { hit = true, hitPos = from, hitNormal = v3(-1, 0, 0) }
    end
    return { hit = false }
end

local function settle()
    for _ = 1, 6 do
        frames(40)
        if S.pose == nil then break end
        S.triggers['Jump']()
        S.triggers['HookshotSheath']()
    end
    frames(40)
end

local function fire(anchor)
    S.rayFn = wallRays
    settle()
    S.pos, S.onGround = v3(0, 0, 0), true
    S.messages, S.globalEvents, log = {}, {}, {}
    S.triggers['HookshotActivate']()
    for _ = 1, 4 do
        S.sharedRay({ hit = true, hitPos = anchor, hitObject = nil, distance = anchor:length() })
    end
    S.actions['Use'](true)
end

-- Frames until `pred`, at most n; the frame count, or nil.
local function until_(n, pred)
    for i = 1, n do frames(1); if pred() then return i end end
end

set(BASIC, "HOOK_TRAVEL_SPEED", 4000)
set(BASIC, "MAX_HOOKSHOT_RANGE", 3000)
set(BASIC, "PULL_SPD", 2000)
set(BASIC, "MIN_RAPPEL_CLEARANCE", 380)
set(BASIC, "RAPPEL_FUN_MODE", true)
set(GATES, "GATE_GRAPPLE", nil)
set(TETHER, "SWING_ENABLED", true)
S.equipment = { { recordId = "dbs_hookshot_ar" } }
H.onActive()

-- ---------------------------------------------------------------------------
realPrint("A. a self-pull and the hang it ends in")
set(TETHER, "DELAYED_FIRING", false)
check("FLOW free while the hookshot is only drawn", not yielded(), tostring(yielded()))
fire(v3(600, 0, 0))
local at = until_(120, yielded)
check("FLOW yielded once the pull carries the player", at ~= nil, at and (at .. " frames") or "never")
local held = until_(240, function() return override end)
check("the hang takes the override flag", held ~= nil, tostring(override))
local iy, io
for i, e in ipairs(log) do
    if e == "yield" and not iy then iy = i end
    if e == "override true" and not io then io = i end
end
check("yield is logged before the override write", iy and io and iy < io, table.concat(log, ", "))
frames(30)
check("still yielded while hanging", yielded())
S.triggers['Jump']()          -- Space drops the hang
local freed = until_(240, function() return not yielded() end)
check("FLOW resumed after the hang is dropped and the landing settles", freed ~= nil,
      freed and (freed .. " frames") or table.concat(log, ", "))
check("and the override is released", override == false)

-- ---------------------------------------------------------------------------
realPrint("\nB. tethered: the player walks free, FLOW is welcome")
set(TETHER, "DELAYED_FIRING", true)
set(TETHER, "SWING_ENABLED", true)
fire(v3(300, 0, 800))
frames(60)
check("tethered", S.messages[#S.messages] == "Rope attached - fire again to reel in", S.messages[#S.messages])
check("FLOW not yielded while merely tethered", not yielded(), table.concat(log, ", "))

realPrint("\nC. off the ledge into a swing")
S.pos = v3(0, 0, 0)
S.onGround = false
local G = 9.80665 * 400
local vz = 0
local swung = until_(60, function()
    vz = vz - G * DT
    S.pos = S.pos + v3(-300 * DT, 0, vz * DT)
    return S.pose == "hookhangdwn"
end)
check("a swing began", swung ~= nil, S.pose)
check("FLOW yielded for the swing", yielded())
S.actions['Use'](true)        -- release early: launch, land
S.onGround = false
local ended = until_(600, function()
    if S.pose ~= "hookhangdwn" then S.onGround = true end
    return not yielded()
end)
check("FLOW resumed once launch and landing are over", ended ~= nil,
      ended and (ended .. " frames") or table.concat(log, ", "))

-- ---------------------------------------------------------------------------
realPrint("\nD. load clears a hold")
set(TETHER, "DELAYED_FIRING", false)
fire(v3(600, 0, 0))
until_(120, yielded)
check("held before the load", yielded())
H.onLoad({ movementControlsOverridden = true })
check("onLoad resumes FLOW", not yielded(), table.concat(log, ", "))

realPrint(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

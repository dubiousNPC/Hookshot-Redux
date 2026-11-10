-- Which body parts each hookshot pose drives. The engine takes walking speed
-- from the leg animation, so a pose on LowerBody stops the player walking:
-- full body only while the hookshot moves the player.
-- arg[1] = stub path, arg[2] = player.lua path
local S = assert(loadfile(arg[1]))()
local v3 = S.v3

local realPrint = print
print = function() end

local pass, fail = 0, 0
local function check(label, ok, got)
    if ok then pass = pass + 1 else fail = fail + 1 end
    realPrint(("  %s  %-62s %s"):format(ok and "PASS" or "FAIL", label, tostring(got)))
end

local mod = assert(loadfile(arg[2]))()
local H = mod.engineHandlers
local BASIC = "Settings_OpenMW_Hookshot_Basic"
local TETHER = "Settings_OpenMW_Hookshot_Tether"
local function set(sec, k, v) S.section(sec):set(k, v) end
local DT = 1 / 60
local function frames(n) for _ = 1, n do S.time = S.time + DT; H.onUpdate(DT) end end

local LOWER = 1
local function full() return S.poseMask and S.poseMask % 2 == LOWER end
local function desc() return tostring(S.pose) .. (full() and " full" or " upper") end

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
    S.triggers['HookshotActivate']()
    for _ = 1, 4 do
        S.sharedRay({ hit = true, hitPos = anchor, hitObject = nil, distance = anchor:length() })
    end
    frames(1)
    realPrint("    drawn: " .. desc())
    check("aiming is upper body", S.pose == "hookaim" and not full(), desc())
    S.actions['Use'](true)
end
-- Frames until pred, at most n.
local function until_(n, pred) for i = 1, n do frames(1); if pred() then return i end end end

set(BASIC, "HOOK_TRAVEL_SPEED", 4000)
set(BASIC, "MAX_HOOKSHOT_RANGE", 3000)
set(BASIC, "PULL_SPD", 2000)
S.equipment = { { recordId = "dbs_hookshot_ar" } }
H.onActive()

realPrint("A. a wall grapple")
set(TETHER, "DELAYED_FIRING", false)
fire(v3(1200, 0, 0))
frames(1)
check("the shot on its way out is upper body", S.pose == "hookgo" and not full(), desc())
local pulled = until_(120, function() return S.pose == "hookgo" and full() end)
check("the pull is full body", pulled ~= nil, desc())
local handed = until_(240, function() return S.pose == "hookoff" end)
check("the hand-off plays hookoff", handed ~= nil, desc())
check("full body (the clip moves pelvis and legs)", handed and full(), desc())

realPrint("B. the planted dart")
set(TETHER, "DELAYED_FIRING", true)
fire(v3(300, 0, 800))
local teth = until_(120, function() return S.pose == "hookhang" end)
check("tethered plays hookhang", teth ~= nil, desc())
check("upper body: the player walks", teth and not full(), desc())
S.actions['Use'](true)        -- reel in
frames(1)
check("reeling in is a pull: full body", S.pose == "hookgo" and full(), desc())

realPrint(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

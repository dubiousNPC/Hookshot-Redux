-- Tether/swing edge cases the main tether_test does not reach: an anchor
-- ABOVE the player (a real ledge), momentum carried off the ground, and an
-- ordinary jump while tethered.
-- arg[1] = stub path, arg[2] = player.lua path
local S = assert(loadfile(arg[1]))()
local v3 = S.v3

local logs = {}
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    logs[#logs + 1] = table.concat(parts, " ")
end

local pass, fail = 0, 0
local function check(label, ok, got)
    if ok then
        pass = pass + 1
        realPrint(("  PASS  %-58s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        realPrint(("  FAIL  %-58s %s"):format(label, tostring(got)))
    end
end

local mod = assert(loadfile(arg[2]))()
local H = mod.engineHandlers
local TETHER = "Settings_OpenMW_Hookshot_Tether"
local BASIC = "Settings_OpenMW_Hookshot_Basic"
local GATES = "Settings_OpenMW_Hookshot_Gates"
local function set(sec, k, v) S.section(sec):set(k, v) end
local DT = 1 / 60
local function frames(n)
    for _ = 1, n do S.time = S.time + DT; H.onUpdate(DT) end
end

-- Only the 200-unit normal probe lands, as in tether_test: rappel-eligible.
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

local function tetherTo(anchor)
    S.rayFn = wallRays
    settle()
    S.pos = v3(0, 0, 0)
    S.onGround = true
    S.messages, S.globalEvents, logs = {}, {}, {}
    S.triggers['HookshotActivate']()
    for _ = 1, 4 do
        S.sharedRay({ hit = true, hitPos = anchor, hitObject = nil, distance = anchor:length() })
    end
    S.actions['Use'](true)
    frames(60)
    S.pos = v3(0, 0, 0)       -- wherever the stub left it, start the case here
    frames(1)
    return S.messages[#S.messages] == "Rope attached - fire again to reel in"
end

local function swingLog()
    for i = #logs, 1, -1 do
        local r, th, om = logs[i]:match("Swing begun radius%s+([%d.%-e]+)%s+theta%s+([%d.%-e]+)%s+omega%s+([%d.%-e]+)")
        if r then return tonumber(r), tonumber(th), tonumber(om) end
    end
end

set(BASIC, "HOOK_TRAVEL_SPEED", 4000)
set(BASIC, "MAX_HOOKSHOT_RANGE", 3000)
set(BASIC, "PULL_SPD", 2000)
set(BASIC, "MIN_RAPPEL_CLEARANCE", 380)
set(BASIC, "RAPPEL_FUN_MODE", true)
set(BASIC, "DEBUG_MODE", true)
set(GATES, "GATE_GRAPPLE", nil)
set(TETHER, "DELAYED_FIRING", true)
set(TETHER, "SWING_ENABLED", true)
S.equipment = { { recordId = "dbs_hookshot_ar" } }
H.onActive()

-- ---------------------------------------------------------------------------
realPrint("A. running off a ledge carries the run into the arc")
-- Anchor up and ahead: the ledge you hooked. Run AWAY from it at 300 u/s for
-- a few frames on the ground, then leave the ground.
local A = v3(300, 0, 800)
check("tethered to an overhead anchor", tetherTo(A), S.messages[#S.messages])
local RUN = 300
for _ = 1, 10 do
    S.pos = S.pos + v3(-RUN * DT, 0, 0)
    frames(1)
end
-- Off the edge: the run continues and gravity takes over, as the engine would
-- move the player, until the mod picks the swing up.
S.onGround = false
local G = 9.80665 * 400
local vz, vel = 0, nil
for _ = 1, 60 do
    vz = vz - G * DT
    vel = v3(-RUN, 0, vz)
    S.pos = S.pos + vel * DT
    frames(1)
    if S.pose == "hookhangdwn" then break end
end
local r, theta, omega = swingLog()
check("a swing began", r ~= nil, r)
if r then
    local toP = S.pos - A
    -- the run's component along the arc's tangent, as an angular rate
    local right = v3(-1, 0, 0)
    local tangent = right * math.cos(theta) + v3(0, 0, math.sin(theta))
    local expected = vel:dot(tangent) / r
    realPrint(("      radius %.0f  theta %.3f  omega %.4f rad/s  (run implies %.4f rad/s)")
        :format(r, theta, omega, expected))
    check("the run's speed is carried into the swing (within 25%)",
          math.abs(omega - expected) <= 0.25 * math.abs(expected),
          ("omega %.4f vs %.4f"):format(omega, expected))
end

-- ---------------------------------------------------------------------------
realPrint("\nB. an ordinary jump while tethered under the anchor")
-- Standing almost directly under the anchor and hopping: a jump, not a
-- leap off a ledge. The engine clears isOnGround for the airtime.
local B = v3(40, 0, 800)
S.onGround = true
check("tethered under the anchor", tetherTo(B), S.messages[#S.messages])
S.globalEvents, S.effects = {}, {}
S.pos = S.pos + v3(0, 0, 5)       -- first frame of a jump
S.onGround = false
frames(1)
local startedSwing = S.pose == "hookhangdwn"
check("a plain jump does not start a swing", not startedSwing, tostring(S.pose))
local held = 0
if startedSwing then
    for i = 1, 600 do
        frames(1)
        if S.pose ~= "hookhangdwn" then held = i; break end
    end
    local launched = false
    for _, e in ipairs(logs) do if e:find("Launched at", 1, true) then launched = true end end
    realPrint(("      the jump became a swing held for %.1f s, then %s")
        :format(held / 60, launched and "launched the player" or "ended"))
    check("and is not held aloft for seconds", held > 0 and held < 60,
          ("%.1f s"):format(held / 60))
end

for _, l in ipairs(logs) do if l:find("Tether") or l:find("rappel") or l:find("Swing") then realPrint("   log: " .. l) end end
realPrint(("\n%d passed, %d failed"):format(pass, fail))

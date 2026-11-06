-- Drives the real player.lua through a tether, a break and a swing.
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
local function check(label, got, want, tol)
    local ok
    if type(want) == "number" and type(got) == "number" then
        ok = math.abs(got - want) <= (tol or 1e-6)
    else
        ok = (got == want)
    end
    if ok then
        pass = pass + 1
        realPrint(("  PASS  %-44s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        realPrint(("  FAIL  %-44s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

local mod = assert(loadfile(arg[2]))()
local H = mod.engineHandlers

local TETHER = "Settings_OpenMW_Hookshot_Tether"
local BASIC = "Settings_OpenMW_Hookshot_Basic"
local GATES = "Settings_OpenMW_Hookshot_Gates"
local function set(sec, k, v) S.section(sec):set(k, v) end

local function frames(n, dt)
    dt = dt or 1 / 60
    for _ = 1, n do
        S.time = S.time + dt
        H.onUpdate(dt)
    end
end

local function countGlobal(name)
    local n = 0
    for _, e in ipairs(S.globalEvents) do if e.name == name then n = n + 1 end end
    return n
end

local function lastMessage() return S.messages[#S.messages] end
local function snapped() return lastMessage() == "The rope snaps!" end

-- A wall hit: the short normal probe lands with a horizontal normal; the longer
-- clearance and ledge probes miss, which is what makes a wall rappel-eligible.
-- Only the 200-unit surface-normal probe lands. The long clearance and ledge
-- probes miss, which is what makes a wall rappel-eligible, and the swing's
-- short step probe must miss or the arc releases on its first frame.
local function wallRays(from, to)
    local len = (to - from):length()
    if len > 150 and len < 260 then
        return { hit = true, hitPos = from, hitNormal = v3(-1, 0, 0) }
    end
    return { hit = false }
end

local ANCHOR_X = 600

-- Clears whatever the previous case left, then fires at a wall ANCHOR_X units
-- ahead on +X and runs the outbound travel through to attachment.
local function fireAt()
    S.rayFn = wallRays
    -- Settle first, then clear whatever the previous case ended in. A pull may
    -- still be in flight, and it can land in a hang, so this iterates.
    for _ = 1, 6 do
        frames(40)
        if S.pose == nil then break end
        S.triggers['Jump']()             -- drops out of a hang
        S.triggers['HookshotSheath']()   -- cuts a tether or sheathes
    end
    frames(40)
    S.pos = v3(0, 0, 0)
    S.onGround = true
    S.sounds, S.messages, S.globalEvents, logs = {}, {}, {}, {}

    S.triggers['HookshotActivate']()
    local hitPos = S.pos + v3(ANCHOR_X, 0, 0)
    for _ = 1, 4 do
        S.sharedRay({ hit = true, hitPos = hitPos, hitObject = nil, distance = ANCHOR_X })
    end
    S.actions['Use'](true)
    frames(60)
    return hitPos
end

-- ---------------------------------------------------------------------------
realPrint("settings")
check("DELAYED_FIRING default", S.section(TETHER):get("DELAYED_FIRING"), false)
check("TETHER_GRACE default", S.section(TETHER):get("TETHER_GRACE"), 120)
check("SWING_ENABLED default", S.section(TETHER):get("SWING_ENABLED"), true)
check("DART_VISIBLE default", S.section(TETHER):get("DART_VISIBLE"), true)

set(BASIC, "HOOK_TRAVEL_SPEED", 4000)
set(BASIC, "MAX_HOOKSHOT_RANGE", 2000)
set(BASIC, "PULL_SPD", 2000)
set(BASIC, "RAPPEL_CLIMB_SPD", 400)
set(BASIC, "RAPPEL_FUN_MODE", true)
set(BASIC, "MIN_RAPPEL_CLEARANCE", 380)
set(BASIC, "DEBUG_MODE", false)
set(GATES, "GATE_GRAPPLE", nil)
S.equipment = { { recordId = "dbs_hookshot_ar" } }
H.onActive()

-- ---------------------------------------------------------------------------
realPrint("\ndelayed firing off: the old pull path is untouched")
set(TETHER, "DELAYED_FIRING", false)
fireAt()
check("did not tether", lastMessage() ~= "Rope attached - fire again to reel in", true)

-- ---------------------------------------------------------------------------
realPrint("\ndelayed firing on: dart planted, rope held")
set(TETHER, "DELAYED_FIRING", true)
fireAt()
check("tethered", lastMessage(), "Rope attached - fire again to reel in")
check("pose is the rope hold", S.pose, "hookhang")
check("dart published", countGlobal('HookshotDartUpdate') > 0, true)

-- ---------------------------------------------------------------------------
realPrint("\nratchet: closing in shortens the rope, and the break point with it")
fireAt()
S.pos = v3(300, 0, 0)            -- 300 from the anchor
frames(2)
S.messages = {}
S.pos = v3(-100, 0, 0)           -- 700 away: past 300 + 120
frames(2)
check("snaps against the ratcheted length", snapped(), true)

realPrint("  the same move on an unratcheted rope holds")
fireAt()
S.messages = {}
S.pos = v3(-100, 0, 0)           -- 700 away: inside 600 + 120
frames(2)
check("holds at 700 on a 600 rope", snapped(), false)

-- ---------------------------------------------------------------------------
realPrint("\ngrace window")
fireAt()
S.messages = {}
S.pos = v3(-100, 0, 0)           -- 100 past 600
frames(2)
check("holds at +100 of 120", snapped(), false)
S.pos = v3(-140, 0, 0)           -- 140 past
frames(2)
check("snaps at +140 of 120", snapped(), true)

-- ---------------------------------------------------------------------------
realPrint("\nthe ratchet floors at the minimum length")
fireAt()
S.pos = v3(595, 0, 0)            -- 5 units off the anchor
frames(2)
S.messages = {}
S.pos = v3(390, 0, 0)            -- 210 away: inside the 120 floor + 120 grace
frames(2)
check("holds after touching the anchor", snapped(), false)
S.pos = v3(300, 0, 0)            -- 300 away: outside
frames(2)
check("snaps beyond floor + grace", snapped(), true)

-- ---------------------------------------------------------------------------
realPrint("\nswing: leaving the ground arcs, then releases with a boost")
fireAt()
check("tethered before the swing", lastMessage(), "Rope attached - fire again to reel in")

S.globalEvents, S.effects = {}, {}
-- Off the edge: airborne AND below the ground just left. Clearing onGround
-- alone is also what a jump does, and a swing must not start from a jump
-- (tether_edge_test, case B).
S.onGround = false
S.pos = S.pos + v3(0, 0, -50)
frames(1)
check("levitation applied", (S.effects.levitate or 0) > 0, true)
check("pose switched to the swing", S.pose, "hookhangdwn")

local before = countGlobal('ragdollTeleport')
local lowestZ, arcFrames = math.huge, 0
for i = 1, 600 do
    frames(1)
    if S.pos.z < lowestZ then lowestZ = S.pos.z end
    if S.pose == "hookhangdwn" then arcFrames = i end
    if S.pose ~= "hookhangdwn" then break end
end
check("the arc moved the player", countGlobal('ragdollTeleport') > before, true)
check("arc ran for a readable time", arcFrames > 10, true)
check("swung below the start height", lowestZ < 0, true)
realPrint(("      arc frames=%d  lowest z=%.1f  release pose=%s")
    :format(arcFrames, lowestZ, tostring(S.pose)))
frames(240)
check("levitation cleared on release", (S.effects.levitate or 0), 0)
check("rope and dart retracted", countGlobal('HookshotDartEnd') > 0, true)

-- ---------------------------------------------------------------------------
realPrint("\nswing honours its setting")
set(TETHER, "SWING_ENABLED", false)
fireAt()
S.effects = {}
S.onGround = false
S.pos = S.pos + v3(0, 0, -50)
frames(10)
check("no swing when disabled", (S.effects.levitate or 0), 0)
check("still tethered", S.pose, "hookhang")
set(TETHER, "SWING_ENABLED", true)

-- ---------------------------------------------------------------------------
realPrint("\nsecond fire press reels in")
fireAt()
logs = {}
set(BASIC, "DEBUG_MODE", true)
S.actions['Use'](true)
frames(2)
local reeled = false
for _, l in ipairs(logs) do
    if l:find("Tether retracting", 1, true) then reeled = true end
end
set(BASIC, "DEBUG_MODE", false)
check("retract ran", reeled, true)
check("pose left the rope hold", S.pose ~= "hookhang", true)

-- ---------------------------------------------------------------------------
realPrint("\nsheath cuts the tether")
fireAt()
check("tethered before sheathing", lastMessage(), "Rope attached - fire again to reel in")
S.globalEvents = {}
S.triggers['HookshotSheath']()
check("dart removed", countGlobal('HookshotDartEnd') > 0, true)
check("no pose held", S.pose, nil)

-- ---------------------------------------------------------------------------
realPrint("\ndart can be turned off")
set(TETHER, "DART_VISIBLE", false)
fireAt()
check("no dart events when hidden", countGlobal('HookshotDartUpdate'), 0)
check("still tethers", lastMessage(), "Rope attached - fire again to reel in")
set(TETHER, "DART_VISIBLE", true)

realPrint(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

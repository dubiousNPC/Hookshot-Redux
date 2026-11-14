-- Hookshot <-> Take a Seat (v0.44+, I.TakeASeat): while Take a Seat holds the
-- player (seated, lying or still getting up) the hookshot is neither drawn nor
-- fired; once it lets go, both work again. Take a Seat docs/tickets/0010.
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

local I = package.loaded['openmw.interfaces']
local busy = false
local mod = assert(loadfile(arg[2]))()
local H = mod.engineHandlers
local BASIC = "Settings_OpenMW_Hookshot_Basic"
local TETHER = "Settings_OpenMW_Hookshot_Tether"
local GATES = "Settings_OpenMW_Hookshot_Gates"
local function set(sec, k, v) S.section(sec):set(k, v) end
local DT = 1 / 60
local function frames(n) for _ = 1, n do S.time = S.time + DT; H.onUpdate(DT) end end
set(BASIC, "MAX_HOOKSHOT_RANGE", 3000)
set(GATES, "GATE_GRAPPLE", nil)
set(TETHER, "DELAYED_FIRING", true)
S.equipment = { { recordId = "dbs_hookshot_ar" } }
H.onActive()
S.rayFn = function() return { hit = false } end
local function aim() for _ = 1, 4 do S.sharedRay({ hit = true, hitPos = v3(300, 0, 800), hitObject = nil, distance = 854 }) end end
local function last() return S.messages[#S.messages] end

-- No Take a Seat installed: unchanged behaviour.
I.TakeASeat = nil
S.messages, S.globalEvents = {}, {}
S.triggers['HookshotActivate'](); aim(); frames(2)
S.actions['Use'](true); frames(30)
check("without Take a Seat the hookshot fires as before", last() == "Rope attached - fire again to reel in", last())
S.triggers['HookshotSheath'](); frames(60)

-- Seated: drawing is refused.
I.TakeASeat = { isBusy = function() return busy end }
busy = true
S.messages = {}
S.triggers['HookshotActivate'](); frames(2)
check("seated: drawing is refused with a message", last() == "Get up first", last())
S.actions['Use'](true); frames(30)
check("seated: nothing is fired", last() == "Get up first", last())

-- Drawn first, then sat down: firing is refused.
busy = false
S.messages = {}
S.triggers['HookshotActivate'](); aim(); frames(2)
busy = true
S.actions['Use'](true); frames(30)
check("drawn, then seated: firing is refused", last() == "Get up first", last())
check("and no hook travel was started", not (last() or ''):find('Rope attached'), last())

-- Free again.
busy = false
S.messages = {}
aim(); S.actions['Use'](true); frames(30)
check("after getting up the drawn hookshot fires", last() == "Rope attached - fire again to reel in", last())

-- A broken interface does not break the hookshot.
S.triggers['HookshotSheath'](); frames(60)
I.TakeASeat = { isBusy = function() error('boom') end }
S.messages = {}
S.triggers['HookshotActivate'](); aim(); frames(2)
S.actions['Use'](true); frames(30)
check("an erroring isBusy is treated as free", last() == "Rope attached - fire again to reel in", last())

realPrint(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

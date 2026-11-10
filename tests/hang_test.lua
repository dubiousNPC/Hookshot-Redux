-- Where a hang puts the player: Targeting.resolveHangPosition against simple
-- geometry (axis-aligned boxes and one 45-degree half-space).
-- arg[1] = stub path. Run from the mod root.
package.path = './?.lua;' .. package.path
local S = assert(loadfile(arg[1]))()
local v3 = S.v3

local realPrint = print
print = function() end
local T = require('scripts.OpenMWHookshot.hookshot_targeting')

local pass, fail = 0, 0
local function check(label, ok, got)
    if ok then pass = pass + 1 else fail = fail + 1 end
    realPrint(("  %s  %-64s %s"):format(ok and "PASS" or "FAIL", label, tostring(got)))
end

-- Solids: boxes {x0,x1,y0,y1,z0,z1}, or a function p -> inside.
local solids = {}
local function inside(p)
    for _, b in ipairs(solids) do
        if type(b) == "function" then
            if b(p) then return true end
        elseif p.x >= b[1] and p.x <= b[2] and p.y >= b[3] and p.y <= b[4] and p.z >= b[5] and p.z <= b[6] then
            return true
        end
    end
    return false
end
-- Marching ray: hit at the first sample inside a solid (a ray that starts
-- inside one counts as a hit, the conservative reading).
S.rayFn = function(from, to, opts)
    -- These solids are world geometry, never heightmap terrain.
    if opts and opts.collisionType == 4 then return { hit = false } end
    local d = to - from
    local len = d:length()
    local n = math.max(1, math.ceil(len / 2))
    for i = 0, n do
        local p = from + d * (i / n)
        if inside(p) then return { hit = true, hitPos = p, hitNormal = v3(0, 0, 1) } end
    end
    return { hit = false }
end

local DROP = 195
local function horiz(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local player = v3(0, 0, 0)

realPrint("wall face")
solids = { { -500, 500, 600, 800, 0, 800 } }
local a = v3(0, 600, 450)
local p = T.resolveHangPosition(a, v3(0, -1, 0), "wall", player - a)
check("found", p ~= nil, p)
if p then
    check("feet a ceiling-hang drop below the hook (was 20)", math.abs((a.z - p.z) - DROP) < 0.01, a.z - p.z)
    check("just clear of the face: 34 out (radius + 2)", math.abs(horiz(p, a) - 34) < 0.01, horiz(p, a))
    check("on the open side", p.y < 600, p.y)
end

realPrint("wall face, anchor 12 inside the face (the rendering-ray hit, as measured in game)")
a = v3(0, 612, 450)
p = T.resolveHangPosition(a, v3(0, -1, 0), "wall", player - a)
check("34 out from the face, not from the anchor", p and math.abs((600 - p.y) - 34) < 0.01, p and (600 - p.y))

realPrint("flat ceiling")
solids = { { -500, 500, 300, 1100, 700, 850 } }
a = v3(0, 500, 700)
p = T.resolveHangPosition(a, v3(0, 0, -1), "ceiling", player - a)
check("straight under the hook", p and horiz(p, a) < 0.01, p and horiz(p, a))
check("feet 195 below", p and math.abs(a.z - p.z - DROP) < 0.01, p and (a.z - p.z))

realPrint("flat ceiling with a partition right under the hook")
solids = { { -500, 500, 300, 1100, 700, 850 }, { -500, 500, 520, 560, 0, 550 } }
a = v3(0, 530, 700)
p = T.resolveHangPosition(a, v3(0, 0, -1), "ceiling", player - a)
check("moves toward the player only as far as needed", p and p.y < 520 - 32 and horiz(p, a) <= 72, p and horiz(p, a))

realPrint("45-degree sloped ceiling, open toward -y")
-- Solid above the plane z = 700 - (y - 500); outward normal (0,-1,-1)/sqrt2.
solids = { function(q) return q.z > 700 - (q.y - 500) end }
a = v3(0, 500, 700)
local n = v3(0, -1, -1):normalize()
p = T.resolveHangPosition(a, n, "ceiling", player - a)
check("found", p ~= nil, p)
check("within one step of straight under the hook (was 138 out)", p and horiz(p, a) <= 8, p and horiz(p, a))

realPrint("ledge: a floor hit 30 in from a platform edge")
solids = { { -500, 500, 600, 1400, 300, 450 } }
a = v3(0, 630, 450)
p = T.resolveHangPosition(a, v3(0, 0, 1), "floor", player - a)
check("found", p ~= nil, p)
if p then
    check("past the edge with the whole body (was inside the platform)", p.y + 32 < 600, p.y)
    check("by no more than a step beyond that", p.y + 32 >= 600 - 8, p.y)
    check("feet 195 below the hook", math.abs(a.z - p.z - DROP) < 0.01, a.z - p.z)
end

realPrint("ledge clearance (Rappel Fun Mode)")
S.section("Settings_OpenMW_Hookshot_Basic"):set("RAPPEL_FUN_MODE", true)
S.section("Settings_OpenMW_Hookshot_Basic"):set("MIN_RAPPEL_CLEARANCE", 380)
S.pos = v3(0, 0, 600)
-- A 150-thick platform with 450 of air under it (top 600, ground at 0).
solids = { { -500, 500, 600, 1400, 450, 600 }, { -2000, 2000, -2000, 2000, -50, 0 } }
check("a thick platform over 450 of air is a rappel ledge (read as 130 before)",
      T.checkRappelClearance(v3(0, 630, 600), v3(0, 0, 1)) == true)
solids = { { -500, 500, 600, 1400, 450, 600 }, { -2000, 2000, -2000, 2000, -50, 300 } }
check("the same platform 300 above the ground is not",
      T.checkRappelClearance(v3(0, 630, 600), v3(0, 0, 1)) == false)
solids = { { -500, 500, -2000, 1400, 450, 600 }, { -2000, 2000, -2000, 2000, -50, 0 } }
check("a platform that continues under the player has no edge",
      T.checkRappelClearance(v3(0, 630, 600), v3(0, 0, 1)) == false)

realPrint("nowhere clear: keep the legacy offset")
solids = { { -1000, 1000, -1000, 1000, -1000, 1000 } }
a = v3(0, 500, 700)
p = T.resolveHangPosition(a, v3(0, -1, 0), "wall", player - a)
check("returns nil", p == nil, p)

realPrint(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end

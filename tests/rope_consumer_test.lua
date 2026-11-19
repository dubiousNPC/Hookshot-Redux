-- Drives the REAL example_beam_consumer/global.lua with a recording BeamFX
-- adapter and a stand-in verlet module that follows the API the consumer
-- calls (newChain / pin / pointCount / points / update). This checks the
-- consumer's logic (point counts, taut vs slack, flips, reseed, teardown,
-- fallback); 'real' swaps the stand-in for BeamFX's own verlet.lua.
-- usage: luajit rope_consumer_test.lua <mod root> [noverlet | real <BeamFX root>]
local ROOT = arg[1]
local NO_VERLET = arg[2] == 'noverlet'
local REAL = arg[2] == 'real' and arg[3]
package.path = ROOT .. '/?.lua;' .. package.path

local pass, fail = 0, 0
local function check(name, ok, got)
    if ok then pass = pass + 1; print('  PASS  ' .. name)
    else fail = fail + 1; print('  FAIL  ' .. name .. '   got: ' .. tostring(got)) end
end

-- ---- engine stubs -------------------------------------------------------
local player = { id = 'player0', cell = { name = 'cell' } }
package.loaded['openmw.world'] = { players = { player } }
package.loaded['openmw.core'] = { getSimulationTime = function() return 0 end }
-- BeamFX present unless the run is 'noverlet' (the renderer checks the file).
package.loaded['openmw.vfs'] = { fileExists = function(p) return not NO_VERLET and p == 'scripts/beamfx/shared/verlet.lua' end }

-- ---- recording adapter ---------------------------------------------------
local calls = {}
local visuals = {}
function visuals:invoke(method, ...)
    local a = { ... }
    calls[#calls + 1] = { method = method, args = a }
    return true
end
function visuals:spaceKeyForCell(cell) return 'space:' .. cell.name end
function visuals:update() end
function visuals:reset() end
package.loaded['scripts.OpenMWHookshot.example_beam_consumer.beamfx_adapter'] =
    { new = function() return visuals end }

-- ---- stand-in verlet -----------------------------------------------------
local chainsMade = 0
if REAL then
    package.path = REAL .. '/?.lua;' .. package.path
    local real = dofile(REAL .. '/scripts/beamfx/shared/verlet.lua')
    package.loaded['scripts.beamfx.shared.verlet'] = setmetatable({ newChain = function(o) chainsMade = chainsMade + 1; return real.newChain(o) end }, { __index = real })
elseif not NO_VERLET then
    local V = {}
    function V.newChain(o)
        chainsMade = chainsMade + 1
        local n = o.segmentCount + 1
        local c = { n = n, pts = {}, prev = {}, acc = o.acceleration, drag = o.drag,
                    iters = o.constraintIterations, step = o.fixedStep, pinned = {}, opts = o }
        local dx, dy, dz = o.endPos.x - o.startPos.x, o.endPos.y - o.startPos.y, o.endPos.z - o.startPos.z
        c.rest = math.sqrt(dx * dx + dy * dy + dz * dz) * o.slack / o.segmentCount
        for i = 1, n do
            local t = (i - 1) / (n - 1)
            local p = { x = o.startPos.x + dx * t, y = o.startPos.y + dy * t, z = o.startPos.z + dz * t }
            c.pts[i] = p; c.prev[i] = { x = p.x, y = p.y, z = p.z }
        end
        c.pinned[1], c.pinned[n] = c.pts[1], c.pts[n]
        function c:pointCount() return self.n end
        function c:pin(i, pos)
            if type(pos) ~= 'table' and type(pos) ~= 'userdata' then return false end
            self.pinned[i] = { x = pos.x, y = pos.y, z = pos.z }
            self.pts[i] = { x = pos.x, y = pos.y, z = pos.z }
            return true
        end
        function c:update(dt)
            local h = self.step
            local steps = math.min(4, math.max(1, math.floor(dt / h + 0.5)))
            for _ = 1, steps do
                for i = 1, self.n do
                    if not self.pinned[i] then
                        local p, q = self.pts[i], self.prev[i]
                        local k = math.max(0, 1 - self.drag * h)
                        local nx = p.x + (p.x - q.x) * k + self.acc.x * h * h
                        local ny = p.y + (p.y - q.y) * k + self.acc.y * h * h
                        local nz = p.z + (p.z - q.z) * k + self.acc.z * h * h
                        self.prev[i] = { x = p.x, y = p.y, z = p.z }
                        self.pts[i] = { x = nx, y = ny, z = nz }
                    end
                end
                for _ = 1, self.iters do
                    for i = 1, self.n - 1 do
                        local a, b = self.pts[i], self.pts[i + 1]
                        local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if d > 1e-9 then
                            local diff = (d - self.rest) / d
                            local wa = self.pinned[i] and 0 or 1
                            local wb = self.pinned[i + 1] and 0 or 1
                            local w = wa + wb
                            if w > 0 then
                                a.x = a.x + dx * diff * wa / w; a.y = a.y + dy * diff * wa / w; a.z = a.z + dz * diff * wa / w
                                b.x = b.x - dx * diff * wb / w; b.y = b.y - dy * diff * wb / w; b.z = b.z - dz * diff * wb / w
                            end
                        end
                    end
                end
            end
        end
        function c:points()
            local out = {}
            for i = 1, self.n do out[i] = { x = self.pts[i].x, y = self.pts[i].y, z = self.pts[i].z } end
            return out
        end
        return c
    end
    package.loaded['scripts.beamfx.shared.verlet'] = V
end

-- ---- load the consumer ---------------------------------------------------
local script = dofile(ROOT .. '/scripts/OpenMWHookshot/example_beam_consumer/global.lua')
local events = dofile(ROOT .. '/scripts/OpenMWHookshot/example_beam_consumer/events.lua')
local onRope = script.eventHandlers[events.ROPE_UPDATE]
local onEnd = script.eventHandlers[events.ROPE_END]
local onUpdate = script.engineHandlers.onUpdate

local function last(method)
    for i = #calls, 1, -1 do if calls[i].method == method then return calls[i] end end
end
local function count(method)
    local n = 0
    for _, c in ipairs(calls) do if c.method == method then n = n + 1 end end
    return n
end
local function pointsOf(call)
    if not call then return nil end
    if call.method == 'replacePathPoints' then return call.args[2] end
    if call.method == 'upsertPath' then return call.args[2].points end
end
local function lastPoints()
    for i = #calls, 1, -1 do
        local p = pointsOf(calls[i]); if p then return p, calls[i].method end
    end
end
-- largest distance of an interior point below the straight line, and the arc length
local function sagOf(pts)
    local a, b = pts[1], pts[#pts]
    local maxSag, arc = 0, 0
    for i, p in ipairs(pts) do
        local t = (i - 1) / (#pts - 1)
        local lz = a.z + (b.z - a.z) * t
        if lz - p.z > maxSag then maxSag = lz - p.z end
        if i > 1 then
            local q = pts[i - 1]
            arc = arc + math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
        end
    end
    return maxSag, arc
end
local function collinear(pts)
    local s = sagOf(pts); return s < 1e-6
end

local FROM, TO = { x = 0, y = 0, z = 100 }, { x = 600, y = 0, z = 100 }

print(NO_VERLET and 'consumer without the verlet module (BeamFX absent)' or (REAL and 'consumer with BeamFX\'s REAL verlet module' or 'consumer with a stand-in verlet module'))

-- taut
onRope({ sender = player, from = FROM, to = TO, slack = false })
local p, m = lastPoints()
check('first taut update creates the path with upsertPath', m == 'upsertPath', m)
check('the path has 12 points', p and #p == 12, p and #p)
check('maxSegments is 11', last('upsertPath').args[2].maxSegments == 11, last('upsertPath').args[2].maxSegments)
check('taut points are on the straight line', p and collinear(p), p and sagOf(p))
check('taut endpoints are from and to', p and p[1].x == 0 and p[12].x == 600, p and p[12].x)
onRope({ sender = player, from = FROM, to = { x = 610, y = 0, z = 100 }, slack = false })
p, m = lastPoints()
check('a second taut update replaces the points in place', m == 'replacePathPoints', m)
local before = #calls
onUpdate(1 / 60)
check('no chain stepping while taut', #calls == before, #calls - before)

-- slack
onRope({ sender = player, from = FROM, to = TO, slack = true })
p, m = lastPoints()
check('slack update keeps 12 points', p and #p == 12, p and #p)
local stepCalls0 = count('replacePathPoints')
for _ = 1, 180 do onUpdate(1 / 60) end
local stepped = count('replacePathPoints') - stepCalls0
p = lastPoints()
local sag, arc = sagOf(p)
if NO_VERLET then
    check('without verlet the slack rope is drawn straight', collinear(p), sag)
    check('without verlet nothing is stepped per frame', stepped == 0, stepped)
else
    check('the chain is stepped every frame (180 frames -> 180 point replacements)', stepped == 180, stepped)
    check('after 3 s the rope hangs (sag > 100 on a 600 tether)', sag > 100, string.format('sag %.1f arc %.1f', sag, arc))
    check('arc length is about slack x straight (1.18 x 600)', math.abs(arc - 708) < 15, string.format('%.1f', arc))
    check('the slack rope still starts at the shoulder and ends at the dart',
        math.abs(p[1].x - 0) < 1e-6 and math.abs(p[12].x - 600) < 1e-6, p[1].x .. ',' .. p[12].x)
    print(string.format('    verlet: sag %.1f, arc %.1f', sag, arc))
    -- player walks: pins follow on the next event
    onRope({ sender = player, from = { x = 50, y = 30, z = 100 }, to = TO, slack = true })
    onUpdate(1 / 60)
    p = lastPoints()
    check('a walking update moves the shoulder pin', math.abs(p[1].x - 50) < 1e-6 and math.abs(p[1].y - 30) < 1e-6, p[1].x)
    check('no new chain for a small move', chainsMade == 1, chainsMade)
    onRope({ sender = player, from = { x = 50, y = 900, z = 100 }, to = TO, slack = true })
    check('a jump over 600 units reseeds the chain', chainsMade == 2, chainsMade)
end

-- flip back to taut
onRope({ sender = player, from = FROM, to = TO, slack = false })
p = lastPoints()
check('back to taut: straight again', collinear(p), sagOf(p))
before = #calls
onUpdate(1 / 60)
check('back to taut: the chain is no longer stepped', #calls == before, #calls - before)

-- slack again, then retract
onRope({ sender = player, from = FROM, to = TO, slack = true })
onEnd({ sender = player })
check('retract removes the path', last('remove') ~= nil, last('remove') and last('remove').args[1])
before = #calls
onUpdate(1 / 60)
check('after retract nothing is stepped', #calls == before, #calls - before)

-- load clears
onRope({ sender = player, from = FROM, to = TO, slack = true })
script.engineHandlers.onLoad()
before = #calls
onUpdate(1 / 60)
check('after onLoad nothing is stepped', #calls == before, #calls - before)

-- bad input
local ok = pcall(onRope, { sender = player, from = { x = 0 / 0, y = 0, z = 0 }, to = TO, slack = true })
check('a NaN position is ignored without error', ok, ok)

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end

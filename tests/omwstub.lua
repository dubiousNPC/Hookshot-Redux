-- Minimal OpenMW API stand-in, enough to run player.lua off-engine.
-- Returns a control table for driving the simulation.
local S = {
    pos = nil,                 -- set below
    onGround = true,
    rayHit = false,            -- castRay result for the next call
    rays = 0,
    globalEvents = {},
    localEvents = {},
    messages = {},
    sounds = {},
    effects = {},              -- effect -> magnitude
    triggers = {},
    actions = {},
    time = 0,
    pose = nil,
    poseLog = {},
}

-- ---------------------------------------------------------------- vector3
local vmt = {}
local function v3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end
vmt.__index = {
    length = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
    dot = function(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end,
    normalize = function(a)
        local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        if l == 0 then return v3(0, 0, 0), 0 end
        return v3(a.x / l, a.y / l, a.z / l), l
    end,
}
vmt.__add = function(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__sub = function(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
vmt.__unm = function(a) return v3(-a.x, -a.y, -a.z) end
vmt.__mul = function(a, b)
    if type(a) == "number" then return v3(b.x * a, b.y * a, b.z * a) end
    if type(b) == "number" then return v3(a.x * b, a.y * b, a.z * b) end
    error("vector3 * vector3 is not defined")
end
vmt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
vmt.__tostring = function(a) return ("(%.1f, %.1f, %.1f)"):format(a.x, a.y, a.z) end
S.v3 = v3

-- Transform: rotation only, composed as matrices, applied to a vector.
local tmt = {}
local function mat(m) return setmetatable({ m = m }, tmt) end
tmt.__index = {
    getYaw = function(t) return math.atan(t.m[1][3] and 0 or 0) end,
}
tmt.__mul = function(a, b)
    if getmetatable(b) == vmt then
        local m = a.m
        return v3(
            m[1][1] * b.x + m[1][2] * b.y + m[1][3] * b.z,
            m[2][1] * b.x + m[2][2] * b.y + m[2][3] * b.z,
            m[3][1] * b.x + m[3][2] * b.y + m[3][3] * b.z)
    end
    local p, q, r = a.m, b.m, {}
    for i = 1, 3 do
        r[i] = {}
        for j = 1, 3 do
            r[i][j] = p[i][1] * q[1][j] + p[i][2] * q[2][j] + p[i][3] * q[3][j]
        end
    end
    return mat(r)
end

package.loaded['openmw.util'] = {
    vector2 = function(x, y) return { x = x, y = y } end,
    vector3 = v3,
    transform = {
        rotateZ = function(a)
            local c, s = math.cos(a), math.sin(a)
            return mat({ { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } })
        end,
        rotateX = function(a)
            local c, s = math.cos(a), math.sin(a)
            return mat({ { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } })
        end,
    },
    remap = function(v, a, b, c, d)
        if b == a then return c end
        return c + (v - a) * (d - c) / (b - a)
    end,
    color = { hex = function() return {} end, rgba = function() return {} end },
}

-- ---------------------------------------------------------------- self
S.pos = v3(0, 0, 0)
local selfObj
selfObj = setmetatable({
    controls = { movement = 0, sideMovement = 0, jump = false, run = false,
                 yawChange = 0, pitchChange = 0 },
    type = {},
    recordId = "player",
    id = "player_0",
    isValid = function() return true end,
    sendEvent = function(_, name, data)
        S.localEvents[#S.localEvents + 1] = { name = name, data = data }
    end,
}, {
    __index = function(_, k)
        if k == 'position' then return S.pos end
        if k == 'rotation' then
            return { getYaw = function() return S.yaw or 0 end }
        end
        if k == 'object' then return selfObj end
        if k == 'cell' then return { name = "TestCell" } end
        return nil
    end,
})
package.loaded['openmw.self'] = selfObj

-- ---------------------------------------------------------------- nearby
package.loaded['openmw.nearby'] = {
    COLLISION_TYPE = { World = 1, Door = 2, HeightMap = 4, Actor = 8, AnyPhysical = 15 },
    items = {},
    actors = {},
    castRay = function(from, to, opts)
        S.rays = S.rays + 1
        if S.rayFn then return S.rayFn(from, to, opts) end
        if S.rayHit then
            return { hit = true, hitPos = to, hitNormal = v3(0, 0, 1) }
        end
        return { hit = false }
    end,
    castRenderingRay = function() return { hit = false } end,
}

-- ---------------------------------------------------------------- core
package.loaded['openmw.core'] = {
    getSimulationTime = function() return S.time end,
    getRealTime = function() return S.time end,
    magic = { EFFECT_TYPE = { Levitate = "levitate" } },
    sendGlobalEvent = function(name, data)
        S.globalEvents[#S.globalEvents + 1] = { name = name, data = data }
        if name == 'ragdollTeleport' and data and data.newPos then
            S.pos = data.newPos
        end
    end,
}

-- ---------------------------------------------------------------- types
package.loaded['openmw.types'] = {
    Actor = {
        STANCE = { Nothing = 0, Weapon = 1, Spell = 2 },
        isOnGround = function() return S.onGround end,
        isSwimming = function() return false end,
        getEquipment = function() return S.equipment or {} end,
        activeEffects = function()
            return {
                modify = function(_, mag, eff)
                    S.effects[eff] = (S.effects[eff] or 0) + mag
                end,
            }
        end,
        inventory = function() return {} end,
        stats = { dynamic = { health = function() return { current = 100 } end } },
        getPathfindingAgentBounds = function()
            return { halfExtents = v3(30, 30, 64) }
        end,
    },
    Player = {
        CONTROL_SWITCH = { Fighting = "Fighting", Magic = "Magic" },
        setControlSwitch = function() end,
        OFFENSE_TYPE = { Theft = 1 },
    },
    Item = { objectIsInstance = function(o) return o and o.isItem == true end },
    Light = { objectIsInstance = function() return false end },
}

-- ---------------------------------------------------------------- input
package.loaded['openmw.input'] = {
    ACTION_TYPE = { Boolean = 1, Range = 2 },
    registerTrigger = function() end,
    registerAction = function() end,
    registerTriggerHandler = function(k, fn) S.triggers[k] = fn end,
    registerActionHandler = function(k, fn) S.actions[k] = fn end,
    getRangeActionValue = function() return 0 end,
    getBooleanActionValue = function() return false end,
    isShiftPressed = function() return false end,
}

-- ---------------------------------------------------------------- misc
package.loaded['openmw.async'] = {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, _, f) return f end,
}
package.loaded['openmw.ambient'] = {
    playSoundFile = function(p) S.sounds[#S.sounds + 1] = p end,
    stopSoundFile = function() end,
}
package.loaded['openmw.camera'] = {
    getPosition = function() return S.pos + v3(0, 0, 120) end,
    getPitch = function() return 0 end,
    getYaw = function() return S.yaw or 0 end,
    getExtraPitch = function() return 0 end,
    getExtraYaw = function() return 0 end,
    MODE = { FirstPerson = 0, ThirdPerson = 1 },
    getMode = function() return 1 end,
}
package.loaded['openmw.ui'] = {
    showMessage = function(m) S.messages[#S.messages + 1] = m end,
    create = function() return { layout = { props = {} }, update = function() end } end,
    texture = function() return {} end,
    TYPE = { Flex = 1, Image = 2, Text = 3 },
    content = function(t) return t end,
    layers = { indexOf = function() return 1 end },
}
package.loaded['openmw.vfs'] = {
    pathsWithPrefix = function() return function() return nil end end,
    fileExists = function() return true end,
}
package.loaded['openmw.animation'] = {
    PRIORITY = { Default = 0, WeaponLowerBody = 1, SneakIdleLowerBody = 2, SwimIdle = 3,
                 Jump = 4, Movement = 5, Hit = 6, Weapon = 7, Block = 8, Knockdown = 9,
                 Torch = 10, Storm = 11, Death = 12, Scripted = 13 },
    BONE_GROUP = { LowerBody = 0, Torso = 1, LeftArm = 2, RightArm = 3 },
    BLEND_MASK = { LowerBody = 1, Torso = 2, LeftArm = 4, RightArm = 8, All = 15 },
    cancel = function(_, g)
        S.poseLog[#S.poseLog + 1] = "cancel " .. tostring(g)
        if S.pose == g then S.pose = nil end
    end,
    hasGroup = function() return true end,
    isPlaying = function() return true end,
    getTextKeyTime = function() return 0 end,
    playBlended = function() end,
}

local sections = {}
local function section(name)
    if sections[name] then return sections[name] end
    local t, subs = {}, {}
    local sec = {
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
S.section = section
package.loaded['openmw.storage'] = { playerSection = section, globalSection = section }

package.loaded['openmw.interfaces'] = {
    Settings = {
        registerPage = function() end,
        registerGroup = function(g)
            local sec = section(g.key)
            for _, st in ipairs(g.settings or {}) do sec:set(st.key, st.default) end
        end,
        registerRenderer = function() end,
    },
    AnimationController = {
        playBlendedAnimation = function(g, o)
            S.pose = g
            S.poseLog[#S.poseLog + 1] = "play " .. tostring(g)
        end,
    },
    Controls = { overrideMovementControls = function() end },
    Crimes = { commitCrime = function() return {} end },
    UI = { setMode = function() end },
    MWUI = { templates = {} },
    SharedRay = {
        requestDistance = function() end,
        subscribe = function(_, fn) S.sharedRay = fn end,
    },
}

-- Stub the two UI-heavy modules; everything else loads for real.
package.loaded['scripts.OpenMWHookshot.hookshot_reticle'] = {
    show = function() end, hide = function() end,
    update = function() end, updateAnimation = function() end,
    isVisible = function() return false end,
}
package.loaded['scripts.OpenMWHookshot.hookshot_menu'] = {
    open = function() end, isOpen = function() return false end, cancel = function() end,
}

return S

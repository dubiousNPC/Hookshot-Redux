---@omw-context player

--[[
    hookshot_physics.lua
    Ragdoll sequences, bounding boxes, collision detection, and physics tick loop.

    Owns the ragdoll data array and all movement simulation. The update function
    returns completion events instead of directly triggering state transitions —
    player.lua handles those via handleSequenceCompletion.
]]--

local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local settings = require('scripts.OpenMWHookshot.hookshot_settings')
local U = require('scripts.OpenMWHookshot.hookshot_util')

local debugPrint = settings.debugPrint
local addToVector3 = U.addToVector3
local isActor = U.isActor
local isAlive = U.isAlive

local Physics = {}

-- ==============================================
-- COLLISION MASKS
-- ==============================================
local ANY_PHY = nearby.COLLISION_TYPE.AnyPhysical
-- Hookshot collision mask: exclude water so hookshot works while swimming
local HOOKSHOT_PHY = nearby.COLLISION_TYPE.World
                   + nearby.COLLISION_TYPE.Door
                   + nearby.COLLISION_TYPE.HeightMap
                   + nearby.COLLISION_TYPE.Actor

-- ==============================================
-- PHYSICS CONSTANTS
-- ==============================================
local ITEM_Z_OFFSET = 0             -- Items can be very flat; minimal offset like RT
local BUMP_OFFSET = 25              -- Offset to prevent teleports from pushing objects through wall / floor
local ARRIVAL_RADIUS = 50           -- How close to targetP counts as "arrived" and ends the sequence.
                                    -- Deliberately separate from BUMP_OFFSET: that one is a COLLISION
                                    -- standoff, this one is an ARRIVAL test. They were the same constant,
                                    -- so tuning either silently retuned the other.
local DECEL_DISTANCE = 250          -- Start easing the pull down inside this distance from targetP
local DECEL_MIN_FACTOR = 0.25       -- Never ease below this fraction of the configured Pull Speed
local DECEL_MIN_SPEED = 300         -- ...nor below this absolute speed. NOTE: this floor is not cosmetic -
                                    -- STUCK_DIST_THRESHOLD/PREV_POS_UPDATE_DT below means anything slower
                                    -- than 100 units/sec reads as "stuck" and would terminate the sequence
                                    -- through the wrong branch. 300 keeps a 3x margin over that.
local STUCK_DIST_THRESHOLD = 5      -- Object has to move more than this distance per tick or sequence ends
local STUCK_COUNT_THRESHOLD = 3     -- Number of frames the object has been stuck before stopping ragdoll
local MAX_TIMEOUT = 2               -- Maximum ragdoll duration (seconds) for fail-safe purposes
local ITEM_HALF_WIDTH = 10          -- Bounding box data for items
local ITEM_HEIGHT = 20              -- Bounding box data for items
local PREV_POS_UPDATE_DT = 50/1000  -- Time to update prevPos
local BOUNDING_DATA_PTS = 6         -- Number of points that comprises of a bounding box
local SELF_PULL_GRACE_FRAMES = 5    -- Ignore collisions for first N frames of self-pull

local PLAYER_HEIGHT = U.PLAYER_HEIGHT

local M_TO_UNITS = 400              -- Gut-feel conversion from meters to Morrowind distance units
local TERMINAL_VELOCITY = 53 * M_TO_UNITS
local GRAVITY_MS2 = 9.80665 * M_TO_UNITS

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local ragDollData = {}

-- ==============================================
-- SEQUENCE FACTORIES
-- ==============================================
function Physics.createPullSequence(targetPos, speed, timeout, isItemPull)
    return {
        type = "PULL",
        targetP = targetPos,
        spd = speed or settings.pullSpeed(),
        timeout = timeout or MAX_TIMEOUT,
        contOnHit = false,
        contToTime = false,
        isItemPull = isItemPull or false,
    }
end

-- handoffDistance: if > 0, the drag ENDS this many units short of targetP
-- instead of driving all the way in, and the completion event carries a
-- `handoff` vector (target minus current position, world space) so the
-- caller can cover the remainder with engine movement. Pass 0/nil for the
-- old drag-all-the-way behaviour - rappel sequences do exactly that, since
-- a hang has to actually arrive at its hang position.
function Physics.createSelfPullSequence(targetPos, speed, timeout, landingData, handoffDistance)
    return {
        type = "SELF_PULL",
        targetP = targetPos,
        spd = speed or settings.pullSpeed(),
        timeout = timeout or MAX_TIMEOUT,
        contOnHit = false,
        contToTime = false,
        landingData = landingData,
        graceFrames = SELF_PULL_GRACE_FRAMES,
        handoffDistance = handoffDistance or 0,
    }
end

function Physics.createDropSequence(timeout)
    return {
        type = "DROP",
        v = util.vector3(0, 0, 0),
        timeout = timeout or MAX_TIMEOUT,
        applyG = true,
        contOnHit = true,
        contToTime = false,
    }
end

-- ==============================================
-- RAGDOLL DATA MANAGEMENT
-- ==============================================
function Physics.createRagdollData(target, boundingData, sequences, options)
    options = options or {}
    return {
        target = target,
        boundingData = boundingData,
        seqs = sequences,
        contOnHit = options.contOnHit or false,
        isFalling = options.isFalling or false,
        seqInit = false,
        travelled = 0,
        stuckCount = 0,
    }
end

function Physics.addRagdoll(ragdoll)
    table.insert(ragDollData, ragdoll)
end

function Physics.removeByTarget(target)
    U.arrayCompact(ragDollData, function(data, i, j)
        return data[i].target ~= target
    end)
end

function Physics.addSequence(ragdoll, sequence)
    table.insert(ragdoll.seqs, sequence)
end

-- ==============================================
-- COLLISION-AWARE TELEPORT
-- ==============================================
local function tpWithCollision(target, boundingData, newPos, startPos)
    if not target or not boundingData or not newPos then
        print("ERROR: tpWithCollision called with nil parameters")
        return {position = startPos or target.position, collided = true}
    end

    local pos = startPos or target.position
    local dirVector = (newPos - pos):normalize()
    local currVectorLen = (newPos - pos):length()
    local collidedWithSomething = false

    for idx = 1, BOUNDING_DATA_PTS do
        local tmpPos = pos + boundingData.sideVectors[idx]
        local obstacle = nearby.castRay(
            tmpPos,
            tmpPos + dirVector * math.max(0, currVectorLen),
            {
                collisionType = HOOKSHOT_PHY,
                ignore = target
            }
        )
        if obstacle.hitPos then
            collidedWithSomething = true
            currVectorLen = math.max(0, (tmpPos - obstacle.hitPos):length() - BUMP_OFFSET)
        end
    end

    local actualNewPos = pos + dirVector * currVectorLen
    core.sendGlobalEvent('ragdollTeleport', { object = target, newPos = actualNewPos })

    return {position = actualNewPos, collided = collidedWithSomething}
end

-- ==============================================
-- BOUNDING BOX CALCULATION
-- ==============================================
function Physics.getBoundingData(target)
    if not target then
        print("ERROR: getBoundingData called with nil target")
        return {
            halfWidth = ITEM_HALF_WIDTH,
            height = ITEM_HEIGHT,
            sideVectors = {
                util.vector3(0, 0, ITEM_Z_OFFSET),
                util.vector3(0, 0, ITEM_HEIGHT),
                util.vector3(ITEM_HALF_WIDTH, 0, ITEM_HEIGHT / 2),
                util.vector3(-ITEM_HALF_WIDTH, 0, ITEM_HEIGHT / 2),
                util.vector3(0, ITEM_HALF_WIDTH, ITEM_HEIGHT / 2),
                util.vector3(0, -ITEM_HALF_WIDTH, ITEM_HEIGHT / 2),
            }
        }
    end

    local halfWidth = ITEM_HALF_WIDTH
    local height = ITEM_HEIGHT
    local zOffset = ITEM_Z_OFFSET

    if target == self then
        halfWidth = 30
        height = PLAYER_HEIGHT
        zOffset = 10
    elseif isActor(target) then
        local MAX_ACTOR_RADIUS = 2000
        local pos = target.position

        local refPtTop = addToVector3(pos, 0, 0, MAX_ACTOR_RADIUS)
        local refFromAbove = nearby.castRay(pos, refPtTop, {
            collisionType = ANY_PHY,
            ignore = target
        })

        if refFromAbove.hitPos then
            refPtTop = addToVector3(refFromAbove.hitPos, 0, 0, -1)
        end

        local topBound = nearby.castRay(refPtTop, pos, {
            collisionType = ANY_PHY
        })

        if topBound.hitPos then
            height = (topBound.hitPos - pos):length()
        end

        local refPtX = addToVector3(pos, MAX_ACTOR_RADIUS, 0, height / 2)
        local refFromX = nearby.castRay(pos, refPtX, {
            collisionType = ANY_PHY,
            ignore = target
        })

        if refFromX.hitPos then
            refPtX = addToVector3(refFromX.hitPos, -1, 0, 0)
        end

        local xBound = nearby.castRay(refPtX, pos, {
            collisionType = ANY_PHY
        })

        if xBound.hitPos then
            halfWidth = (xBound.hitPos - pos):length()
        end

        local refPtY = addToVector3(pos, 0, MAX_ACTOR_RADIUS, height / 2)
        local refFromY = nearby.castRay(pos, refPtY, {
            collisionType = ANY_PHY,
            ignore = target
        })

        if refFromY.hitPos then
            refPtY = addToVector3(refFromY.hitPos, 0, -1, 0)
        end

        local yBound = nearby.castRay(refPtY, pos, {
            collisionType = ANY_PHY
        })

        if yBound.hitPos then
            halfWidth = math.max(halfWidth, (yBound.hitPos - pos):length())
        end

        if not isAlive(target) then
            height = height / 4
        end

        zOffset = 50
    end

    return {
        halfWidth = halfWidth,
        height = height,
        sideVectors = {
            util.vector3(0, 0, zOffset),
            util.vector3(0, 0, height),
            util.vector3(halfWidth, 0, height / 2),
            util.vector3(-halfWidth, 0, height / 2),
            util.vector3(0, halfWidth, height / 2),
            util.vector3(0, -halfWidth, height / 2),
        }
    }
end

-- ==============================================
-- SEQUENCE COMPLETION (bookkeeping only)
-- ==============================================
-- Removes the current sequence and resets bookkeeping fields.
-- Returns an event descriptor for player.lua to handle state transitions.
local function completeCurrentSequence(ragdoll)
    if not ragdoll or not ragdoll.seqs then return nil end

    local currentSeq = ragdoll.seqs[#ragdoll.seqs]
    if not currentSeq then return nil end

    debugPrint("Completing sequence, remaining:", #ragdoll.seqs - 1)

    -- Determine event type based on sequence
    local event

    if currentSeq.type == "PULL" and currentSeq.isItemPull then
        event = { type = "ITEM_PULL_COMPLETE", ragdoll = ragdoll }
    elseif currentSeq.type == "DROP" and ragdoll.target ~= self then
        event = { type = "ITEM_DROP_COMPLETE", ragdoll = ragdoll }
    elseif currentSeq.type == "SELF_PULL" and currentSeq.landingData then
        -- handoffVector is only ever set on the proximity-exit branch in
        -- update(). A sequence that ended because it timed out, got stuck,
        -- or hit something leaves it nil, so a BLOCKED grapple can never be
        -- mistaken for a clean release and given free momentum.
        event = {
            type = "SELF_PULL_COMPLETE",
            ragdoll = ragdoll,
            landingData = currentSeq.landingData,
            handoff = currentSeq.handoffVector,
        }
    else
        event = { type = "SEQUENCE_COMPLETE", ragdoll = ragdoll }
    end

    -- Bookkeeping: remove sequence and reset init state
    table.remove(ragdoll.seqs)
    ragdoll.seqInit = false
    ragdoll.bufferPosition = nil

    return event
end

-- ==============================================
-- MAIN UPDATE LOOP
-- ==============================================
-- Returns a list of completion events for player.lua to process.
-- isPaused should be true when item menu is open.
function Physics.update(deltaSeconds, isPaused)
    local events = {}

    if isPaused then return events end

    local wasActive = #ragDollData > 0

    U.arrayCompact(ragDollData, function(data, i, j)
        local o = data[i]

        if not o or not o.target or not o.seqs then
            return false
        end

        local lastIdx = #o.seqs
        if lastIdx <= 0 then
            return false
        end

        local s = o.seqs[lastIdx]
        if not s then
            return false
        end

        local objectPosition = o.bufferPosition or o.target.position
        if not objectPosition then
            print("ERROR: Object has no position")
            return false
        end

        if not o.seqInit then
            o.seqInit = true
            o.tElapsed = 0
            o.prevPos = objectPosition
            o.dtPrevPos = 0
            o.stuckCount = 0
            o.travelled = o.travelled or 0

            if s.targetP then
                o.origDist = (objectPosition - s.targetP):length()
            end
        else
            o.tElapsed = o.tElapsed + deltaSeconds
            o.dtPrevPos = o.dtPrevPos + deltaSeconds

            if o.prevPos and o.dtPrevPos >= PREV_POS_UPDATE_DT then
                local frameDist = (o.target.position - o.prevPos):length()
                o.travelled = o.travelled + frameDist

                if frameDist < STUCK_DIST_THRESHOLD then
                    o.stuckCount = o.stuckCount + 1
                    if o.stuckCount > STUCK_COUNT_THRESHOLD and not s.contToTime then
                        local event = completeCurrentSequence(o)
                        if event then table.insert(events, event) end
                        return true
                    end
                else
                    o.stuckCount = 0
                end

                o.prevPos = o.target.position
                o.dtPrevPos = 0
            end

            if s.timeout and o.tElapsed >= s.timeout then
                local event = completeCurrentSequence(o)
                if event then table.insert(events, event) end
                return true
            end
        end

        local movementV
        if s.targetP then
            movementV = s.targetP - objectPosition
            local currDist = movementV:length()

            -- Ease-out on approach (the "needs some lerp" part). Constant
            -- speed straight into a hard stop is what makes the end of a
            -- pull read as a snap; ramping down over the last DECEL_DISTANCE
            -- units lands it instead. Floored twice - once as a fraction of
            -- the configured speed, once absolutely - so a slow Pull Speed
            -- setting can't ease down into the stuck-detector's range.
            local speed = s.spd
            if currDist < DECEL_DISTANCE then
                speed = s.spd * math.max(DECEL_MIN_FACTOR, currDist / DECEL_DISTANCE)
                speed = math.max(speed, math.min(DECEL_MIN_SPEED, s.spd))
            end

            -- The arrival radius has to be at least one frame's travel, or the
            -- check can be stepped clean over: the object jumps from just
            -- outside the radius to just outside it on the FAR side, never
            -- landing inside, and then ping-pongs around the target until the
            -- stuck-detector times it out ~200ms later. That dead zone opens up
            -- whenever step > 2 * ARRIVAL_RADIUS - i.e. at high Pull Speed
            -- settings, or at ordinary speed on a low/uneven framerate, which
            -- is exactly the "few jagged frames at the end of the pull" this
            -- fixes. Derived from the EASED speed, not the nominal one, so it
            -- stays as tight as it can while still being tunnel-proof.
            local stepThisFrame = speed * deltaSeconds

            -- A handoff sequence exits EARLY: its release distance replaces
            -- ARRIVAL_RADIUS as the exit radius (never shrinks it - the
            -- tunnel-proofing below still applies on top).
            local exitRadius = ARRIVAL_RADIUS
            if s.handoffDistance and s.handoffDistance > 0 then
                exitRadius = math.max(ARRIVAL_RADIUS, s.handoffDistance)
            end
            local arrivalRadius = math.max(exitRadius, stepThisFrame * 1.1)

            if currDist < arrivalRadius then
                if not s.contToTime then
                    -- movementV is still the raw target-minus-position delta
                    -- at this point (it doesn't get normalized until below),
                    -- which is exactly the direction+distance the caller
                    -- needs to finish the move under engine movement.
                    if s.handoffDistance and s.handoffDistance > 0 then
                        s.handoffVector = movementV
                    end
                    local event = completeCurrentSequence(o)
                    if event then table.insert(events, event) end
                end
                return true
            end

            movementV = movementV:normalize() * speed
        else
            movementV = s.v
        end

        if s.applyG then
            local verticalV = movementV.z - GRAVITY_MS2 * deltaSeconds
            verticalV = math.max(verticalV, -TERMINAL_VELOCITY)
            movementV = util.vector3(movementV.x, movementV.y, verticalV)
            s.v = movementV
        end

        local displacement = movementV * deltaSeconds
        local newPos = objectPosition + displacement

        local tpResult
        if s.graceFrames and s.graceFrames > 0 then
            s.graceFrames = s.graceFrames - 1
            -- Grace frames: skip the collision cage entirely rather than
            -- running it and discarding the result. Previously the cage
            -- still ran and clamped the move distance even though the
            -- resulting `collided` flag got zeroed out afterward - that's
            -- what caused the "sticking" at the start of a self-pull
            -- (you're standing right against the wall you just hooked, so
            -- the cage clamps you to near-zero movement even though grace
            -- frames are supposed to let you move freely away from it).
            -- This also saves the 6 raycasts the cage would have spent
            -- computing a result we were just going to throw away.
            core.sendGlobalEvent('ragdollTeleport', { object = o.target, newPos = newPos })
            tpResult = { position = newPos, collided = false }
        else
            tpResult = tpWithCollision(o.target, o.boundingData, newPos, objectPosition)
        end

        if tpResult.collided then
            if not o.contOnHit and not s.contOnHit and not s.contToTime then
                local event = completeCurrentSequence(o)
                if event then table.insert(events, event) end
                return false
            elseif not s.contOnHit and not s.contToTime then
                local event = completeCurrentSequence(o)
                if event then table.insert(events, event) end
                return true
            end
        end

        o.bufferPosition = tpResult.position

        return true
    end)

    if wasActive and #ragDollData == 0 then
        table.insert(events, { type = "ALL_COMPLETE" })
    end

    return events
end

return Physics

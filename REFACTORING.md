# Hookshot Enhanced — Refactoring Design Document

## Problem Statement

`player.lua` is ~2121 lines (post-Phase 0 cleanup) containing 7 distinct subsystems with interleaved concerns:
settings registration, reticle UI, targeting/raycasting, ragdoll physics, hanging/rappel state,
action dispatch, and input handling. Changing one subsystem requires reading and risk-assessing
the entire file. Several secondary issues compound this: settings are loaded once and never
refreshed, debug prints litter hot paths unconditionally, and dead code remains in-tree.

## Goals

1. Split `player.lua` into focused modules with clear interfaces.
2. Make settings reactive (changes apply without `reloadlua`).
3. Clean up debug logging, dead code, and stale comments.
4. Every phase produces a working mod — no "big bang" rewrites.

## Non-Goals

- Changing gameplay behavior or adding features.
- Rewriting the OpenMW API layer or hookshot_orient / hookshot_menu.
- Optimizing performance beyond what falls out naturally from cleanup.

---

## Constraints: OpenMW Lua Scripting

**Modules loaded by a player script share its API context.** `hookshot_menu.lua` already
does `local self = require('openmw.self')` at line 16 — proof that any module `require`d
from a player/local script can directly import `openmw.self`, `openmw.nearby`, etc. No
dependency injection is needed for extracted modules.

**`require()` runs at script load time.** Module-level code (settings registration, input
trigger registration) executes immediately when the script loads. This means settings and
input registration must remain at module scope, not inside lazy init functions.

**`interfaces.Settings.registerPage/Group` must be called before `storage.playerSection`
reads.** Registration order matters.

---

## Target File Structure

```
scripts/OpenMWHookshot/
  player.lua              (805 lines) State machine, action dispatch, onUpdate orchestration
  global.lua              (115 lines, cleanup done)
  hookshot_settings.lua   (327 lines) ✓ DONE — Settings registration, reactive loading, debugPrint
  hookshot_util.lua       (100 lines) ✓ DONE — Pure math, type checkers, array helpers, shared constants
  hookshot_reticle.lua    (203 lines) ✓ DONE — Reticle manager, animation, crosshair UI
  hookshot_targeting.lua  (386 lines) ✓ DONE — Raycasting pipeline, surface analysis, target classification
  hookshot_physics.lua    (446 lines) ✓ DONE — Ragdoll sequences, bounding boxes, collision, physics tick
  hookshot_orient.lua     (146 lines, cleanup done)
  hookshot_menu.lua       (263 lines, cleanup done)
```

---

## Module Designs

### 1. `hookshot_settings.lua`

**Responsibility:** Own all settings registration, provide reactive access to current values,
export `debugPrint`.

**Exports:**
```lua
local settings = require('scripts.OpenMWHookshot.hookshot_settings')

-- All setting values are accessed via function calls (always current):
settings.maxRange()          -- returns number
settings.pullSpeed()         -- returns number
settings.rappelFunMode()     -- returns boolean
settings.minRappelClearance()-- returns number
settings.debugMode()         -- returns boolean

-- Reticle settings
settings.reticleIcon()       -- returns string
settings.reticleIdleSize()   -- returns number
settings.reticleMinSize()    -- returns number
settings.reticleMaxSize()    -- returns number
settings.reticleMinDistance() -- returns number
settings.reticleMaxDistance() -- returns number
settings.lockAnimation()     -- returns boolean

-- Color settings
settings.color(targetType)   -- returns Color for "none"/"floor"/"wall"/"ceiling"/"rappel"/"enemy"/"item"

-- Icon data (computed once at load, needed by reticle icon setting dropdown)
settings.iconNames           -- string array
settings.useFallbackTextures -- boolean

-- Debug helper
settings.debugPrint(...)     -- prints if debug mode is on

-- Sound paths
settings.sounds.toggle       -- "Sound/Hookshot_Toggle.mp3"
settings.sounds.set          -- "Sound/Hookshot_Set.mp3"
settings.sounds.fire         -- "Sound/Hookshot_Fire.mp3"
settings.sounds.target       -- "Sound/Hookshot_Target.mp3"

-- Constants that don't change
settings.MOD_VERSION         -- "0.4.3-beta"
```

**How reactivity works:** Instead of loading settings into locals at module scope, each accessor
calls `section:get(key)` on every access. OpenMW's storage system caches internally, so this is
just a hash table lookup — not a performance concern. The `debugPrint` function checks
`settings.debugMode()` live, so toggling debug in the settings menu takes effect immediately.

**What moves here:** (line numbers are post-Phase 0)
- Lines 82-107: icon scanning logic (needed to build the reticle icon dropdown)
- Lines 115-328: all `registerPage`, `registerGroup`, `registerTrigger`, `registerAction` calls
- Lines 333-364: `storage.playerSection` creation and setting reads
- Lines 366-370: `debugPrint`
- Lines 574-577: sound path constants

**Dependencies:** `interfaces`, `storage`, `input`, `vfs`, `util` (all available at module scope)

**Note on input registration:** `input.registerTrigger` and `input.registerAction` must run
at module scope before the settings that reference them. This module will do both, since
input bindings appear in the settings UI. The trigger *handlers* (what to do when fired)
stay in `player.lua`.

---

### 2. `hookshot_util.lua`

**Responsibility:** Pure functions with no OpenMW side effects. Math utilities and object
type classification.

**Exports:**
```lua
local U = require('scripts.OpenMWHookshot.hookshot_util')

-- Math
U.anglesToV(pitch, yaw)                    -- returns Vector3
U.addToVector3(v, xDiff, yDiff, zDiff)     -- returns Vector3
U.clamp(value, min, max)                   -- returns number
U.remapClamped(value, oldMin, oldMax, newMin, newMax) -- returns number
U.angleBetweenVectors(v1, v2)              -- returns radians

-- Type checkers
U.isCarriableItem(obj)     -- returns boolean (Item AND NOT Light)
U.isActor(obj)             -- returns boolean
U.isGrabbable(obj)         -- returns boolean (carriable item OR actor)
U.isAlive(actor)           -- returns boolean
U.getHP(actor)             -- returns number

-- Array helpers
U.arrayCompact(t, keepFn)  -- in-place compaction (renamed from ArrayIter for clarity)
```

**What moves here:** (line numbers are post-Phase 0)
- Lines 700-712: `ArrayIter` → renamed `arrayCompact`
- Lines 717-735: `anglesToV`, `addToVector3`, `clamp`
- Lines 402-405: `remapClamped`
- Lines 745-758: type checkers (`isCarriableItem`, `isActor`, `isGrabbable`)
- Lines 737-741: `getHP`, `isAlive`
- Lines 768-774: `angleBetweenVectors`

**Dependencies:** `types`, `util` only. No `self`, `nearby`, `camera`, `input`.

---

### 3. `hookshot_reticle.lua`

**Responsibility:** Crosshair UI element lifecycle — create, show, hide, animate, update
color/size. Knows nothing about targeting or game state.

**Exports:**
```lua
local Reticle = require('scripts.OpenMWHookshot.hookshot_reticle')

Reticle:init()                              -- create UI element (idempotent)
Reticle:show()                              -- make visible, hide engine crosshair
Reticle:hide()                              -- hide, restore engine crosshair
Reticle:update(hasTarget, targetType, distance)  -- update visuals
Reticle:updateAnimation(deltaSeconds)       -- tick lock-on bounce
```

**What moves here:** (line numbers are post-Phase 0)
- Lines 375-569: entire `ReticleManager` object
- Lines 69-70: reticle animation constants (`LOCK_ON_ANIMATION_DURATION`,
  `LOCK_ON_BOUNCE_SIZE`) — these are internal to the reticle, not user-facing settings

**Internal changes:**
- Instead of reading `COLOR_ENEMY`, `RETICLE_IDLE_SIZE` etc. from local variables, the
  module calls `settings.color(targetType)`, `settings.reticleIdleSize()`, etc.
- Icon path resolution uses `settings.iconNames` and `settings.useFallbackTextures`.
- `debugPrint` calls become `settings.debugPrint(...)`.
- Texture path constants (`RETICLE_TEXTURE_PATH`, `FALLBACK_TEXTURE_PATH`) move here
  since they're only used for icon resolution.

**Dependencies:** `ui`, `camera`, `util`, `hookshot_settings`

**Note:** This module does NOT import `openmw.self`. The `:` method syntax creates its own
`self` parameter referring to the ReticleManager table, not the player object.

---

### 4. `hookshot_targeting.lua`

**Responsibility:** Everything between "where is the camera pointing?" and "what did we hit?"
Raycasting, surface probing, rappel clearance checks, ledge detection, target classification,
and the fallback cone search for small objects.

**Exports:**
```lua
local Targeting = require('scripts.OpenMWHookshot.hookshot_targeting')

-- Camera query
Targeting.getCameraDirData()  -- returns pos, dirV, yaw, pitch

-- Surface analysis (all receive explicit parameters, no hidden state)
Targeting.probeSurfaceNormal(hitPos, approachDir)
Targeting.checkRappelClearance(hitPos, hitNormal)
Targeting.checkLedgeEdge(hitPos, hitNormal, cameraPos, cameraPitch, surfaceType)
Targeting.getTargetType(hitObject, surfaceType, hitPos, hitNormal, cameraPos, cameraPitch)

-- Fallback detection
Targeting.findGrabbableNearAim(cameraPos, cameraDir, maxRange)
```

**What moves here:** (line numbers are post-Phase 0)
- Lines 840-845: `getCameraDirData`
- Lines 850-866: `probeSurfaceNormal`
- Lines 870-974: `checkRappelClearance`
- Lines 991-1068: `checkLedgeEdge`
- Lines 1073-1130: `getTargetType`
- Lines 765-826: `ITEM_DETECTION_ANGLE_THRESHOLD`, `findGrabbableNearAim`
- Lines 73-76: ledge detection constants (`PLAYER_HEIGHT`, `DOWNWARD_LOOK_THRESHOLD`,
  `LEDGE_EDGE_TOLERANCE`, `LEDGE_PROBE_CLEARANCE`)

**Collision mask:** This module defines `HOOKSHOT_PHY` locally via
`nearby.COLLISION_TYPE.World + Door + HeightMap + Actor`. The same one-liner is also
defined in `hookshot_physics.lua`. This avoids a cross-dependency between the two modules.

**What stays in player.lua:**
- `tryDrawReticle` — orchestrates the targeting module, reticle module, and frame-throttled
  state cache. It belongs in the main state machine.

**Dependencies:** `camera`, `nearby`, `self`, `hookshot_settings`, `hookshot_util`,
`hookshot_orient` (all directly `require`d — no injection needed)

---

### 5. `hookshot_physics.lua`

**Responsibility:** Ragdoll simulation primitives: sequence creation, bounding box measurement,
collision-aware teleportation, and the physics tick loop. Reports sequence completion events
back to the caller — does NOT own state machine transitions.

**Exports:**
```lua
local Physics = require('scripts.OpenMWHookshot.hookshot_physics')

-- Sequence factories
Physics.createPullSequence(targetPos, speed, timeout, isItemPull)
Physics.createSelfPullSequence(targetPos, speed, timeout, landingData)
Physics.createDropSequence(timeout)

-- Ragdoll lifecycle
Physics.createRagdollData(target, boundingData, sequences, options)
Physics.addRagdoll(ragdollData)
Physics.removeByTarget(target)
Physics.hasActiveRagdolls()

-- Physics primitives
Physics.getBoundingData(target)
Physics.tpWithCollision(target, boundingData, newPos, startPos)

-- Main tick — returns list of completion events:
-- Each event: { ragdoll = ragdollData, sequence = completedSeq }
Physics.update(deltaSeconds)
```

**The completion event pattern:** Currently, `updateRagdoll` calls `removeCurrentSequence`
which directly opens menus, changes hookshot state, applies levitation, etc. After extraction,
`Physics.update(dt)` returns a list of "this sequence just completed" events. The physics
module handles its own bookkeeping (removing the completed sequence from `ragdoll.seqs`,
resetting `seqInit` and `bufferPosition`) before emitting the event. `player.lua` iterates
the events and handles state transitions:

```lua
-- In player.lua onUpdate:
local completions = Physics.update(deltaSeconds)
for _, event in ipairs(completions) do
    handleSequenceCompletion(event.ragdoll, event.sequence)
end
```

`handleSequenceCompletion` is the state-transition half of the current `removeCurrentSequence`,
living in `player.lua` where it has access to the state machine, menu system, sound, etc.

**What moves here:** (line numbers are post-Phase 0)
- Lines 43-66: physics constants (GRAVITY, TERMINAL_VELOCITY, BUMP_OFFSET, stuck thresholds,
  grace frames, etc.)
- Lines 640-695: sequence factories and ragdoll data constructor
- Lines 831-835: `rmFromRagDollData` (renamed `removeByTarget`)
- Lines 1265-1296: `tpWithCollision`
- Lines 1301-1403: `getBoundingData`
- Lines 1778-1896: `updateRagdoll` inner loop (refactored: ragdoll bookkeeping stays here,
  state transitions are emitted as events)

**What stays in player.lua:**
- `removeCurrentSequence` → refactored as `handleSequenceCompletion` (state transitions only)
- `dropObject`, `terminateHook` — these touch sound and state
- `pullHookedObject`, `hookToWorldObject` — these orchestrate physics + state

**Collision mask:** Defines `HOOKSHOT_PHY` and `ANY_PHY` locally (same one-liner as targeting).

**Dependencies:** `core` (for `sendGlobalEvent`), `nearby`, `self`, `hookshot_util`,
`hookshot_settings` (all directly `require`d)

---

### 6. What remains in `player.lua` (~600 lines)

After extraction, player.lua becomes the **state machine orchestrator**:

```
Imports & module init          (~30 lines)
State definition               (~55 lines)  HookshotState enum, state table
Targeting orchestration        (~70 lines)  tryDrawReticle (calls Targeting + Reticle)
Sequence completion handler    (~115 lines) handleSequenceCompletion (ex-removeCurrentSequence)
dropObject + terminateHook     (~25 lines)
handleItemMenuAction           (~37 lines)
Landing & hanging states       (~150 lines) updateLandingState, updateHangingState,
                                            clearHangingLevitation, releaseFromHang
Action handlers                (~52 lines)  pullHookedObject, hookToWorldObject
State management               (~85 lines)  draw/fire/sheath/activate
Input handlers + onUpdate      (~50 lines)  trigger handlers, onUpdate, onFrame, exports
```

The hanging/landing subsystem stays here because it's tightly coupled to `self.controls`,
`camera` mode enforcement, `input` polling, and levitation effects — extracting it would
just create a module with the same dependencies as player.lua itself.

---

## Cleanup Items (Phase 0 — COMPLETED)

All Phase 0 items have been applied. No architecture changes — local edits only.

### player.lua (2138 → 2121 lines)

| Issue | Status | What was done |
|---|---|---|
| Unconditional `print()` in `updateHangingState` | Done | 9 prints → `debugPrint` (per-frame hot path + rappel input) |
| Unconditional `print()` on trigger fire | Done | 3 prints → `debugPrint` (HookshotActivate, HookshotSheath, Jump-while-hanging) |
| Magic number `128` for player height | Done | Replaced with existing `PLAYER_HEIGHT` constant |
| Windows backslashes in sound paths | Done | 4 paths: `Sound\\*` → `Sound/*` |
| Dead function `getName` | Done | Deleted (6 lines, never called) |
| Dead function `isObjectBeingRagdolled` | Done | Deleted (8 lines, never called) |

### hookshot_orient.lua (186 → 146 lines)

| Issue | Status | What was done |
|---|---|---|
| Dead function `getRotationDifference` | Done | Deleted (39 lines — placeholder that computed axis/angle then returned identity) |

### hookshot_menu.lua (294 → 263 lines)

| Issue | Status | What was done |
|---|---|---|
| Stale header comment says "3-button" | Done | Fixed to "2-button", removed Context action bullet |
| Dead function `getContextAction` | Done | Deleted (23 lines — was the removed third context button) |
| Unused imports `core`, `self` | Done | Both removed |

### global.lua (118 → 115 lines)

| Issue | Status | What was done |
|---|---|---|
| Unused variable `ownerId` | Done | Removed declaration and assignment. Kept `isStolen = true` on the recordId branch. |

### Intentionally unchanged

One-time registration prints in player.lua (lines 127, 136, 144, etc.) run before
`debugPrint` is defined. Since they execute exactly once at load time, they are acceptable
as unconditional `print` and were left alone.

---

## Roadmap

### Phase 0: Cleanup — COMPLETED
**Risk: Minimal** — No structural changes. Every fix was a local edit.

All items applied. Awaiting in-game verification.

### Phase 1: Extract `hookshot_settings.lua` — COMPLETED
**Risk: Low** — Settings are a read-only data provider.

Created `hookshot_settings.lua` (327 lines). `player.lua` reduced from 2121 → 1806 lines.

What was done:
1. Created `hookshot_settings.lua` with: icon scanning, all settings/input registration,
   reactive function-style accessors (`settings.maxRange()`, `settings.pullSpeed()`, etc.),
   `settings.color(targetType)` lookup, `settings.debugPrint(...)`, sound path table, MOD_VERSION.
2. Removed from `player.lua`: all `registerPage`/`registerGroup`/`registerTrigger`/`registerAction`
   blocks, `storage.playerSection` creation, setting locals, icon scanning, sound path constants,
   `debugPrint` definition, unused imports (`interfaces`, `storage`, `vfs`).
3. Replaced all references: `PULL_SPD` → `settings.pullSpeed()`, `MAX_HOOKSHOT_RANGE` →
   `settings.maxRange()`, `COLOR_*` → `settings.color(type)`, `hookshotFire` →
   `settings.sounds.fire`, etc. (full replace-all verified by grep).
4. `ReticleManager:getColor()` simplified from 18-line if/elseif chain to single
   `settings.color(self.state.targetType)` call.
5. Settings page description updated: removed "reload the game or run reloadlua" instruction.
6. `debugPrint` in player.lua is now `local debugPrint = settings.debugPrint` — an alias
   so all 75+ call sites remain unchanged.

Awaiting in-game verification: change Pull Speed in settings menu, fire hookshot — new
speed should apply without `reloadlua`.

### Phase 2: Extract `hookshot_util.lua` — COMPLETED
**Risk: Low** — Pure functions, easily tested by calling them.

Created `hookshot_util.lua` (95 lines). `player.lua` reduced from 1806 → 1742 lines.

What was done:
1. Created `hookshot_util.lua` with: `anglesToV`, `addToVector3`, `clamp`, `remapClamped`,
   `angleBetweenVectors`, `getHP`, `isAlive`, `isCarriableItem`, `isActor`, `isGrabbable`,
   `arrayCompact` (renamed from `ArrayIter`).
2. In `player.lua`: added `local U = require(...)` plus local aliases for all functions
   (e.g., `local isActor = U.isActor`). This preserves all existing call sites unchanged.
3. Removed old function definitions (64 lines deleted from player.lua).

Awaiting in-game verification.

### Phase 3: Extract `hookshot_reticle.lua` — COMPLETED
**Risk: Low** — Self-contained UI, clear interface boundary.

Created `hookshot_reticle.lua` (203 lines). `player.lua` reduced from 1742 → 1560 lines.

What was done:
1. Created `hookshot_reticle.lua` with: full `ReticleManager` object (renamed `Reticle`),
   animation constants (`LOCK_ON_ANIMATION_DURATION`, `LOCK_ON_BOUNCE_SIZE`), texture path
   resolution via `settings.useFallbackTextures`/`RETICLE_TEXTURE_PATH`/`FALLBACK_TEXTURE_PATH`.
2. Module imports: `ui`, `camera`, `util`, `hookshot_settings`, `hookshot_util` (for `remapClamped`).
3. In `player.lua`: removed entire ReticleManager block (176 lines), animation constants (3 lines),
   unused `remapClamped` alias. Added `local Reticle = require(...)`.
4. All 9 call sites renamed: `ReticleManager:` → `Reticle:`.

Awaiting in-game verification: draw hookshot, observe reticle shows/hides/changes color/animates.

### Phase 4: Extract `hookshot_targeting.lua` — COMPLETED
**Risk: Medium** — Multiple raycasting functions with cross-cutting settings dependencies.

Created `hookshot_targeting.lua` (386 lines). `player.lua` reduced from 1560 → 1201 lines.
`hookshot_util.lua` updated to 100 lines (added shared `PLAYER_HEIGHT` constant).

What was done:
1. Created `hookshot_targeting.lua` with: `getCameraDirData`, `probeSurfaceNormal`,
   `checkRappelClearance`, `checkLedgeEdge`, `getTargetType`, `findGrabbableNearAim`.
   Also moved `ITEM_DETECTION_ANGLE_THRESHOLD` and ledge detection constants
   (`DOWNWARD_LOOK_THRESHOLD`, `LEDGE_EDGE_TOLERANCE`, `LEDGE_PROBE_CLEARANCE`).
2. Module imports: `camera`, `nearby`, `self`, `util`, `hookshot_orient`, `hookshot_settings`,
   `hookshot_util`. Defines `HOOKSHOT_PHY` locally.
3. Moved `PLAYER_HEIGHT` to `hookshot_util.lua` as `U.PLAYER_HEIGHT` (shared between
   targeting and future physics module). player.lua keeps a local alias for `getBoundingData`.
4. In `player.lua`: removed 6 function definitions + constants (359 lines). Updated all
   call sites to `Targeting.*` prefix — 9 calls across `tryDrawReticle`,
   `hookToWorldObject`, and the fire-hookshot logic.
5. Removed unused util aliases (`anglesToV`, `angleBetweenVectors`) that were only used
   by the moved functions.

Awaiting in-game verification: draw hookshot, test target detection for items, actors,
floors, walls, ceilings, and rappel points (fun mode on and off).

### Phase 5: Extract `hookshot_physics.lua` — COMPLETED

Created `hookshot_physics.lua` (446 lines). `player.lua`: 1201 → 805 lines.

**What was done:**

| Item | Detail |
|------|--------|
| Physics constants | Moved 15 constants (ITEM_Z_OFFSET through GRAVITY_MS2) to physics module |
| Sequence factories | Moved `createPullSequence`, `createSelfPullSequence`, `createDropSequence` as `Physics.*` |
| Ragdoll management | Moved `createRagdollData`, `ragDollData` array, `rmFromRagDollData` → `Physics.addRagdoll`, `Physics.removeByTarget`, `Physics.addSequence` |
| Collision | Moved `tpWithCollision` (internal to physics), `getBoundingData` → `Physics.getBoundingData` |
| Update loop | `updateRagdoll` → `Physics.update(dt, isPaused)` returns completion events |
| Completion events | `removeCurrentSequence` split: bookkeeping → `completeCurrentSequence` (internal to physics), state transitions → `handleSequenceCompletion` (player.lua) |
| Event types | `ITEM_PULL_COMPLETE`, `ITEM_DROP_COMPLETE`, `SELF_PULL_COMPLETE`, `SEQUENCE_COMPLETE`, `ALL_COMPLETE` |
| Removed aliases | `addToVector3`, `clamp`, `getHP`, `isAlive`, `ArrayIter` no longer needed in player.lua |
| Removed constants | `ANY_PHY`, `PLAYER_HEIGHT`, and all physics constants removed from player.lua |

**Verify thoroughly:**
- Pull item → menu appears → Take works → item in inventory
- Pull item → menu appears → Drop works → item falls with gravity
- Pull actor → actor moves to player
- Hook to floor → player flies to surface → lands
- Hook to ceiling → player flies → enters hanging state → rappel up/down/release
- Hook to rappel point (fun mode) → same as ceiling
- Mid-flight collision → hookshot terminates cleanly
- Stuck detection → sequence ends

### Phase 6 (Optional): Reactive settings verification
**Risk: Low** — By this point settings are already reactive from Phase 1. This phase is
just about testing edge cases.

1. Change every setting while in-game and verify it takes effect.
2. Specifically test: changing reticle icon mid-aim, changing colors, changing range,
   toggling fun mode, toggling debug mode.

---

## Dependency Graph (build order)

```
hookshot_util          (no mod dependencies)
hookshot_settings      (no mod dependencies)
    │
    ├── hookshot_reticle    (depends on: settings)
    ├── hookshot_targeting  (depends on: settings, util, orient)
    └── hookshot_physics    (depends on: settings, util)
            │
            └── player.lua  (depends on: all of the above + menu + orient)
```

Phases 1 and 2 can be done in parallel. Phase 3 requires Phase 1. Phases 4 and 5 require
Phases 1 and 2. All extraction phases (1-5) are now complete.

---

## Risk Mitigation

- **Keep backups.** The `backups/` directory pattern already exists. Before each phase,
  copy the current `player.lua` into `backups/`.
- **Test after every phase.** Each phase should be a separate commit. If something breaks,
  revert just that phase.
- **Phase 5 complete.** The completion-event refactor split `removeCurrentSequence` cleanly:
  `completeCurrentSequence` (physics bookkeeping) stays internal to physics module,
  `handleSequenceCompletion` (state transitions) stays in player.lua. Five event types
  (`ITEM_PULL_COMPLETE`, `ITEM_DROP_COMPLETE`, `SELF_PULL_COMPLETE`, `SEQUENCE_COMPLETE`,
  `ALL_COMPLETE`) cover all sequence completion paths.
- **Don't change `global.lua` beyond Phase 0.** It's 118 lines, well-scoped, and has no
  structural issues. The only fix is the unused `ownerId` variable.

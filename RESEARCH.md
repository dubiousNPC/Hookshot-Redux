# OpenMW Lua — accrued research

Written for agents making changes to this mod suite. Everything here was found
by reading, instrumenting or breaking real code: Bardcraft, Sun's Dusk,
Fashionwind, OMWFW, InventoryEquipmentDisplay and CAKE. Where a rule has a
counter-example, the counter-example is named.

Two things dominate: **per-frame work** and **`pcall`**. They are related. Bad
polling wastes frames you can measure; `pcall` hides the bugs you cannot.

---

# Part 1 — Per-frame work

## 1.1 The measured cost

Fashionwind's bug report is the only hard field data in this suite, and it is
worth quoting because it sets the scale:

> 7 NPC scripts have `onUpdate` on every active NPC... One cosmetic mod having
> 7 scripts cranking out constant 1k ops/s in just Pelagiad is really bad. In
> Narsis it's 5-6k ops/s per script.

Seven near-identical scripts, each walking every active NPC's inventory every
20 frames. The fix is not "poll less often". It is **one script instead of
seven**, and then **no polling at all**.

## 1.2 `onFrame` vs `onUpdate` — not interchangeable

| | runs while paused | use it for |
|---|---|---|
| `onFrame` | **yes** | work that must continue during a menu, and nothing else |
| `onUpdate` | no | all gameplay work |

Almost everything in a cosmetic or animation mod wants `onUpdate`. You cannot
change perspective from a menu, so a camera-mode check in `onFrame` is running
during menus purely to observe that nothing happened.

Bardcraft polled `camera.getMode()` in `onFrame`, unconditionally, for the
whole session:

```lua
onFrame = function(dt)
    local camMode = camera.getMode()
    if camMode ~= lastCameraMode then ... end
```

At 144 fps that is ~144 calls a second, forever, to catch an event that happens
a handful of times an hour — and it ran whether or not anything was attached.

## 1.3 The escalation ladder

Take the highest rung that works. Do not start at the bottom.

1. **Engine event.** `onActive`, `onInactive`, `UiModeChanged`, `onSave`/`onLoad`,
   `I.ItemUsage` handlers. Zero cost when nothing happens.
2. **Trigger handler.** `input.registerTriggerHandler("TogglePOV", ...)`.
   Instant, and not reached unless the key is pressed. Register defensively —
   trigger keys come from built-in scripts and a stripped setup may lack them:
   ```lua
   if input.triggers and input.triggers.TogglePOV then
   ```
3. **Storage subscription.** `settings:subscribe(async:callback(fn))`. Fires on
   change only.
4. **Interface subscription.** Publish an interface others subscribe to, and
   **hold the subscription only while it is needed** (§1.5).
5. **One-shot timer.** `async:newUnsavableSimulationTimer(delay, fn)` for a
   deferred settle. `time.runRepeatedly` for genuine periodic work.
6. **Throttled `onUpdate` with a cheap change signature** (§1.6).
7. **`onFrame`.** Only for work that must survive a pause.

## 1.4 Event-first, poll-as-backstop

Some state changes arrive without an event. Camera mode is the canonical case:
`TogglePOV` covers deliberate presses, but vanity mode after idle, preview mode
while a key is held, and another mod calling `setMode` do not fire it.

`AnimRefresh` is the pattern: trigger handler for the case the player notices,
plus a **1 s** poll as a backstop for the cases they did not ask for. One second
of latency is acceptable precisely because those changes were not requested.

Never let the backstop become the mechanism. If the poll is doing all the work,
the event hookup is broken.

## 1.5 Subscribe only while active

The single highest-leverage rule. A mod that costs nothing when idle is a mod
nobody profiles.

```lua
local function syncSubscription(want)
    if want == subscribed then return end
    if not (I.AnimRefresh and I.AnimRefresh.subscribe) then return end
    if want then I.AnimRefresh.subscribe('MyMod', cb)
    else I.AnimRefresh.unsubscribe('MyMod') end
    subscribed = want
end
```

With no subscribers `AnimRefresh`'s `onUpdate` does one table-empty check and
returns, and its trigger handler is never reached. A player wearing nothing pays
essentially zero.

Call `sync` from every place the underlying state can change — in CAKE that is
`onActive`, the equip event, and `UiModeChanged`. A subscription that is never
released is just a poll with extra steps.

## 1.6 The change-signature pattern

When you genuinely must poll, make the "nothing changed" path free. From IED:

```lua
-- Deliberately avoids record() lookups: recordId and count are already on the
-- object, so the common path never touches the record store or the filesystem.
local function buildSignature(actor, equippedWeaponId, equippedShieldId, isDrawn)
```

Compare the string; rebuild only on difference. Two rules:

- **Never do a record lookup, VFS lookup or mesh resolution inside the
  signature.** That is the path taken every tick.
- **`getAll` ordering is not documented as stable.** If it ever varies, the
  signature differs and you do one redundant rebuild. Harmless — but do not
  build correctness on the order.

Fold settings into the signature rather than giving every context its own
subscription:

```lua
local signature = buildSignature(...) .. '|' .. tostring(cfg:get('showWeapons'))
```

## 1.7 Detecting rest, wait and travel

Bardcraft's trick, and the one most likely to be missed:

```lua
local currentTime = core.getGameTime()
if lastUpdate and currentTime - lastUpdate > 1 then
    self:setSheatheVfx()   -- rest / wait / fast travel all land here
end
```

Rest, wait and fast travel all appear as a discontinuity in game time. One test
covers all three without knowing which UI mode caused it. `UiModeChanged` on
`Rest`/`Travel`/`Training` covers the menus that rebuild the model **without**
advancing time. **Use both** — neither is a superset.

## 1.8 Deferred refresh after a model rebuild

Attaching to a skeleton that is about to be replaced attaches nothing. Both
prior mods defer, and Sun's Dusk's version is the better one:

| | defer | guard | retry |
|---|---|---|---|
| Bardcraft | 1 frame | none | no |
| Sun's Dusk | 0.1 s timer | `animation.hasBone` | once |

One frame is not always enough. Use the timer, guard with `hasBone`, retry
once, and **do not retry forever** — a missing bone is usually a missing
skeleton, not a race.

## 1.9 NPC scripts

- **One script for all categories.** Adding a slot must not add a script.
- **One inventory walk covering everything**, not one per category.
- `onActive` is normally sufficient. An NPC's inventory does not change while
  you are looking at it.
- If you must poll, `time.runRepeatedly` at ≥1 s, never a frame counter.
- **NPC local scripts cannot read a player settings section.** Route through a
  global section:
  `MENU declares → PLAYER subscribes and pushes → GLOBAL writes globalSection → NPC reads`.
  Absent config must read as *enabled*: an NPC can activate before the section
  is seeded, and defaulting to off looks like a broken mod.

## 1.10 Cheap wins, verified

- `item.recordId` — not a `getRecordId()` helper doing record lookups.
- `inv:find(id)` / `inv:countOf(id)` — engine-side, not a Lua `getAll` loop.
- `types.Actor.inventory(self)` — the handle is stable and self-updating; hoist
  it to script init rather than re-resolving.
- Memoize record and mesh lookups keyed by `recordId`. Cache the **miss** too
  (store `false`, distinguish from `nil`) or you re-derive it every pass.
- Cache a `hasBone` probe per animation-object lifetime, but invalidate it on
  anything that could rebuild the skeleton — and on a deliberate equip, which
  costs one probe on a keypress and stops a stale hit attaching to a bone that
  is no longer there.

---

# Part 2 — `pcall`

## 2.1 The rule

> **`pcall` is banned unless you are calling code you do not control, or
> failure is a supported state you have documented.**

Everywhere else it converts a diagnosable crash into an undiagnosable silence.
On a mod whose entire output is "a mesh appears", silence is indistinguishable
from working.

Audited across this suite: **21 `pcall`s found, 18 removed, 3 kept.**

## 2.2 The two bugs it actually hid

Not hypothetical. Both cost real time.

**CAKE — a whole session.** `cake_shared.lua` baked the plugin's raw `MODL`
string into the registry and handed it to `addVfx`:

```
plugin MODL     RV\Ashmask1.nif        <- raw, relative to meshes/
record.model    meshes/rv/ashmask1.nif <- VFS path, what the API wants
```

Different strings. `addVfx` got a path that does not exist. `pcall` swallowed
it. The item was consumed, the `_eq` record created, state set correctly — and
nothing appeared. The report was "the item does nothing when selected."

**IED — silently believed nothing was ever equipped.** The original called
`types.Actor.equipment`, a function that does not exist. The `pcall` around it
returned `false`, the code treated that as "no equipment", and the mod worked
just wrongly enough not to look broken.

Note the shape both share: **the pcall did not protect against a failure, it
manufactured a plausible-looking wrong answer.**

## 2.3 What justifies one

**Third-party callbacks.** You do not control subscriber code, and one
subscriber throwing must not stop delivery to the others:

```lua
for key, callback in pairs(subscribers) do
    local ok, err = pcall(callback, mode, previous)
    if not ok then
        print("[AnimRefresh] callback error in '" .. tostring(key) .. "': " .. tostring(err))
    end
end
```

Note it **prints the key**. A pcall that discards the error is not isolation,
it is concealment.

**An optional module.** `require` has no non-throwing form, and if the file is
documented as deletable then absence is a supported state:

```lua
local ok, mod = pcall(require, 'scripts.cake.cake_anim')
if not ok then print('[CAKE] cake_anim.lua not loadable; gestures disabled') end
```

That is the entire list.

## 2.4 What does not justify one

Every one of these was removed:

| Call | Why the pcall was wrong |
|---|---|
| `anim.addVfx` | Path and bone are validated immediately above. A failure means one of those checks is wrong. |
| `anim.removeVfx` | Removing an id that was never added is a no-op. |
| `anim.hasBone` | Documented for any actor; cannot throw on a valid one. |
| `anim.playBlended` / `anim.cancel` | Playing or cancelling a group the skeleton lacks is a no-op. |
| `inv:countOf` | Documented method on an inventory you just obtained. |
| `obj:getBoundingBox` | Documented `GameObject` method on an object you just enumerated. |
| `types.Weapon.record` / `types.Armor.record` | The caller already established the type via `getAll(types.X)` or `objectIsInstance`. |
| `types.Actor.getEquipment` / `getStance` | Documented, on a valid actor. |
| `storage.playerSection` | Available in its context and creates on demand. |

The recurring tell: **you are pcall-ing a documented API on an object you have
already validated.** If that can throw, your validation is the bug.

## 2.5 When you want a guard, not a pcall

A missing asset is a legitimate thing to handle — but *report* it:

```lua
elseif vfs.fileExists(path) then
    result = path
else
    print("[IED] mesh not in VFS, skipping: " .. tostring(path))
end
```

Checking and logging is not the same as swallowing. The distinction is whether
someone reading the log can tell what happened.

---

# Part 3 — Bug catalogue

Every one of these was found in shipped code in this suite.

## 3.1 Paths and assets

| Bug | Detail |
|---|---|
| **Raw `MODL` vs VFS path** | Plugin `MODL` is relative to `meshes/` with original case and backslashes. `record.model` is a VFS path. Resolve from the record **at runtime**; never bake the plugin string into Lua. |
| **Sharing one mesh between world object and VFX** | Bardcraft states it outright: a mesh attached as VFX stops being interactable until restart. Sun's Dusk avoids it by convention — `_g` ground mesh on the base record, worn mesh on `_eq`. Treat "worn model ≠ ground model" as a requirement. |
| **Unchecked base mesh path** | Existence-checking only a `_sh`/`_eq` variant and returning the base path unchecked is one `pcall` away from silent failure. |
| **Preserving plugin fidelity in the wrong place** | Reproducing paths verbatim is right for the *plugin* and wrong for the *Lua registry*. Assert against the engine's expectations, not the plugin's. |

## 3.2 Animation API

| Bug | Detail |
|---|---|
| **`BONE_GROUP` ≠ `BLEND_MASK`** | `BONE_GROUP` is a sequential index (LowerBody 1, Torso 2, LeftArm 3, RightArm 4). `BLEND_MASK` is a bitmask (1, 2, 4, 8). Summing `BONE_GROUP` yields a valid but meaningless mask — Torso+LeftArm+RightArm = 9 = LowerBody+RightArm. `BLEND_MASK.UpperBody` (14) already means torso plus both arms. |
| **`PRIORITY.Scripted`** | Pauses every non-Scripted animation globally. Wrong for a short gesture — it freezes the walk cycle. Use `PRIORITY.Weapon` on an upper-body mask. |
| **Missing bone is silent** | Attaching to a bone that does not exist is a no-show, not an error. Always `hasBone` first, and always declare a vanilla fallback. |
| **`animation.cancel`** | Lives on `openmw.animation` and takes the actor. It is not on `I.AnimationController`. |
| **`types.Actor.equipment`** | Does not exist. It is `getEquipment`. |
| **KF text keys** | A group keyed `loop start`/`loop stop` will not answer to `start`/`stop`. Read the keys out of the binary; the resulting stuck or absent pose reads as a scripting bug when it is a naming one. |
| **`vfxId` and magic effects** | The engine uses `vfxId` to add and remove magic effects. The docs warn explicitly against ids that collide with `core.MagicEffectId` values. Namespace yours (`saw_w_<recordId>`, `cake_<category>`). |

## 3.3 Bones and slot arbitration

| Bug | Detail |
|---|---|
| **Occupancy keyed by type, not bone** | IED mapped `AxeOneHand` and `LongBladeOneHand` to one bone, and `Arrow`/`Bolt` to another, but deduplicated by weapon *type*. An equipped sheathed longsword plus a carried axe stacked two meshes on one bone. Key by **resolved bone name**, and compute the shared set from the map rather than restating it. |
| **The engine occupies the same bones** | OpenMW's native weapon sheathing puts the equipped-and-undrawn weapon and shield on the same bones a display mod uses. Claim the bone only while `not isDrawn`; drawn, it is free again. |
| **Excluding by record id, not occupancy** | Skipping "the equipped shield" by `recordId` still lets a *second, different* shield onto the bone the engine already filled. |
| **Arbitration that never arbitrates** | OMWFW's five head categories each wrote their "bone owner" lock to a *different* storage section, so every `xIsOurs()` was unconditionally true. Distinct `vfxId`s mean shared-bone categories do not evict each other anyway — declare explicit `conflicts` both ways and assert symmetry. |

## 3.4 State

| Bug | Detail |
|---|---|
| **Inferring worn state from inventory presence** | If "the `_eq` record is in your bag" *is* the test, then **looting one equals wearing it**. Keep explicit state set by activation; the inventory audits it, it does not define it. |
| **String surgery for id derivation** | `id:sub(1, -4)` and `id .. "_eq"` are right only if the id already carries the expected prefix. Use an explicit reverse index so a naming change fails loudly at generation time, not silently at runtime. |
| **Record ids are lowercase** | Comparisons against `item.recordId` must be lowercased. Half of one table's keys were capitalised and could never match. |
| **A refresh trigger that does not refresh** | Bardcraft's `UiModeChanged` called `verifySheathedInstrument()`, which returns a boolean and has no side effect. The documented refresh never happened. |

## 3.5 Plugin data

| Bug | Detail |
|---|---|
| **`_eq` applied to `FNAM` instead of `NAME`** | 320 records with 160 unique ids: two identical blocks differing only in display name. The second silently overwrote the first (TES3 is last-wins), leaving zero `_eq` records and every item named "…_eq". |
| **Ids from a different content set** | 50 ids in a script, **none** of which existed in any shipped plugin. Always cross-check the registry against the plugin binary. |
| **Undeclared masters** | Meshes from OAAB, Project Cyrodiil and others resolve fine for you and not for users. Declare the masters — do **not** "fix" it by editing or dropping the records; those paths are correct. |
| **Bodypart / item id collisions** | Reusing bodypart ids (`_RV_Ashmask1_H`) for wearable items works at the engine level but conflates the two everywhere else. A prefix resolves it. |

## 3.6 Structure

- **Dead settings are worse than no settings** — they imply a feature exists.
  Cross-reference declared against read.
- **An empty category is a load failure waiting to happen** if anything
  validates its keys against it. Prune empties at generation time.
- **Registration must be idempotent.** `onInit` and `onLoad` both call it and
  only one runs on a given start.
- **Bundle shared libraries, do not copy them in.** Version-guard the file
  itself (`if I.X and I.X.version >= MY_VERSION then return end`) so only the
  newest loaded copy runs. `AnimRefresh`, `SharedRay`, `SuperSettingsRenderers`.

---

# Part 4 — Verification

Tooling in `tools/`. No Lua interpreter is installed; `luacheck.py` and
`luarun.py` drive the system `liblua5.4.so.0` through ctypes.

| Tool | Catches |
|---|---|
| `luacheck.py` | Syntax. |
| `check_names.py` | Undefined names, unused requires. |
| `api_sweep.py` | Every `module.member` call vs the Cod3x stubs. **Run this** — a misspelled API inside a pcall-wrapped call is §2.2 again. |
| `sweep.py` | Settings declared vs read, categories used vs defined, events sent vs handled, l10n keys, orphaned modules. |
| `test_*.lua` | Mocked-API behaviour tests. |

## 4.1 A mock that accepts everything tests nothing

The single most important testing lesson here. CAKE's integration test passed
through the entire path-bug session because its mock returned `m/<id>.nif` for
`record.model` and its `addVfx` accepted any string.

Mocks must **assert the contract the engine enforces**:

```lua
addVfx = function(_, path, o)
    assert(path:sub(1,7)=='meshes/' and not path:find('\\',1,true),
           'addVfx got a non-VFS path: '..path)
    assert(world.files[path], 'addVfx got a path not in the VFS: '..path)
    if world.vfx[o.boneName] then world.doubled = (world.doubled or 0) + 1 end
    ...
```

That last line is the other half: a counter that trips whenever two meshes land
on one bone turns §3.3 into a test rather than a code review.

## 4.2 Assert the invariant that matters

Four assertions were once added guarding "the registry matches the plugin". It
did. The thing that had to match was **the engine**. Before writing an
assertion, ask which side actually enforces the constraint.

## 4.3 Generate, do not hand-maintain

Registries derived from plugin data should be generated by a script that
**asserts its own invariants** — every category bone exists in the skeleton,
every item resolves to a category, ids are lowercase, conflicts are symmetric.
A typo then fails at generation rather than silently in game.

---

# Part 5 — Checklist before changing anything here

1. Does this add an `onFrame` or `onUpdate` handler? Justify it against §1.3.
2. Does it poll anything a subscription or engine event would give you?
3. If it subscribes, is the subscription released when idle?
4. Are you adding a `pcall`? It needs to be third-party code or a documented
   optional. Otherwise remove it and let the error surface.
5. Are you passing a mesh path? Resolve it from the record at runtime.
6. Are you attaching to a bone? `hasBone` first, vanilla fallback declared.
7. Are you tracking occupancy? Key it by bone, not by type — and check whether
   the engine already owns that bone.
8. Are you inferring state from inventory presence? Don't.
9. Run `luacheck.py`, `check_names.py`, `api_sweep.py`, `sweep.py` and the
   tests. All five, not the first one.
10. If you added behaviour, does the mock actually enforce the engine's
    contract, or would it accept a wrong answer?

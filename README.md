# OpenMW Hookshot
A mod for OpenMW that allows you to pull items and actors to you, or yourself to world objects, like a hookshot from The Legend of Zelda.

### Main Features
1. Pull actors to you by firing the hookshot at them
2. Pull items to you - they'll drop naturally at your feet with gravity
3. Pull yourself to distant objects or terrain by firing the hookshot at something stationary
4. Rappel up or down from hookshot anchor points
5. Works underwater - grapple to surfaces while swimming
6. Smart surface detection filters out surfaces you wouldn't want to grapple to (heightmap terrain, continuous rooftops, etc.)
7. A depth-aware BeamFX filament rope extends with the hook, reels in during pulls, and remains attached while rappelling

### Requirements
Core hookshot gameplay requires OpenMW 0.49+. The rope visual requires OpenMW 0.51+, BeamFX API 1.2 or newer, and Lua postprocessing.

Install the Hookshot and BeamFX directories as separate OpenMW data roots, then enable these content files:

```ini
content=beamfx.omwscripts
content=Hookshot.omwaddon
content=OpenMWHookshot.omwscripts
```

Enable postprocessing and restart OpenMW. BeamFX dynamically manages its own shaders; do not add BeamFX shaders manually to the F2 postprocessing chain. BeamFX is fail-soft: if it is missing or temporarily unavailable, Hookshot gameplay continues without the rope visual.

### State of Mod
Main functionality is complete - you can grab actors and items in the reticle and pull them to you,
or hook on to objects to fly to them. The mod includes intelligent surface classification to determine
valid grapple points and rappel-eligible surfaces. A fired hook now travels to the selected target before
the pull begins; Hook Travel Speed is configurable in Basic Settings.

### Default keymappings
- Draw/sheathe Hookshot reticle: z
- Fire while drawn: the base-game Attack/Use action
- Cancel Hookshot aiming mode: x
- Rappel up: w, Rappel down: s, Release Rappel: space
- All keybindings are rebindable in the OpenMW Lua Scripts settings menu

### Known issues:
- Self-pulling can sometimes be visually jittery in open areas. Lower Pull Speed in the options.

### Design notes
Reasoning that used to live in code comments.

**Hook travel and rope**
- The rope launch point is `U.actorShoulderOrigin` (0.81 of standing height, offset right and forward). Hook flight time is measured from it, so it never comes from the optional visual mod; the beam consumer uses the same helper so the drawn rope starts where the gameplay says.
- The rope exists only while FIRING or HANGING. `setMode()` is the single choke point for state changes, so every exit path retracts it, and playerAnim sees every transition.
- The global renderer keeps one retained path per player under a 0.5s persistent lease. `replacePathPoints` renews the lease, so a stalled or reloaded script still can't leave a rope in the world; the player side sends on movement or every 0.15s, well inside the lease.
- The rope is created once with `upsertPath` and moved with `replacePathPoints` (BeamFX API 1.9), not re-`upsert`ed. `upsert` restarts the beam's longitudinal animation clock on every call, which pins any `travel`, `pulse` or `dash` pattern at phase zero; point replacement preserves `animationStartedAt`. It is also far cheaper: one points array instead of a full spec plus appearance expansion and revalidation, 60 times a second.
- `ROPE_POINTS` fixes the path topology, because `replacePathPoints` requires the same point count every call. At 2 it is a straight line; above 2 the extra points are interpolated and a Verlet chain can replace that generator for sag. Each link is one visual record out of BeamFX's 64/128, so a long rope is not free.
- A provider without the path methods falls back to the original transient single-segment `upsert`.

**Pulls and handoff**
- The handoff releases 90 units short and ends within 10 units of the aim point. The player arrives with no engine velocity, so the gap is covered at run speed, not pull speed: 55/24 gave a window of about 0.12s, which is too short for the `hookoff` pose to blend in at all.
- Non-rappel grapples aim above the landing point and release short of it. OpenMW has no Lua velocity setter, so a teleported arrival has zero momentum and has to be stopped by the collision cage exactly where it's most likely to push through the surface. The last stretch is a jump plus normal air steering instead, which other movement mods can see.
- Pulls ease out over the last 250 units, floored at 300 u/s so a slow pull never reads as stuck (stuck = under ~100 u/s). The arrival radius always covers one frame of travel, so a fast pull or a low frame rate can't step over the target.
- Self-pulls skip the collision cage for their first frames: the player starts against the wall they hooked, and the cage would clamp the move to nothing.
- `Physics.addSequence` refuses an untracked ragdoll. A queued sequence promises a completion event, and an orphaned ragdoll (removed while the item menu was open) would never send one, leaving the FIRING pose looping.

**Animation**
- **Full body only while the hookshot moves the player.** The engine takes walking speed from the leg animation, so a pose on LowerBody stops the player walking: with the old full-body tethered pose, holding W moved the player 0 units in 1.5 s against 189 for a plain walk (OpenMW 0.52). Full body is for the self-pull, the hand-off, the swing and the hang. Aiming, the shot on its way out, item and actor pulls, the planted dart and the launch are upper body, and the legs stay under locomotion. A shot turns full body as its self-pull starts (`Anim.onPullStarted`); `playPose` treats a change of mask as a new pose so the same clip can replay.
- `hookoff` is authored for the whole body (pelvis 43 degrees, thighs 34 degrees, arms up to 117). Played upper body only, the legs showed the engine's jump pose and the hand-off read as no animation at all. It now plays full body; the hand-off is airborne, and the landing point is unchanged (96-114 units from the wall either way).
- Clip lengths are fixed in the `.kf`, so `playerAnim.SPEED` fits each one to how long its state actually lasts. The hang loops are the short ones — `hookhang` is 0.167s, a 6Hz twitch at speed 1 — and `hookoff` is the long one, a 1.0s clip over a window a third that length. Blend durations in the `Animations/*/*.yaml` files are derived from clip length divided by speed, so changing a speed means re-deriving its rule.
- `Anim.verifyGroups()` prints each group's presence and text keys on first update when Debug Mode is on. A missing group or a group keyed `loop start` instead of `start` is silent in the engine, and the three clips that looked broken were neither.

**Dart, tether and swing**
- There is no Lua call to launch a projectile -- `I.Projectiles` only reports hits on projectiles the engine made -- so `dbs_hookshot_dart` is an ordinary object the global script creates, teleports along the rope tip and removes. The global script keys its darts by the owner's `id`: each event hands it a new userdata for the player, and a table keyed by the object never found the dart on the end event, so every hang left one in the world. The aim cone then preferred that dart as an item target, and the next shot pulled it instead of hooking. `saveState` is cleared so it never enters a save. It is published before the beam interface is consulted, because the dart is a real object and must not depend on the optional rope visual being installed.
- Delayed firing plants the dart and holds the rope instead of pulling. It applies to world geometry only; a dart planted in a moving actor is a different feature.
- The tether length ratchets: the closest approach becomes the new length, floored at `TETHER_MIN_LENGTH` so the rope can never lock you in place. The break point rides the ratcheted length, so closing in and backing out snaps sooner than the original throw would have.
- Leaving the ground on a rappel-eligible tether starts a pendulum in the vertical plane through the anchor. There is no velocity getter, so the initial angular velocity is differenced from the previous tethered position, which is what carries a run-off-a-ledge into the arc instead of starting it from rest.
- The swing is position-driven, so player input is zeroed while it runs. Release arms on the pass through the low point -- and only with enough angular speed to be worth launching -- then fires `SWING_RELEASE_PAST` radians later. Release hands a velocity to `Physics.createLaunchSequence`, a DROP with a non-zero start, so the arc out reuses the same gravity integrator and collision cage as every other movement in the mod.
- The swing's step probe is a single centre-line ray, not the six-point cage the pulls use. A centre ray can pass where the body would not fit, so swinging flush along a wall is the case to watch; contact releases the swing, which is the safe failure.

**Equipment gates**
- Four whitelists -- Grapple, Item, Npc, Special -- each a `textSet_V1` set of record ids. An empty list inherits the base glove gate, so an upgrade changes nothing until a list is populated. A populated list is the gate on its own, so an id from another mod works without being added to `GLOVE_RECORD_IDS`; drawing is allowed whenever any one mode is. Anything in Special unlocks every mode.
- The gate sets are read live on draw and fire rather than cached. They are read a few times per keypress, and they are the settings most likely to be edited while the game is running.
- A locked mode reads as `"none"` from `getTargetType`, so the reticle greys out and the aim-cone scan skips that object class entirely. The reticle never offers a pull that `fireHookshot` will refuse.

**Hooked actors**
- An actor being dragged in plays `hsfalling` from `actorAnim.lua`, an NPC/CREATURE script with an event handler and no per-frame work. The group name is `hsfalling`; the file is `xhsfalling1.kf`, and the group comes from the text key, not the filename.
- The pose is started by event and stopped by the actor's own timer, so a dead or reloaded player script cannot leave an NPC stuck in it. A generation counter means a re-hook extends rather than double-stops.
- `animation.hasGroup` is checked first. Creatures have their own skeletons and will not have the clip, and naming a group the skeleton lacks suppresses the actor's own animation and supplies nothing.

**Settings**
- Per-frame accessors read from a `settingsCache` mirror (Bor's Drop-in Utils) rather than calling into storage. The reticle alone reads six or seven of them every frame.

**Targeting**
- Surface type comes from a dedicated short physics ray, not SharedRay's hit normal, which is unreliable.
- Heightmap terrain is never a rappel floor. Ledge edges are told apart from rooftops by probing back toward the player: same height and flat means a continuous surface.
- A ledge's clearance is measured past its edge, where the player hangs. It used to be measured straight down from 20 units under the top, which is inside the platform, so the ray met the platform's own underside and any platform thicker than 20 units read as no clearance (22 for a 54-unit slab, 100 for a 155-unit one).
- The aim cone catches thin items and actors the rendering ray misses. Its type test runs last, behind the distance and angle culls: those are a few arithmetic ops, while `objectIsInstance` is an engine call, and the cone is walked over every nearby item and actor on every throttled tick.

**Hanging**
- A hang goes under the rope: feet 195 below the anchor, in the clear column nearest straight under it (`Targeting.resolveHangPosition`). The search steps out from the anchor -- along a wall's normal, away from a sloped ceiling, past a ledge's edge toward the player -- and takes the first column where the player's height and the rope line to the hook are clear. The old offset followed the surface normal, which put a wall hang 30 out and only 20 below the hook (head above it, rope sticking out sideways), a sloped-ceiling hang diagonally off, and a ledge hang inside the platform.
- A wall's face is found with horizontal rays at body and head height, because the anchor comes from the rendering ray and can sit 10-12 units inside the collision face. Rope-ray hits within 32 units of the anchor are that surface, not an obstruction.
- A pull that stops short of the hang point (it may arrive up to 100 units off, along its diagonal approach) settles the rest of the way horizontally at 400 u/s, like a rope coming to rest. A body-high probe stops the settle at anything in the way.
- The climb clamps the head, not the feet, against the anchor; the old feet limit let the upper body into the surface the hook was in.
- Combat is suppressed from DRAWN until IDLE because firing shares the Attack key.

**Save and load**
- The hook is not saved. `onSave` stores only the overrides, levitation and crosshair state this mod owns, so `onLoad` can undo them without touching another mod's. The animation reset waits for the first update, since the animation object may not exist during load.

### Parkourwind FLOW
While the hookshot carries, swings, launches, lands or hangs the player, it
stands FLOW down through `I.Flow.yield`. `syncFlowYield` in `player.lua` runs
from `setMode`, from the self-pull phase change and once per frame. Without
it, FLOW read the hold as a jump: the Jump that drops a hang chained into a
FLOW ledge grab, and a long pull could play FLOW's Skydive and land as a
knockdown over the landing pose. The yield is issued *before* the hookshot
writes the movement override, because the flag is shared and FLOW releases its
own hold as it stands down. FLOW stays active while merely **tethered**: the
player walks free there. Without FLOW installed nothing changes.

### Take a Seat
While Take a Seat (v0.44+) holds the player, meaning seated, lying, or still
getting up (`I.TakeASeat.isBusy()`), the hookshot is neither drawn nor fired:
"Get up first". Otherwise it would pull or launch a seated body out of its
pose with collision off. Without Take a Seat installed nothing changes.

### Credits:
imarchnemesis: Original Hookshot mod.
S3ctor: Reticle assets and T4rg3t5 logic.
Hrnchamd: Surface orientation math.
MisterSmellies: Rappel/hanging inspiration.
Lightningrodbombom: Real Telekinesis concept.
Slowchu, BeamFX contributors: Shared depth-aware filament renderer and consumer adapter template.
SahJop: original construction and design.
DubiousNPC: Animations

### Extension
This mod is freely available for further modification or extension.

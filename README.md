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
- Clip lengths are fixed in the `.kf`, so `playerAnim.SPEED` fits each one to how long its state actually lasts. The hang loops are the short ones — `hookhang` is 0.167s, a 6Hz twitch at speed 1 — and `hookoff` is the long one, a 1.0s clip over a window a third that length. Blend durations in the `Animations/*/*.yaml` files are derived from clip length divided by speed, so changing a speed means re-deriving its rule.
- `Anim.verifyGroups()` prints each group's presence and text keys on first update when Debug Mode is on. A missing group or a group keyed `loop start` instead of `start` is silent in the engine, and the three clips that looked broken were neither.

**Targeting**
- Surface type comes from a dedicated short physics ray, not SharedRay's hit normal, which is unreliable.
- Heightmap terrain is never a rappel floor. Ledge edges are told apart from rooftops by probing back toward the player: same height and flat means a continuous surface.
- The aim cone catches thin items and actors the rendering ray misses. Its type test runs last, behind the distance and angle culls: those are a few arithmetic ops, while `objectIsInstance` is an engine call, and the cone is walked over every nearby item and actor on every throttled tick.

**Hanging**
- The climb clamps the head, not the feet, against the anchor; the old feet limit let the upper body into the surface the hook was in.
- Combat is suppressed from DRAWN until IDLE because firing shares the Attack key.

**Save and load**
- The hook is not saved. `onSave` stores only the overrides, levitation and crosshair state this mod owns, so `onLoad` can undo them without touching another mod's. The animation reset waits for the first update, since the animation object may not exist during load.

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

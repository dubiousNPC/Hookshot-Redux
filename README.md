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

### Credits:
imarchnemesis: Original Hookshot mod.
S3ctor: Reticle assets and T4rg3t5 logic.
Hrnchamd: Surface orientation math.
MisterSmellies: Rappel/hanging inspiration.
Lightningrodbombom: Real Telekinesis concept.
BeamFX contributors: Shared depth-aware filament renderer and consumer adapter template.

### Extension
This mod is freely available for further modification or extension.

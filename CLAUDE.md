# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenMW Hookshot Enhanced is a Lua mod for OpenMW 0.49+ (rope visual 0.51+) (open-source Morrowind engine). It adds a Zelda-style hookshot that can pull items/actors toward the player, grapple to world surfaces, and rappel from anchor points.

## Development Workflow

There is no build system. This is a pure Lua mod loaded by OpenMW at runtime.

- **Install:** Add the mod folder to OpenMW's data directories in `openmw.cfg`
- **Reload during development:** Run `reloadlua` in the OpenMW in-game console (F2) to hot-reload scripts
- **No unit test framework** — all testing is manual in-game

## Architecture

### Entry Point

`OpenMWHookshot.omwscripts` registers five scripts:
- `PLAYER: scripts/OpenMWHookshot/player.lua` — core mod logic
- `PLAYER: scripts/SharedRay/SharedRay_v2.lua` — shared camera ray (vendored)
- `PLAYER: scripts/OpenMWHookshot/example_beam_consumer/player.lua` — rope interface
- `GLOBAL: scripts/OpenMWHookshot/global.lua` — teleports and inventory moves
- `GLOBAL: scripts/OpenMWHookshot/example_beam_consumer/global.lua` — rope renderer

### Module Responsibilities

**player.lua** — State machine (`IDLE → DRAWN → FIRING → HANDOFF/LANDING/HANGING → IDLE`, plus `ITEM_MENU`), hook travel and rope, hanging/rappel, input handlers, save/load cleanup.

**hookshot_physics.lua** — Ragdoll sequences, collision-aware teleport, physics tick. Returns completion events to player.lua.

**hookshot_targeting.lua** — Surface probes, rappel clearance, ledge edge detection, target classification, aim-cone fallback.

**hookshot_settings.lua** — Settings registration, live accessors, equipment gates, input registration.

**hookshot_reticle.lua** — Crosshair UI. **hookshot_util.lua** — math, type checks, rope shoulder origin. **playerAnim.lua** — all animation calls.

**global.lua** — Handles operations requiring global script authority:
- `ragdollTeleport` event: moves objects via `teleport()` (only global scripts can teleport arbitrary objects)
- `HookshotInventoryAction` event: moves items to inventory with theft detection via `I.Crimes.commitCrime()`

**hookshot_orient.lua** — Pure math module for surface classification:
- Classifies surfaces by normal Z component (floor > 0.5, ceiling < -0.5, else wall)
- Calculates safe landing offsets per surface type
- Determines rappel eligibility

**hookshot_menu.lua** — Modal UI for item interaction after pulling:
- Take/Steal (context-sensitive based on ownership) and Drop buttons
- Uses OpenMW UI layer system with `I.UI.setMode()` for cursor/pause

### Player ↔ Global Communication

Player scripts send events to global script for privileged operations:
- `core.sendGlobalEvent('ragdollTeleport', { object, newPos, rotation })`
- `core.sendGlobalEvent('HookshotInventoryAction', { object, actor, action })`

### Key Constants

- `M_TO_UNITS = 400` — conversion factor from meters to Morrowind units
- `GRAVITY_MS2 = 9.80665 * 400` — gravity in game units
- `PLAYER_HEIGHT = 128` — standard player height in game units
- `RAYCAST_THROTTLE = 3` — raycasts every N frames for performance
- `HOOKSHOT_PHY` — collision mask excluding water (World + Door + HeightMap + Actor)

## OpenMW Lua API Patterns

- Modules loaded by a player script share its API context — any `require`d module can
  import `openmw.self`, `openmw.nearby`, etc. directly (no dependency injection needed).
  `hookshot_menu.lua` already does this.
- `nearby.castRay()` for target detection (player/local script context only)
- `types.X.objectIsInstance(obj)` for type checking items/actors
- `camera` module for aim direction and crosshair visibility
- `input.registerTrigger/registerAction` for keybindings
- `interfaces.Settings.registerPage/registerGroup` for settings UI
- `ambient.playSoundFile()` for audio feedback
- `vfs.pathsWithPrefix()` for scanning available textures at load time
- Global scripts use `object:teleport()` and `item:moveInto()` for world mutation

## Refactoring

`REFACTORING.md` records the completed split of `player.lua` into modules. Design reasoning is in the README's Design notes.

## File Layout

```
OpenMWHookshot.omwscripts        # Script manifest
scripts/OpenMWHookshot/
  player.lua                     # Main mod logic (player-local)
  global.lua                     # Privileged operations (global)
  hookshot_*.lua                 # physics, targeting, settings, reticle, util, orient, menu
  playerAnim.lua                 # Animation controller
  example_beam_consumer/         # Rope visuals (beamfx_adapter.lua is vendored)
scripts/SharedRay/SharedRay_v2.lua  # Vendored
Sound/                           # Audio assets (.mp3)
Textures/                        # Reticle textures (.dds)
```

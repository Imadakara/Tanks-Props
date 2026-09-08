# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Tank Prop Hunt — a team tactical shooter with prop-hunt elements (disguise mechanic), Godot 4.7
(GDScript), 3D, Jolt physics. Local prototype vs bots, no networking yet — the three maps are built
as reusable game-mode templates (see "Map inventory") with a future networked PvP mode in mind, so
architecture favors universal/data-driven mechanisms over map-specific code wherever the two don't
conflict.

Full design docs live outside this repo, in `C:\Users\PC\Documents\Personal Vault\Tank Props Docs\`.
Code comments frequently say "see vault" — that's this folder, not anything inside the repo. Read
the relevant doc before doing non-trivial work on a system it covers. The reference docs below
describe how each system works **now**, not how it got there — deep history is in `git log` and in
the retired `Tank_Prop_Hunt_MVP_Dev_Plan.md` / `Tank_Prop_Hunt_TZ_MVP_Godot.md` (both superseded by
`Tank_Prop_Hunt_Development_Plan.md`).

- `Tank_Prop_Hunt_Gameplay_Concept.md` — **the design doc**: vision, pillars, core loop, feature
  list, the horizontal progression model (specializations / modules / build / mastery), target
  F2P meta shape. "What the game is", not implementation.
- `Tank_Prop_Hunt_Disguise_Progression_Model.md` — source doc for the progression model
  (sidegrade-not-upgrade; account → specializations → modules → build → mastery).
- `Tank_Prop_Hunt_Development_Plan.md` — **the roadmap** (supersedes the now-deprecated
  `Tank_Prop_Hunt_TZ_MVP_Godot.md` + `Tank_Prop_Hunt_MVP_Dev_Plan.md`): §2 enumerates what's
  already built, then phases A–F (core stabilization → data/art → specialization+module system →
  meta shell & progression → networking → production) with per-stage DoD.
- `Tank_Prop_Hunt_Game_Modes.md` — **current-state reference for the game modes**
  (TARGET_OBJECTIVE / TEAM_ARENA): rules, round/series flow, HUD block, round-loop code, full map
  list. The "Game modes" section below is a summary; that doc is the detail.
- `Tank_Prop_Hunt_Container_Extraction.md` — **current-state reference for the third mode**
  (CONTAINER_EXTRACTION, `KitchenMap.tscn`): the 5 white containers and how they ride in the
  modification slot, `ContainerManager` (layout / delivery / drop-on-death), the toy-scale kitchen
  map with its six height tiers, the two new geometry prefabs (`Structure` / `ToyRamp`) and the
  **hard-won ramp rules** (≤24° or a box tank stalls; how a ramp must meet a platform edge or the
  navmesh silently disconnects), plus fall damage. Read it before touching that map's geometry.
  Its §10 splits what is genuinely mode-specific (three files) from what rode on existing universal
  systems — the reference for how cheap the *next* mode should be; §11 is the honest remaining-work
  list for the prototype (composition is still 1×1, no carrier marker, no event feedback, bots'
  disguise inert here, balance unplayed).
- `Tank_Prop_Hunt_Bot_AI_Sandbox.md` — the single, universal bot AI (`TankAIController`), used on
  every map: states/driving stack/params.
- `Tank_Prop_Hunt_Tank_Chassis.md` — **current-state reference for how the tank looks and reacts
  to terrain**: the `Hull` visual pivot (`hull_rig.gd`) that carries the code-built armour boxes,
  running gear and the terrain tilt / suspension dynamics; why the turret deliberately stays level
  (aim would drift by the roll angle otherwise) and why `VehicleBody3D` was not used; tracks/road
  wheels with per-side speeds; the slope→speed multiplier, the **edge brink → teeter → tumble**
  system (slope-aware centre-of-mass vs directional edge probes; a recoverable BRINK/TEETER lead-in
  with a defined point of no return, then `TumbleController`'s RigidBody-proxy tumble + turtle
  self-right, GTA-style camera) that fires when a tank goes off a cliff; and the `TestGroundMap.tscn`
  proving ground with its measured ramp-climb limit. Read it before touching the tank's visuals or
  anything that reads the hull's orientation.
- `Tank_Prop_Hunt_Ammo_Drops.md` — **current-state reference for ammo drops**: the `AmmoDropZone`
  prefab (circle + high dummy) placed in every map's empty corners, its drop/pickup/anti-overlap
  rules, per-map placement, `GameConfig` defaults.
- `Tank_Prop_Hunt_Disguise.md` — **current-state reference for disguise**: activation (player-only,
  key **M**), the `GameConfig`-driven prop (meta-game picks it later), x-ray-silhouette player view,
  full break-trigger list incl. the two enemy-relative rules, and the bot's `_can_see()` blindness
  gate.
- `Tank_Prop_Hunt_Modifications.md` — **current-state reference for the tank modification system**:
  the single HUD slot (pick up only when empty, both teams, no drop — use or lose on death), the
  red `ModCrate` (spawned by the ammo drop-zone leader, both zones at once, `TARGET_OBJECTIVE`
  only), and the first modification, the **mortar** — barrel attachment, two-press lobbed special
  shot with its own aiming camera + ground-ring reticle, `GameConfig.mortar_objective_damage`
  to the 100-HP objective / one-shot vs the now-3-HP tanks. Bots pick up **and use** it (`MOD_SEEK`/`MOD_RETRIEVE`/
  `MORTAR_ATTACK`): attackers only within a 10 s window after each mortar drop (and coordinating so
  two bots don't chase the same zone), defenders only on a crate they can see.
- `Tank_Prop_Hunt_Turrets.md` — **current-state reference for the stationary turret system**: the
  universal `Turret.tscn` prefab (own scene, dropped into any map's `.tscn` per side via
  `@export team`, no spawner), its 3 states (SEARCH 360° sweep / ATTACK / RELOAD), MEDIUM-base +
  EASY/HARD difficulty presets, 10-HP destructible body, tank-cadence fire (3 s between shots) +
  10-round mag + 5 s reload, near blind-zone (`min_fire_range` — drives out of `_can_see`, not just
  fire), disguise blindness, the ally→turret
  ALERT target-share, the "mortar on the objective kills the guard turret first" geometry, and the
  debug FOV/fire-sector overlay.
- `Tank_Prop_Hunt_Map_Creation_Guide.md` — **step-by-step how-to for designers** (assumes no
  project knowledge): make a new map + assign its `match_mode`, the required-node skeleton, add/tune
  the `Objective`, place `SpawnZone`s + author the roster JSON (role/difficulty/count/waypoints),
  place + tune `AmmoDropZone`s. Task-oriented; the `Game_Modes`/`Bot_AI`/`Ammo_Drops` docs are the
  system detail it points back to.
- `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md` — **step-by-step how-to for designers**: add / remove
  / move / resize `Obstacle*` (solid) and `HazardZone*` (impassable area) under `NavigationRegion3D`,
  and the mandatory manual NavMesh re-bake after any such change (editor "Bake NavigationMesh"
  button, per-map, no automation; async-bake gotcha if scripted). Placement pitfalls (agent-radius
  clearance, keep zone circles clear).

## Running / testing

No build step (GDScript is interpreted) and no automated test suite exists in this repo. Verify
changes by actually running the project — normally through the `godot-runtime` MCP server
(`run_project` with `background: true`, then `get_debug_output` immediately to catch script/scene
errors, then `run_script`/`take_screenshot`/`simulate_input` to drive and inspect a live session,
then `stop_project`). See the `godot-mcp-testing` skill for the full tool catalog and known
gotchas of that MCP server; don't rediscover them by trial and error.

`res://scenes/tank/tank_ai_controller.gd` has no counterpart in a formal test suite either — its
correctness is established the same way (live `run_script` assertions on state, not manual play).

**Batch calibration** — `tools/calibration/calibrate.gd` runs a whole map's scene-bring-up
invariants in **one** `run_script` (autoloads, `match_mode` / `total_rounds`, `MatchManager` /
`RoundTimer` / `ScoreManager`, borders, the tank component set, bot-AI enabled, root-upright,
kill-plane, plus per-mode checks — objective HP pool, no-objective, container layout). Launch
a map, wait for bring-up (~3 s flat maps, ~6 s `KitchenMap` — it bakes its navmesh), then
paste the file's contents as the `run_script` `script` arg (that tool takes inline source, not
a `res://` path). It returns `{pass, summary, failed[], passed[]}`; a non-empty `failed` is a
regression to explain before shipping. Prefer extending its `_MAP_EXPECT` + per-map functions
over one-off ad-hoc `run_script` checks — one launch, many asserts.

**Current `run/main_scene`** (`project.godot`) points at `res://scenes/main_menu/MainMenu.tscn` — a
plain two-button launcher, not either map scene directly. Pick one from there, or see "Map
inventory" further down and point `run/main_scene` at a specific map (or pass `scene:` to
`run_project`) to skip the menu when iterating on one map.

## Invariants — never violate these

Terse list; each points into `.claude/architecture.md` for the mechanism. These are the
rules whose breach is a silent-corruption / never-converges / runtime-error class bug, not
a style preference.

1. **The tank root never tilts.** Only `Hull` (visual pivot) and `Turret` (its child) tilt.
   forward/right, aim, turret yaw and the entire bot brain read the **root** basis. Sole
   carve-out: `TumbleController` during a cliff tumble — safe only because every root-basis
   reader is frozen meanwhile. → "Tank as a composed entity".
2. **World vs local gun angles.** The turret tilts, so a local gun angle ≠ a world angle.
   `BarrelController.target_pitch` is the *ordered* elevation in **world** terms. Any
   "is the gun on target?" check reads `world_pitch()` / `world_pitch_limits()`, **never
   `rotation.x`** — on a slope a compare against the local angle never converges and bots
   stop firing. Normal-shell world elevation is capped 20° (mortar raises it to 85° while
   aiming, then restores). → "Tank as a composed entity".
3. **No `await` before tree-independent setup in a map root's `_ready()`.** `await` (navmesh
   bake, dynamic obstacles) voids the "root `_ready()` beats every `_process()`" assumption
   that `ammo_drop_zone.gd` / `hud.gd` / `tank_ai_controller.gd` lazy-inits rely on. Anything
   needing no tree (copy `match_mode` into `MatchState`) goes at the very top, before any
   `await`. A lazy init that needs a code-created node waits for **that node**, not "one
   frame". → "Scene bring-up ordering".
4. **`add_child()` on `current_scene` from inside a sibling's own `_ready()` fails**
   ("Parent node is busy setting up children"). Per-match setup runs from the map root's
   `_ready()`, which finishes last. → "Scene bring-up ordering".
5. **A node's `_ready()` must not read a value another sibling's `_ready()` sets** (e.g. HUD
   reading `tank.team`). Sibling `_ready()` order is not the fix — read it from an autoload
   set up before scene load (`MatchState`). → "Scene bring-up ordering".
6. **Signal handler arity must match the emitted arity exactly** or it is a runtime error,
   not a warning. `HealthComponent.damaged` emits `(current_hits, max_hits, killer)`.
   → "Signals over polling".
7. **A freshly-added `class_name` is not seen by headless `run_project`** without an editor
   rescan. Use a `preload()`'d script reference instead (e.g. `SpawnZone.face_center`).
   → "Spawn system".
8. **`match_mode`'s script default is `-1`, a deliberate invalid sentinel** — keeps the
   `.tscn` line always serialized. Still `-1` at runtime ⇒ the line was dropped ⇒
   `push_error` + fallback to TARGET_OBJECTIVE. Conversely **default-valued `@export` lines
   are legitimately absent from a `.tscn`** (`final_stage_enabled`, `map_border_enabled`) —
   not corruption, do not "restore" them. → "Game modes".
9. **Every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`** — it is freed
   with the objective and absent on maps without one. → "Game modes".
10. **Every component gates on `is_player_controlled` independently, default `true`.**
    Spawning a second tank without flipping that flag first makes it read the real player's
    keyboard. Disable it (and hand off camera activity) before it is alive in the tree.
    → "Tank as a composed entity".
11. **`ledge_max_slope_deg` must stay well above the ~44–45° climb limit**, and the
    centre/march support probes need generous vertical reach, or a tank perched nose-up on a
    steep ramp reads as "off a cliff" (broke ramp climbing twice). → "Tank as a composed
    entity" (ledge / brink / tumble).

## Architecture map

Full mechanism for every entry below is in **`.claude/architecture.md`** under the same
section name. Read that file before non-trivial work on any of these systems; the summary
here is only enough to know which section to open. Vault docs stay the source of truth for
anything a section marks "full detail: `Tank_Prop_Hunt_*.md`".

### Tank as a composed entity

`scenes/tank/Tank.tscn` — the one scene for the player's tank **and** every bot
(`team_spawner.gd` instances it N times). All behavior is in sibling components under the
root, each independently toggled player/AI by its own `is_player_controlled: bool`:

- `tank.gd` — `team` / `is_attacker()`; the always-on team-colour tint (`apply_team_visuals()`,
  recursive `Hull`+`Turret` walk minus running gear + mortar); debug-only billboard HP `Label3D`.
- `Hull` (`hull_rig.gd`) — the **visual** hull pivot; every chassis mesh is built in code as its
  children. Owns the terrain tilt (4 corner rays + accel dive/squat + turn roll). `Turret` is a
  child of this pivot, so the ring tilts with the deck (one degree of freedom).
- `BarrelController` — pitch; converts the world `target_pitch` to a local angle via
  `mount_pitch()` and clamps *that* to the trunnion limits. See Invariant 2.
- root **collider** — `ConvexPolygonShape3D`, `1.2×0.6×1.8` at y+0.3, bottom nose/tail edges
  chamfered ⇒ climbs lips ≤ 0.20 and ramps ≤ 44°. Bounding half-extents unchanged, so
  `HULL_HALF_EXTENTS` and every AABB rule still hold.
- `TankMovement` — tracks; strips the sideways `move_and_slide()` drift each frame; also owns
  **fall damage**, the **slope-speed multiplier**, the **carry-weight multiplier** (a loaded
  modification slot slows the tank — the extraction container is 0.7), the **step-up assist**, and
  the **ledge / brink / teeter** support model (directional edge-marches + CoM margin, three
  recoverable stages then a point of no return).
- `TumbleController` — on a cliff commit an invisible `RigidBody3D` proxy (real low CoM, decides
  tracks-vs-roof by physics) takes over, its transform copied onto the root each frame; turtle
  self-rights after a cooldown. The **only** time the root is not upright.
- `CameraRig` (`SpringArm3D`) — player only; free-look orbit, `rotation.y = world_yaw −
  body.rotation.y`; lifts as the aim rises; GTA-style level-follow during a tumble.
- `TurretController` — yaw, `rotate_toward` at constant angular velocity (not `lerp_angle`).
- `WeaponController` — fires along the barrel's actual basis; gated by
  `TankStateMachine.request_fire()`.
- `TankStateMachine` — `NORMAL / DISGUISED / DISGUISE_COOLDOWN / RELOAD`; the single authority
  (`can_fire()` / `can_enter_disguise()` / `break_disguise(reason)`).
- `DisguiseController` — key **M** → tank looks like the `GameConfig` prop; full break-trigger
  list; bots disguise only via roster-gated ambush scenarios; `_can_see()` blindness gate +
  `ignore_disguise` for a bot already fighting the target. Detail: `Tank_Prop_Hunt_Disguise.md`.
- `CollisionDetector` — Area3D; a *moving* tank of any team touching a `DISGUISED` tank breaks it.
- `ModificationController` — one generic pickup slot; a `Modification` `Resource` +
  optional `behavior_scene` (null = passive, e.g. `container.tres`); fixed null-safe contract,
  no `id == &"mortar"` checks. `carry_speed_multiplier()` is the one contract entry read off the
  **resource** rather than a behavior node, so passive mods can have weight. Only behavior so far:
  the mortar. Detail: `Tank_Prop_Hunt_Modifications.md`.
- `HealthComponent` — `take_hit(killer, damage := 1)`; tanks `max_hits` 3; the objective reuses
  it as a 100-HP pool; `attackers_only` / `free_on_destroy` / `invincible` / `force_destroy()`.
- `RespawnController` — disables the tank in place on death, respawns after
  `respawn_cooldown_sec`; force-kills any tank below y = -3; `halt()` on round end stops it for
  the scene load.
- `TankAIController` — the one bot brain, a dormant sibling on every instance (see its own entry).

### Scene bring-up ordering

`scenes/maps/map_scene.gd._ready()` explicitly sequences `_build_map_borders() →
TeamSpawner.spawn_team() → MatchManager.setup(...) → ScoreManager.begin_match()`.
`_build_map_borders()` code-generates a red 4-wall perimeter from the `Ground` box (per-map
`map_border_enabled`, default on). Governed by Invariants 3–5.

### Autoloads and per-tank config

`GameConfig` — project-wide balance knobs. `MatchState` — survives
`reload_current_scene()`: `player_team`, `match_mode`, the by-side series score
(`series_wins_attack` / `_defense`, `total_rounds`), `current_round_num`, the debug/dynamic
flags. Two unrelated JSON layers: `config/{player,bot}_tank_config.json` = per-profile
**physical stats** (speed, turret rate, projectile speed, `max_hits`, `self_right_cooldown_sec`);
`config/roster_*.json` = **who** (team / role / difficulty / count / waypoint routes). Don't
confuse them.

### Spawn system — `TeamSpawner` + `SpawnZone`

`team_spawner.gd` reads a roster JSON (`@export roster_config_path`) and instances `Tank.tscn`
per squad dict (`team`, `count`, `reserve_for_player`, any subset of `TankAIController`
fields). `spawn_zone.gd` marks a circular area (`@export radius`), team by node-name prefix.
**`zone_role` is a Godot group**, not a name pattern — consumers do one
`get_nodes_in_group(role)`. `TankAIController.waypoint_routes` is an ordered list of roles =
one concatenated patrol loop. A zone whose role no roster references is dead weight — delete
it. `SpawnZone.face_center()` orients a tank toward map-XZ-origin after every spawn.

### Signals over polling

Nearly everything is signal-driven (`state_changed`, `damaged` / `destroyed`, `ammo_changed`,
`round_ended`); HUD and AI subscribe. Deliberate exception: `Timer.time_left` polled in
`_process()` for the countdown. See Invariant 6 for the arity rule.

### Game modes

Three modes keyed off `MatchState.match_mode`, one map each. **TARGET_OBJECTIVE** — objective
`HealthComponent` as an HP pool; destroyed ⇒ attack win, timer out ⇒ defense win; 180 s;
buzzer-beater settle phase lets a lobbed mortar still count. **TEAM_ARENA** — deathmatch by
kill count, fixed colour teams Красные/Синие, 180 s. **CONTAINER_EXTRACTION** — 5 containers
ride the `ModificationController` slot as passive mods, CTF delivery to your own `SpawnZone`,
single 300 s round. All three share the `map_scene.gd` round loop; match is best-of-3 by side;
side-swap **only** in TARGET_OBJECTIVE; the final stage is a per-map opt-in
(`final_stage_enabled`, carried only by `TeamArenaMap`). Ammo + mod crates: the
lowest-path drop-zone joins group `ammo_drop_zones` as leader and owns the timers. Full
reference: `Tank_Prop_Hunt_Game_Modes.md` + `Tank_Prop_Hunt_Container_Extraction.md`.

### Debug mode

Everything is gated on **`MatchState.debug_enabled`** (menu checkbox, **default ON**, survives
reload, untouched by `reset_series()`). Gates the immortality button + forced player invincible,
the `Objective:` / observer-camera / `+ Бот` / `Реакция ботов на игрока` controls, the HP
labels, the FOV / nav-path overlays, and the `SpawnZone` debug circles.
**RELEASE TODO**: move this entry off the visible menu (CLI flag / dev build) before Steam —
also noted in `MatchState.debug_enabled`'s doc-comment and a `project` memory.

### `TankAIController` — the one universal bot brain

`scenes/tank/tank_ai_controller.gd`, a dormant sibling on every `Tank.tscn` (player included),
lazily self-inits on the first enabled `_physics_process()`. 21-state priority engine +
NavMesh driving stack (pure pursuit + emergency brake + stuck detector + gap-scan detour),
roles `ACHIEVER` / `KILLER` (`ACHIEVER` self-degrades where there's no objective), 3 difficulty
tiers. All lookups are group- / recursive-search based ⇒ one file, every map. Ledge check is
roster-gated (map property). Full state / priority / parameter tables:
`Tank_Prop_Hunt_Bot_AI_Sandbox.md` — read it before non-trivial work here.

### Obstacle prefab system — `scenes/obstacles/`

Map geometry is prefab **instances**, nothing looked up by name. `Obstacle` (solid box, group
`"obstacles"`, doubles as the disguise prop, **wiped by the dynamic pass**), `Structure`
(permanent geometry, group `"structures"`, **not** wiped — the split is load-bearing),
`HazardZone` (impassable `Area3D`, layer 4), `ToyRamp` (the only incline primitive; place at
the bottom and yaw). Manual NavMesh re-bake after any add / move / resize / delete.

### Dynamic obstacle system — random pre-match layout (per-map, opt-in)

`MatchState.dynamic_obstacles` (menu checkbox). `dynamic_obstacle_placer.gd`
(`populate(map_root, nav_region, seed)`) is deterministic by seed — same int ⇒ byte-identical
layout, the netcode hook. `map_scene.gd._apply_dynamic_obstacles()` swaps in the cubes,
re-bakes the navmesh (`STATIC_COLLIDERS`), connectivity-checks spawn↔spawn / spawn↔objective,
and re-rolls the seed up to 4× before proceeding with a warning. Layout lifetime = one match.
HazardZones are never carved into the navmesh — reactive avoidance only.

### Stationary turret system — `scenes/turret/`

`Turret.tscn` prefab, dropped into a map per side (`@export team`), no spawner. `turret.gd`
shell (`max_hits` 10, `free_on_destroy`, group `"turrets"`) + `turret_ai.gd`
(SEARCH 360° sweep / ATTACK / RELOAD, MEDIUM base + EASY/HARD presets, `min_fire_range` near
blind-zone, disguise gate, tank-cadence fire). `TankAIController` shares ALERT targets to
same-team turrets. "Mortar on the objective kills the guard turret first" is pure geometry —
`ObjectiveTurret` sits on the objective's top face. Full reference: `Tank_Prop_Hunt_Turrets.md`.

### Map inventory

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` — a plain `Control` scene, four buttons, each
just calls `get_tree().change_scene_to_file()` at one of the scenes below; carries no game logic of
its own. Launch any of them directly via `run_project`'s `scene:` param (or repoint
`run/main_scene`) to skip the menu:

- `scenes/maps/TargetObjectiveMap.tscn` — TARGET_OBJECTIVE template: an `Objective` at the map
  centre `(0,1,0)` (no central wall), the `Waypoint1..4` defender diamond around it, one defense
  bot (`ACHIEVER`, patrols/defends around it) and one attack bot (`ACHIEVER`, one-way route to the
  objective), both `TankAIController`, plus an `ObjectiveTurret` (`Turret.tscn` instance, `team=1`)
  sitting on top of the objective as a complication — see "Stationary turret system" above and
  `Tank_Prop_Hunt_Turrets.md`. Balance knobs stay single-sourced: mortar damage is
  `GameConfig.mortar_objective_damage`, the alert-circle radius is `ObjectiveAlertZone.radius` in
  the `.tscn` — docs cite them by name, values live only in the two param tables
  (`Tank_Prop_Hunt_Modifications.md` §8, `Tank_Prop_Hunt_Map_Creation_Guide.md` §2.4).
- `scenes/maps/TeamArenaMap.tscn` — TEAM_ARENA template: one `KILLER` bot roaming the whole map,
  described above.
- `scenes/maps/KitchenMap.tscn` — CONTAINER_EXTRACTION template and the project's only
  **multi-level** map: a toy-scale kitchen (**24 units = 1 m**, tank ≈ 7.5 cm) on a 108×84 floor,
  six height tiers (floor 0 · chairs/stool 10.8 · sink 15.6 · table 18 · counter 21.6 ·
  shelf+cabinet 30 · shelf+fridge 43.2) joined only by `ToyRamp` inclines. Bases sit on surfaces
  (attack on the table, defense on the counter); five `ContainerSpawn`-role markers, one per tier.
  It bakes its navmesh at load (`bake_navmesh_on_start`) instead of storing it, and opts out of
  dynamic obstacles (`dynamic_obstacles_supported = false`). **Before editing its geometry read
  `Tank_Prop_Hunt_Container_Extraction.md` §2.3** — ramps must stay ≤24° (a box `CharacterBody3D`
  stalls dead at ~28° despite `floor_max_angle` 45°), must end exactly on a platform edge, must not
  lie flat across a platform, and a diagonal ramp needs a flat coplanar landing or the navmesh
  silently splits into islands.

- `scenes/maps/TestGroundMap.tscn` — **not a map and not a mode**: the chassis proving ground
  (`test_ground.gd`). No `map_scene.gd`, no `MatchManager`/roster/HUD/navmesh — just the player
  tank, a dummy tank and a code-built course (ramps 6°…48°, a row of 0.04…0.40 lips, washboard,
  smooth waves, a side slope to cross, a jump, an **"Обрыв"** raised platform with sheer edges for
  the brink/tumble system) plus a readout of hull pitch/roll, sag, the slope-speed multiplier and
  the edge state (`зазор ЦМ`, `подход %`, `крен`, TEETER / КУВЫРОК). Keys: `R` reset, `T` terrain
  tilt on/off, `Y` running-gear animation
  on/off, `F` readout. This is where the collider chamfer was measured (see the collider bullet
  above): ramps pass up to 44°, lips up to 0.20. Re-measure here after any change to the collider
  or to `move_speed`/`acceleration` rather than trusting a number from another map. Detail:
  `Tank_Prop_Hunt_Tank_Chassis.md` §10.

An earlier, separate "production" map (`Main.tscn`/`Map.tscn`, a 5×5 proof-of-concept predating
stable bot behavior) was retired once these two became the real game-mode templates — recoverable
from `git log` if ever needed, not reused.

## External Godot skill library

`~/.claude/skills/godot/skills/` holds ~100 `godot-*` skills (the third-party
`gd-agentic-skills` pack + four first-party workflow skills). The full index — one-line
purpose per skill plus a **USE / LATER / SKIP** classification for this project — lives in
`Claude Common/godot-skill-catalog.md`, kept cross-project on purpose. Consult that file
before loading a `godot-*` skill here: most genre / platform / 2D / adaptation skills are a
paradigm mismatch for a 3D desktop tank shooter and the catalog says which, while the LATER
list flags the ones that become relevant at a named roadmap phase (art, modules, meta shell,
networking, production) so they aren't forgotten. The pack is a reference to check against,
not a source of truth — this `CLAUDE.md` and the vault docs win on any conflict.

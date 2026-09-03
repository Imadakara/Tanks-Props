# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Tank Prop Hunt — a team tactical shooter with prop-hunt elements (disguise mechanic), Godot 4.7
(GDScript), 3D, Jolt physics. Local prototype vs bots, no networking yet — the two maps are built
as reusable game-mode templates (see "Map inventory") with a future networked PvP mode in mind, so
architecture favors universal/data-driven mechanisms over map-specific code wherever the two don't
conflict.

Full design docs live outside this repo, in `C:\Users\PC\Documents\Personal Vault\Tank Props Docs\`.
Code comments frequently say "see vault" — that's this folder, not anything inside the repo. Read
the relevant doc before doing non-trivial work on a system it covers — they record *why*, not just
what the code does, including reasoning behind changes that were tried and reverted.

- `Tank_Prop_Hunt_Gameplay_Concept.md` — design concept.
- `Tank_Prop_Hunt_TZ_MVP_Godot.md` — spec / ТЗ.
- `Tank_Prop_Hunt_MVP_Dev_Plan.md` — dev plan with per-stage implementation history and gotchas.
- `Tank_Prop_Hunt_Game_Modes.md` — **current-state reference for the game modes**
  (TARGET_OBJECTIVE / TEAM_ARENA): rules, round/series flow, HUD block, round-loop code, full map
  list. The "Game modes" section below is a summary; that doc is the detail.
- `Tank_Prop_Hunt_Bot_AI_Sandbox.md` — the single, universal bot AI (`TankAIController`), used on
  every map: states/driving stack/params.
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
  shot with its own aiming camera + ground-ring reticle, +30 to the 100-HP objective / one-shot
  vs the now-3-HP tanks. Bots pick up **and use** it (`MOD_SEEK`/`MOD_RETRIEVE`/
  `MORTAR_ATTACK`): attackers only within a 10 s window after each mortar drop (and coordinating so
  two bots don't chase the same zone), defenders only on a crate they can see.
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

**Current `run/main_scene`** (`project.godot`) points at `res://scenes/main_menu/MainMenu.tscn` — a
plain two-button launcher, not either map scene directly. Pick one from there, or see "Map
inventory" further down and point `run/main_scene` at a specific map (or pass `scene:` to
`run_project`) to skip the menu when iterating on one map.

## Architecture

### Tank as a composed entity, not a god-object

`scenes/tank/Tank.tscn` is the single reusable scene for both the player's tank and every bot
(`scenes/main/team_spawner.gd` instances it N times). All behavior lives in sibling components
under the root (`tank.gd`, which holds `team`/`is_attacker()`, the **team-colour mesh tint**
via `apply_team_visuals()` — `GameConfig.team_attack_color`/`team_defense_color` on
`HullMesh`/turret/barrel, called by `team_spawner.gd` after `team` is assigned and by
`RespawnController` via `on_respawned()` — and, **debug-mode only**, a billboard `Label3D` "HP
N/M" above the tank updated on `damaged`/`destroyed`/respawn; this replaced the old red
"подранок" material swap so it doesn't fight the team tint), each independently
toggled between player and AI control via its own `is_player_controlled: bool`:

- `TankMovement` — tracks, reads `Input` or `ai_move_input`/`ai_turn_input`. Only forward/back +
  hull rotation are ever commanded (no strafe axis exists), but `move_and_slide()` on its own will
  still glide the body sideways along a collision tangent when it contacts geometry at an angle —
  normal for a generic character, wrong for a tank. `_physics_process()` corrects for this every
  frame: after `move_and_slide()`, it discards whatever component of the frame's *actual* resulting
  displacement/velocity is perpendicular to the hull's forward axis, keeping only forward/back. Found
  via the bot-AI obstacle-avoidance work (see the Bot AI vault doc) when the bot visibly skidded
  sideways brushing a corner — same underlying `move_and_slide()` behavior applies to the player
  too, just less obvious since a human steers away from corners instinctively.
- `CameraRig` (`SpringArm3D`) — player only; free-look orbit independent of hull rotation. Its
  `rotation.y` is recomputed every physics frame as `world_yaw − body.rotation.y`, so turning the
  hull never drags the camera with it.
- `TurretController` — yaw. When `is_player_controlled`, reads `target_yaw` straight from
  `CameraRig`; for bots, whatever AI script owns the tank writes `target_yaw` directly. Either way
  the actual turn is `rotate_toward(rotation.y, target_yaw, turn_speed*delta)` — constant angular
  velocity (not `lerp_angle`, which was tried and produces a non-linear "fast far / creeping near"
  feel).
- `BarrelController` — pitch, same follow-with-delay pattern.
- `WeaponController` — fires along the barrel's actual basis (no separate angle math); gated by
  `TankStateMachine.request_fire()`.
- `TankStateMachine` — `NORMAL/DISGUISED/DISGUISE_COOLDOWN/RELOAD`, the single authority other
  components consult (`can_fire()`, `can_enter_disguise()`, `break_disguise(reason)`). Timer
  durations come from the `GameConfig` autoload, but `reload_timer.wait_time` is re-read fresh in
  `request_fire()` rather than cached in `_ready()` — a defensive read, in case some future map ever
  needs to override `GameConfig.reload_duration_sec` from its own root's `_ready()` (which Godot
  always runs *after* every child, including this state machine, is already ready — caching would
  use a stale value); no current map does this, both use the shared default (3s).
- `DisguiseController` — the disguise mechanic (full detail: `Tank_Prop_Hunt_Disguise.md`). Live and
  player-usable: key **M** anywhere → tank looks like a `GameConfig`-configured obstacle prop (brown
  box for MVP; the meta-game picks the prop later — no per-map `DisguiseSlot` markers, that system is
  deleted). The disguising player sees the prop with an x-ray silhouette of their tank through it;
  everyone else sees the prop only. Bots never activate or seek disguise. A bot **won't acquire** a
  disguised enemy (`TankAIController._can_see()` returns false in `_scan_for_target()` while the
  target's `TankStateMachine` is `DISGUISED`, unless `GameConfig.ai_can_see_disguised_tanks`) — but a
  bot **already in `DEFEND` on that tank keeps firing** through the disguise (`_can_see(target,
  ignore_disguise=true)` in `_think()`): disguising while already someone's target doesn't save you.
  Break triggers: turret turn / move /
  fire / moving-tank bump (`CollisionDetector`, below) / **projectile hit** (`HealthComponent.damaged`
  → `break_disguise("projectile_hit")`; an `invincible` tank absorbs the shell so no `damaged`, no
  break) / **enemy within `GameConfig.disguise_enemy_proximity_break_dist` of the tank collider**
  (when the prop is smaller than the tank on any axis) / **enemy entering the prop's volume** (when
  it's larger — the MVP prop's case; the prop collider itself is never a physics body). The moment disguise drops for any
  reason, the bot re-acquires next think-tick. For bot pathfinding a disguised tank carries a
  prop-sized `DisguiseObstacle` Area3D on layer `disguise_obstacle` (4): the AI's gap-scan detour
  rays see the full prop footprint, but the emergency brake does not — so a bot with a disguised
  tank on its committed route drives up to the real hull, contact breaks the disguise, bot aggros
  (no A* re-plan; the static navmesh never held any tank).
- `CollisionDetector` — Area3D on the tank body; a *moving* tank of any team touching a `DISGUISED`
  tank breaks its disguise (`break_disguise("collision")`). Independent of the enemy-relative rules
  above.
- `ModificationController` — the single pickup-modification **slot**, a generic host. One slot per
  tank; pick up only when empty (`can_pick_up()`), both teams, no drop — `clear_slot()` on use (the
  modification calls it) or on respawn (`RespawnController`). A `Modification` `Resource`
  (`id`/`display_name`/`hud_short` + `behavior_scene: PackedScene`) carries no logic; `install()`
  instances its `behavior_scene` as a child (`setup(tank)` + `on_installed()`), and the controller
  forwards a fixed contract — `intercepts_fire`/`on_fire_pressed`/`blocks_hull_movement`/
  `hides_crosshair` for the player, `ai_usable`/`ai_engage_range`/`ai_prep_sec`/`ai_aim_solution`/
  `ai_fire_at` for `TankAIController` — null-safe. Base contract:
  `scenes/modifications/modification_behavior.gd` (`extends Node3D`, no `class_name`, all methods
  no-op). `weapon_controller`/`tank_movement`/`hud`/`tank_ai_controller` all talk to this contract —
  no `id == &"mortar"` checks. The only behavior so far is the **mortar**
  (`scenes/modifications/mortar/{mortar_behavior.gd,Mortar.tscn}`): a two-press lobbed special shot
  (aim mode → ground ring reticle → `WeaponController.fire_special(dir, speed, damage)`), the one
  mortar-specific node in `Tank.tscn` being `Turret/MortarCamera`. Bots pick it up **and** use it
  (`MOD_SEEK`/`MOD_RETRIEVE`/`MORTAR_ATTACK`). Full detail: `Tank_Prop_Hunt_Modifications.md`.
- `HealthComponent` — `take_hit(killer, damage := 1)`; `current_hits += damage`, `destroyed` at
  `current_hits >= max_hits`. Tanks use `max_hits` **3** (`config/*_tank_config.json`, script
  default also 3 — raised from 2 so the mortar has a point vs tanks; normal `Projectile.damage` is
  1; a non-fatal hit updates only the debug HP `Label3D`, no mesh repaint). The objective uses this as an **HP pool** — `match_manager.gd` sets its
  `max_hits = GameConfig.objective_hits_required` (**100**), a normal shell does 1, the mortar
  special does `GameConfig.mortar_objective_damage` (30). `attackers_only` lets an objective ignore
  friendly fire;
  `free_on_destroy=false` on tanks hands cleanup to `RespawnController` instead of freeing the node;
  `invincible` is a point override (see the debug toggle buttons under "Game modes"), not part of
  normal balance. `tank.gd._on_damaged()` refreshes the debug-only HP `Label3D` above the tank
  (billboard, `MatchState.debug_enabled` gate); the tank mesh keeps its team-colour tint at all
  times (`apply_team_visuals()`), no damage repaint. `force_destroy(killer := null)` bypasses `invincible`/`attackers_only`
  but still routes through `destroyed` — for "removed from play regardless of debug immortality"
  cases (only caller today: fell below the map, see `RespawnController`).
- `RespawnController` — on death, disables the tank in place (hidden, colliders off,
  `process_mode = DISABLED` on every sibling except itself and `HealthComponent`) instead of
  freeing it, then teleports/resets it after `GameConfig.respawn_cooldown_sec`. Its
  `_physics_process` (this node is never frozen) also **force-kills any tank whose
  `global_position.y` drops below `_FELL_BELOW_Y` = -3** (fell through the floor / squeezed past
  the map border into the void) via `HealthComponent.force_destroy()` — works on the invincible
  player too; the normal respawn cycle then brings it back at its spawn zone.
- `TankAIController` — the single AI brain for the whole project. Present on every `Tank.tscn`
  instance but inert (`enabled=false`) unless a spawner turns it on; when enabled it flips every
  sibling's `is_player_controlled` to `false` and drives them through the same public contract the
  player uses (`ai_move_input`, `target_yaw`, `try_fire()`) — no duplicated movement/combat logic
  path for bots vs. player. States, roles, driving stack, ammo states: see the Bot AI vault doc.

Because every component gates on `is_player_controlled` independently and defaults to `true`,
spawning a second player-controlled-by-default tank without flipping that flag first means it
reads the same `Input`/keyboard as the real player. Always disable it (and hand off camera
activity, see below) before the instance is meaningfully alive in the tree.

### Scene bring-up ordering

Every map's root script (`scenes/maps/map_scene.gd`) explicitly sequences
`_build_map_borders() → TeamSpawner.spawn_team() → MatchManager.setup(...) →
ScoreManager.begin_match()` in its own `_ready()`, rather than letting each manager act in its own
`_ready()`. (`_build_map_borders()` — a per-map `@export var map_border_enabled` toggle, **default
on**; a map only carries a `map_border_enabled` line in its `.tscn` when it sets `false` (Godot's
editor never serializes a default-valued export — see the `match_mode` note under "Game modes")
— reads the `Ground`
collision box and adds a 4-wall solid red `MapBorders` ring, thickness 1 / height 3, flush with the
ground edge, under `NavigationRegion3D` — an impassable perimeter so bots can't drive off the map;
code-generated so it fits any map's ground size with no per-`.tscn` geometry work. It's a physical
block regardless of navmesh; a manual navmesh re-bake would additionally carve the edges. The rare
tank that still slips past — or a map that opts out of the border — is caught by the fell-below
force-kill in `RespawnController`, above.) Two reasons this matters
when adding new per-match setup code: (1) `add_child()` on `current_scene` from *inside* a
sibling's own `_ready()` fails ("Parent node is busy setting up children") — the tree is still
being built; the root's `_ready()` runs last, after all declared children, so it's the safe place.
(2) `ScoreManager`/`MatchManager` scan the `"tanks"` group and must run after spawning, not before.

Corollary that has bitten this repo twice: a node whose own `_ready()` reads a value another
sibling's `_ready()` is meant to set (e.g. HUD reading `tank.team` before `TeamSpawner` assigns it)
gets the stale default, because sibling `_ready()` order isn't the fix — reading from an autoload
that's set up before scene load (`MatchState`) is. Prefer that over reordering nodes when a value
needs to be correct *during* `_ready()`.

A related ordering pitfall specific to cameras: an about-to-be-activated bot's `CameraRig` also
defaults `is_active = true` and steals `Camera3D.current` the instant it enters the tree, inside
`CameraRig._ready()`. `team_spawner.gd` sets `is_active = false` on the orphaned instance *before*
`add_child()` to avoid a one-frame flicker; `TankAIController._initialize()` also re-asserts
`camera.current = false` as a defensive backup, which works regardless of sibling order since it
only runs on the first `_physics_process()` tick, well after every sibling's `_ready()` including
`CameraRig`'s.

### Autoloads and per-tank config

`GameConfig` (balance knobs shared project-wide) and `MatchState` (survives
`get_tree().reload_current_scene()`, where ordinary `@export` fields on scene nodes don't).
`MatchState` holds: `player_team: int` (the player's *side* this round, flipped by the HUD restart
button — every map has a `TeamSpawner` node, see "Spawn system" below); `match_mode: Mode
{TARGET_OBJECTIVE, TEAM_ARENA}` — a **per-map setting**, not runtime detection: `map_scene.gd` has
`@export_enum var match_mode` set in each map's own scene file; the HUD reads it *lazily* since its
own `_ready()` precedes the root's; and a round-series score (`series_wins_attack`/
`series_wins_defense`, `total_rounds = 3`) tracked **by side, not by "the player's team"** —
`record_round_result(winner_side)` just credits whichever side ("attack"/"defense") took the round.
In TARGET_OBJECTIVE the player swaps sides between rounds (see side-swap under "Game modes"), so
"the player's team" isn't a stable thing; the attack/defense **bot squads** are (fixed by roster).
In TEAM_ARENA there's no swap, so "attack" is permanently team 0 / Красные and "defense" team 1 /
Синие. `MatchManager._end_round()` calls `MatchState.record_round_result(winner)` before emitting
`round_ended`; the series accumulates across `reload_current_scene()` and is reset only from the
main menu (`main_menu.gd`) or the "Новый матч" button after `series_complete()`.
`config/player_tank_config.json` and `config/bot_tank_config.json` hold per-profile physical stats
(speed, turret turn rate, projectile speed, `max_hits`) read once by `team_spawner.gd` — these are
tank-profile data, not match balance, which is why they're JSON next to `GameConfig` rather than
fields on it. A second, unrelated JSON layer — `config/roster_*.json` — holds "who" (team/role/
waypoint prefix/...), not "what stats"; see "Spawn system" below, don't confuse the two.

### Spawn system — `TeamSpawner` + `SpawnZone` (one mechanism, every map)

Every map spawns bots the same dynamic way — a future networked PvP mode needs match-start-time
composition, not tanks baked into a `.tscn` — so every map has its own `TeamSpawner` node
instantiating `Tank.tscn`; no map has static bot nodes.

**`scenes/main/team_spawner.gd`** (`TeamSpawner`) reads a JSON **roster** from
`@export var roster_config_path` (same per-instance-config pattern as `map_scene.gd`'s
`match_mode`) — `config/roster_target_objective.json`/`config/roster_team_arena.json`. A roster is
an array of "squad" dicts:

> If a roster (or any `config/*.json`) shows a whitespace-only diff after a Godot editor
> session, it's Godot's `text_editor/behavior/files/convert_indent_on_save` (default on)
> reindenting the file while it sits open in a script-editor tab — a per-machine editor
> setting, fixed by turning it off; see the `godot-editor-convert-indent` memory. Not a code
> issue; `git checkout -- config/<file>.json`.

- `team` (0/1) — which `SpawnZone` the squad spawns from.
- `count` — bots in this squad; `0`/absent → `GameConfig.team_size` (the one place team size is
  ever read; both current rosters instead give a fixed explicit count, e.g. `1`, since neither map
  runs a full 5×5 team right now).
- `reserve_for_player` (bool) — when `true` and this squad's `team == MatchState.player_team` that
  round, spawns one fewer bot (the player fills one of that squad's slots). Neither current roster
  sets this — the player coexists *beside* a fixed bot roster, not filling a slot in it; a future
  full-team map would set it on both squads.
- Any subset of `TankAIController` fields (`role`, `difficulty`, `waypoint_name_prefix`,
  `waypoints_one_way`, `hunt_area_center`/`_half_extents`, `forward_look_bias`, `debug_ui_slot`,
  the four `show_*_debug` flags) — applied only if the key is present (`_apply_squad_to_brain()`),
  an omitted key keeps the script's own `@export` default.

Physical tank stats are a separate, unrelated JSON layer — `config/player_tank_config.json`/
`bot_tank_config.json` (speed, turret turn rate, projectile speed, `max_hits`), applied via
`_apply_tank_config()` regardless of roster. `PlayerTank` itself stays a static, hand-placed node
on every map (`TeamSpawner` only configures/positions it, doesn't instantiate it) — full "player is
just another roster slot" unification is future networking work, out of scope for now.

**`scenes/main/spawn_zone.gd`** (`SpawnZone`) — a `Node3D` marking a circular area (`radius`,
`@export`) — team is encoded by node-name prefix, not a separate field, the same convention as
`Waypoint`/`AttackWaypoint` (`"AttackSpawnZone"` / `"DefenseSpawnZone"`). `pick_spawn_position()`
picks a uniform-by-area random point inside the circle (`sqrt(randf())`, not `randf()` — same
technique as `tank_ai_controller.gd`'s `_pick_random_point_near()`) and raycasts straight down
(`collision_mask = 1`, "environment") to find the actual ground surface under it, retrying up to
`max_attempts` times before giving up and returning the zone's own center as a deterministic
fallback. It also draws its own debug circle (`ImmediateMesh`, red for `Attack*`/blue for
`Defense*`/yellow otherwise) so a screenshot can confirm placement without guessing. Every caller
adds a small clearance on top (`Vector3(0, 0.3, 0)`) — spawning exactly on the raycast-hit y gives a
degenerate zero-depth floor contact that Jolt handles badly (`move_and_slide()` drops the body
through the floor instead of settling); a small gap lets it settle naturally over a few frames.
Two call sites, both funneling through `pick_spawn_position()`: `team_spawner.gd` and
`respawn_controller.gd` (`_on_respawn_timeout()`) — both do a recursive `find_child`, not tied to
any particular tree depth, so either stays correct even if some future map nests its zones under an
intermediate node (neither current map does).

Zones default to opposite corners of the map — both maps (72×72): `AttackSpawnZone`/
`DefenseSpawnZone` at `(28,28)`/`(-28,-28)`, radius 8.

**Zone "role" is a Godot group, not a name pattern.** Every `spawn_zone.gd`-scripted node has an
`@export var zone_role: String` — non-empty, the node self-registers into that group in its own
`_ready()` (`add_to_group(zone_role)`, the exact same idiom `ammo_drop_zone.gd` already used for
`"ammo_drop_zones"` — not a new mechanism). A consumer asks for "every zone of role X" with one
`get_nodes_in_group(X)`; node *names* are no longer load-bearing for lookup, only for
human-readability and (for ordered patrol routes) sort order within the group. This replaced two
previously-separate ad-hoc name-glob searches that used to be hand-rolled per feature
(`tank_ai_controller.gd`'s waypoint collector, and its disguise hide-zone finder) with one shared
mechanism, used the same way by both.

`TankAIController.waypoint_routes: Array[String]` (falls back to the single legacy
`waypoint_name_prefix` string field when empty — old rosters keep working unchanged) lists zone
roles **in the order the bot walks them**, concatenated into one continuous patrol loop — not
several independent cycles. `TargetObjectiveMap.tscn`'s roster
(`config/roster_target_objective.json`) has exactly two squads (one bot each, `count: 1`): the
attacker follows role `AttackWaypointN` alone (one-way, ends in `ATTACK_OBJECTIVE`); the defender
follows `["DefenseWaypoint", "Waypoint"]` — its own corner-to-centre approach from `DefenseSpawnZone`
first, then the `Waypoint1..4` diamond around the objective, looping forever as one combined
6-point route (mirrors the attacker's corner-to-objective path, then adds the standing guard
patrol) — `_advance_waypoint()`'s existing `%`-cycling logic needed no changes for this, a
concatenated route is just a longer flat list to it. **A zone whose role no roster squad's
`waypoint_routes` references is dead weight** — `TeamArenaMap.tscn` used to carry a full inherited
`Waypoint*`/`AttackWaypoint*`/`DefenseWaypoint*` set nobody referenced (copied over when the map was
duplicated from `TargetObjectiveMap.tscn`; its one roster squad is `role: "KILLER"`, which never
reads `_waypoints` at all) — removed entirely, not re-added, since nothing on that map consumes
patrol routes. See `Tank_Prop_Hunt_Map_Creation_Guide.md` §3.5 for the authoring rule (wire a new
marker set's role to a roster squad immediately, or delete it — never leave it "just in case").

The waypoint collector (`_collect_waypoints()`) and the disguise hide-zone finder
(`_nearest_mortar_hide_spot()`, role `"MortarHideZone"`) both search the whole current scene via
groups, not tied to tree depth or node naming. Every circular waypoint/zone marker (patrol, spawn,
ammo/mod drop, `ObjectiveAlertZone`, the disguise `MortarHideZone1`/`2`) is the same
`spawn_zone.gd`-scripted `Node3D` — see the `spawn_zone.gd` bullet under "Debug mode" for the one
shared debug-circle visual all of them draw (that part stays keyed off node *name* prefix, purely
cosmetic — unrelated to `zone_role`, which only ever affects behavioural wiring).

`SpawnZone.face_center(tank)` (static, called via a `preload()`'d script reference — **not**
`class_name`: headless `run_project` doesn't pick up a freshly-added `class_name` without an editor
rescan, same gotcha as new files with `class_name` in general) orients the tank's forward
(`-basis.z`, confirmed against `tank_movement.gd`'s own forward convention) toward the map's XZ
origin right after every spawn/respawn — both maps have their `Ground` centered at world `(0,0)`,
so "map center" never needs computing per-map. `look_at()` targets the tank's *own* Y (not world 0)
specifically to keep pitch/roll at zero on flat ground; a degenerate near-origin spawn
(distance < 0.01) is a no-op rather than an undefined `look_at()`.

### Signals over polling

Nearly everything (`TankStateMachine.state_changed`, `HealthComponent.damaged`/`destroyed`,
`AmmoComponent.ammo_changed`, `MatchManager.round_ended`) is signal-driven; HUD and AI subscribe
rather than poll. The one deliberate exception is reading `Timer.time_left` in `_process()` for
countdown display, since `Timer` has no per-tick signal.

`HealthComponent.damaged` carries `(current_hits, max_hits, killer)`. Godot does **not** silently
drop a signal's extra emitted arguments when a connected method declares fewer parameters — every
handler must match the emitted arity exactly, or it's a runtime error, not a warning.

### Game modes

Full reference: `Tank_Prop_Hunt_Game_Modes.md` in the vault. Summary below.

Two modes, keyed off `MatchState.match_mode` (see Autoloads above), each map a template for one
mode (see "Map inventory"). **TARGET_OBJECTIVE** (`TargetObjectiveMap.tscn`): an `Objective` static
body with a `HealthComponent` (`attackers_only = true`) sits on the map; **objective destroyed →
round ends with an attack win; round timer expires with it intact → defense win**. Round timer for
this mode is `GameConfig.round_timer_sec` = **180 s (3 min)**. The `ObjectiveAlertZone` (the ground
circle the AI uses for `State.ALERT`) is a **child of the objective node** (local `y = -1` so the
circle sits on the ground), freed together with the objective and simply absent on maps without one
(`TeamArenaMap.tscn`); every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`.
**TEAM_ARENA** (`TeamArenaMap.tscn`, no objective node): team deathmatch,
`GameConfig.team_arena_round_sec` = 180 s / round, round winner by kill count (ties by
`defense_wins_ties`). Sides here are **fixed colour teams** — **Красные**
(team 0) and **Синие** (team 1) — never "attack"/"defense"; the HUD `TeamLabel`, score line and
result screen all say Красные/Синие in this mode (in TARGET_OBJECTIVE they say Атака/Оборона).

`match_mode` is an `@export_enum` on each map root, **stored in the `.tscn`** (`TargetObjectiveMap`
= 0, `TeamArenaMap` = 1). Its script default is **`-1`, a deliberate invalid sentinel**: both real
values (0 and 1) are then non-default, so Godot's editor always serializes the line and a GUI
scene-save can't silently strip it (the old default `0` meant `TargetObjectiveMap`'s
`match_mode = 0` line — equal to the default — got dropped on every editor save). If the value is
still `-1` in `_setup_match_context()` the line really is missing (dropped, or a new map forgot
it): `map_scene.gd` `push_error`s and falls back to `TARGET_OBJECTIVE` rather than running the
wrong mode silently. **Default-valued option lines are legitimately absent from a `.tscn`** —
`TargetObjectiveMap` has no `final_stage_enabled` / `map_border_enabled` line (both equal their
`false` / `true` defaults), `TeamArenaMap` has no `map_border_enabled` line (default `true`); that
is not corruption, don't "restore" them.

Both maps run the **same round loop**: `map_scene.gd._setup_match_context()` creates a `ScoreManager`
+ a node named `"MatchManager"` running `scenes/main/match_manager.gd`, which picks its end-of-round
condition from `match_mode` (objective `destroyed` → attack / timeout → defense, vs. timeout →
winner-by-kills) then `MatchState.record_round_result` → `round_ended`. The same script also owns
the **final stage**: extra time (`GameConfig.final_stage_duration_sec` = 30s, HUD shows a
countdown, ammo crates keep dropping, tanks respawn with ammo), then the round resolves by kill
count. It is a **per-map opt-in** — `map_scene.gd` `@export var final_stage_enabled` (script
default `false`); only `TeamArenaMap.tscn` carries the line (**on**), `TargetObjectiveMap` runs
the `false` default with no line — and it starts
**only at the moment the main `RoundTimer` expires** *and* every still-alive (not respawning) tank
is out of ammo (the round has genuinely stalled). It is **not** triggered mid-round by ammo
running out while the clock is still going. When disabled, or when someone still has ammo, the
round just resolves at timeout by the mode's normal rule. Side-swap between rounds
(`hud.gd._on_restart_pressed`, `_has_side_swap()`) happens **only in
TARGET_OBJECTIVE** (where attack/defense roles genuinely alternate); TEAM_ARENA colour teams are
fixed for the whole match, so its restart button just reloads.

A match is **best-of-3, decided by majority of round wins per side**: `series_complete()` is true
as soon as `series_wins_attack` or `series_wins_defense` reaches `rounds_to_win()`
(`total_rounds / 2 + 1` = 2). So round 1 won by attack + round 2 won by defense = 1-1 → the
decider round 3 is played; a genuine 2-0 for one side ends the match after round 2. Same
`series_complete()` for both modes. `series_winner()` returns `"attack"`/`"defense"`/`"tie"`.

The **round counter** is `MatchState.current_round_num`, a real stored field — **incremented by
`advance_round()` when the *next* round starts** (`_on_restart_pressed`), never when the current
one ends. So the result screen still reads "Раунд 1/3" for round 1's outcome; the top line only
becomes "Раунд 2/3" after the reload. `reset_series()` also zeroes `current_round_num` and
`player_team`.

**Ammo drops** (all maps): a self-contained prefab `scenes/ammo_crate/AmmoDropZone.tscn` — a
spawn-sized ground circle (`DropArea`, reuses `spawn_zone.gd`) plus a high dummy `Marker3D`
(`DropOrigin`, script `ammo_crate/ammo_drop_zone.gd`) — sits in each map's two empty corners
(the diagonal opposite the spawn zones). Cadence is **map-level, not per-zone**: the drop zones
join group `ammo_drop_zones`, the lowest-`get_path()` one is the leader and owns the sole
`DropTimer`; every `drop_interval_sec` (30 s) the leader drops **one** `AmmoCrate` at a **random**
zone (`shuffle` + first that accepts) — not one per zone. The crate falls kinematically to a
random clear point in that zone's circle, never overlapping a still-unpicked crate
(`min_crate_separation`, per-zone cap `max_pending_crates` → `GameConfig.ammo_crate_count`; these
three stay per-zone, only the interval + round-end stop are centralized on the leader). Pickup is
`Area3D.body_entered` → `AmmoComponent.add_ammo` (player and bots alike; bots path to zones/crates
via `TankAIController`'s `AMMO_SEEK`/`AMMO_RETRIEVE`/`AMMO_WAIT` states, see the Bot AI vault doc).
Full detail: `Tank_Prop_Hunt_Ammo_Drops.md`.

**Modification crates** (`TARGET_OBJECTIVE` maps only): the same drop-zone leader also runs a
`MortarDropTimer` (`GameConfig.mortar_drop_interval_sec`, 30 s) that drops one **red `ModCrate`**
in *every* zone simultaneously (not one at a random zone like ammo). A `ModCrate` fills the tank's
`ModificationController` slot with the mortar mod when the slot is empty. `TeamArenaMap.tscn`
(`TEAM_ARENA`) starts no such timer. Full detail: `Tank_Prop_Hunt_Modifications.md`.

The **HUD match block** (top-center, all maps, `hud.gd`): line 1 `Раунд N/M | MM:SS`
(N = `current_round_num`), line 2 the mode-dependent overall score — TARGET_OBJECTIVE: series only
(`По раундам — Атака N : M Оборона`, by side since the player swaps); TEAM_ARENA: round kills +
series, all by colour (`Убийства  Красные K : L Синие      Раунды  N : M`, Красные =
`series_wins_attack`, always the left number) — line 3
`Цель: N/M попаданий` — objective health, TARGET_OBJECTIVE only, resolved via
group `"objective_health"` (same group `TankAIController` reads, not by node name — no
`OBJECTIVE: TARGET` prefix, the mode name lives in the map settings, not the HUD), line 4 the
player respawn countdown (`Респаун через N с`, `RespawnLabel`) shown only while
`PlayerTank/RespawnController.time_until_respawn() > 0`. The HUD resolves `MatchManager`/
`RoundTimer`/`ScoreManager`/objective **lazily** and polls them, because `map_scene.gd` creates
those nodes in code *after* the HUD's own `_ready()`.

### Debug mode

All debug scaffolding is gated behind a single session flag, **`MatchState.debug_enabled`**
(autoload, so it's readable in every `_ready()`; survives `reload_current_scene()`;
`reset_series()` does **not** touch it). Set by a checkbox in the map-select menu
(`main_menu.gd` → `_go()`, before `change_scene_to_file`), **default checked / ON**. Launching a
map scene directly (editor / `run_project` with `scene:`, bypassing the menu) leaves it at its
`true` default, so the dev workflow stays debuggy with no extra step.

What the flag gates (each also keeps its finer per-instance filter, e.g. the bot's `show_*_debug`
`@export`s, `SpawnZone.show_debug_circle`):
- `map_scene.gd` — the `Игрок: бессмертие ON/OFF` button *and* the forced `_player_health.invincible
  = true` it sets (so with debug OFF the player is mortal); the `Objective: ON/OFF` button; the
  1/2/3 observer-camera keys (`_unhandled_input`); the `+ Бот (атака)`/`+ Бот (оборона)` buttons
  (`_setup_bot_spawn_buttons()`, calls `TeamSpawner.spawn_one_bot(team)`).
- `tank.gd` — the billboard `Label3D` "HP N/M" above each tank (`_setup_hp_label()`), refreshed on
  `damaged`/`destroyed`/`on_respawned()`. The team-colour mesh tint (`apply_team_visuals()`) is
  **not** gated — it always applies.
- `tank_ai_controller.gd._initialize()` — FOV-cone / nav-path / brain-panel overlays and the
  per-bot reaction-toggle button (setup **and** the `_physics_process` update calls, so the
  overlay meshes/labels are never touched when null).
- `spawn_zone.gd` — the on-ground debug circle. **Every circular area marker in the project is now
  this one script/one visual** (per-instance `@export radius`, movable/scalable in the editor, no
  separate hardcoded radius anywhere): spawn zones, ammo/mod drop-zone circles (`AmmoDropZone/
  DropArea` reuses this script), `ObjectiveAlertZone`, patrol waypoints (`Waypoint*`/
  `AttackWaypoint*`/`DefenseWaypoint*` on `TargetObjectiveMap.tscn`, each tagged with its
  `zone_role` — see "Патруль по вейпоинтам" in `tank_ai_controller.gd`'s header; a role no roster
  squad's `waypoint_routes` references is dead weight, delete it rather than leave it — see
  `Tank_Prop_Hunt_Map_Creation_Guide.md` §3.5), and the
  disguise-ambush `MortarHideZone1`/`MortarHideZone2` (see "Маскировка бота"
  below). Color by name prefix: `Attack*`/`Defense*` — red/blue; a bare `Waypoint*` (the defender's
  diamond, no team prefix in its name) is **also** blue, matching the old `_build_waypoint_debug()`
  convention of "not Attack → defense colour"; `MortarHide*` — purple; genuinely team-neutral zones
  (`ObjectiveAlertZone`/`DropArea`) — yellow. An **editor-time mirror** of the same rings (`addons/zone_gizmos/
  zone_gizmo_plugin.gd`, a `@tool` `EditorNode3DGizmoPlugin`) draws identical circles in the Godot
  viewport while placing/tuning a zone, reading the same `radius`/name convention — keep both in
  sync when touching either.

**RELEASE TODO (Steam / release prep):** the menu checkbox is a *development-stage* entry point —
it's in the normal player-facing menu. Before release, change how debug mode is entered: drop it
from the visible menu and gate it behind a command-line flag / dev build / debug export instead
(or strip it entirely). This note is duplicated in `MatchState.debug_enabled`'s doc-comment and in
a `project` memory — do not silently ship the visible checkbox.

### `scenes/tank/tank_ai_controller.gd` — the one universal bot brain (`TankAIController`)

Single AI system for the whole project — every map deploys the exact same node/script, not a
per-map or per-context system. Lives as a dormant sibling on every `Tank.tscn` instance (including
the player's, see "Tank as a composed entity" above) and lazily self-inits on first enabled
`_physics_process()` tick. A 15-state priority engine
(`IDLE/PATROL/DEFEND/HUNT/PURSUE/SEARCH/ATTACK_OBJECTIVE/ALERT/DEAD/AMMO_SEEK/AMMO_RETRIEVE/
AMMO_WAIT/MOD_SEEK/MOD_RETRIEVE/MORTAR_ATTACK`) with a NavMesh-based driving stack (pure
pursuit + emergency brake + stuck detector + gap-scan detour), two roles (`ACHIEVER`/`KILLER` —
`ACHIEVER` self-degrades to `KILLER` behavior at init if the map has no objective), three difficulty
tiers, and integrations with the shared
`RespawnController`/`HealthComponent`/`AmmoComponent`/`ModificationController` (death state,
alert-on-hit, ballistic aim, ammo-crate seeking, plus mortar pickup **and use** — attackers head
for a drop zone only in a 10 s window after a mortar drop (coordinating so two bots take different
zones; nothing there → straight back to normal) and lob at the objective while not seeking fights,
though a visible tank shooting them after the shot takes priority; defenders grab a seen crate and
lob at tanks; a low-ammo bot grabs a mortar if the zone has no ammo crate; full detail in
`Tank_Prop_Hunt_Modifications.md`). Objective/waypoint/ammo-zone lookups are group- or recursive-search based, not
name- or scene-structure-specific, so the same file works unmodified on any map. Bots don't activate
or seek disguise; `_can_see()` hides a `DISGUISED` enemy from *acquisition* but not from a bot
already fighting it (`ignore_disguise` param — see `DisguiseController` above and
`Tank_Prop_Hunt_Disguise.md`).

**Full architecture reference — states, priority ladder, driving-stack internals, per-tier
parameter tables, scene inventory — lives in the vault's Bot AI doc** (`Tank_Prop_Hunt_Bot_AI_Sandbox.md`),
not here; read it before non-trivial work on this file.

`scenes/maps/TeamArenaMap.tscn` is a separate scene (duplicated from `TargetObjectiveMap.tscn`)
purpose-built for testing the `KILLER` role — its roster sets `role: "KILLER"`, has more
`ObstacleN` bodies spread across the map (vs. `TargetObjectiveMap.tscn`'s single cluster on the
defense approach), and its own rebaked NavMesh. It has no objective node and runs the
**TEAM_ARENA** mode (see "Game modes" above). Launch it explicitly (`run_project` with
`scene: "res://scenes/maps/TeamArenaMap.tscn"`, or point `run/main_scene` at it) — it's not the
default scene, see below.

### Obstacle prefab system — `scenes/obstacles/` (universal, every map)

Map obstacles are **instances of two prefab scenes**, not hand-built `StaticBody3D` +
`CollisionShape3D` + `MeshInstance3D` triples inside each map `.tscn`:

- `Obstacle.tscn` (`obstacle.gd`, `@tool`, `extends StaticBody3D`) — any solid box: crate, block,
  or wall-cover. `@export size: Vector3` / `@export color: Color` drive the child `BoxShape3D` +
  `BoxMesh` + material in one place (defaults `2×1.25×2`, brown — matches `GameConfig.disguise_prop_*`).
  `collision_layer=1` / `collision_mask=0` baked into the prefab so the NavMesh baker still sees it.
  `TeamArenaMap.tscn`'s central `Wall` is just an instance with `size = 5.4×2.2×0.5` + grey; the
  identical wall was **removed from `TargetObjectiveMap.tscn`** (its centre is the relocated
  `Objective`).
- `HazardZone.tscn` (`hazard_zone.gd`, `@tool`, `extends Area3D`) — impassable area, `@export size`,
  fixed translucent-red material, `collision_layer=4`.

All three sub-resources in each prefab are `resource_local_to_scene = true` so per-instance
`size`/`color` don't bleed across instances. Nothing looks obstacles up by name. After
add/move/resize/delete the per-map NavMesh still needs a manual re-bake
(`Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md`).

### Map inventory

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` — a plain `Control` scene, two buttons, each
just calls `get_tree().change_scene_to_file()` at one of the maps below; carries no game logic of
its own. Launch either map directly via `run_project`'s `scene:` param (or repoint `run/main_scene`)
to skip the menu:

- `scenes/maps/TargetObjectiveMap.tscn` — TARGET_OBJECTIVE template: an `Objective` at the map
  centre `(0,1,0)` (no central wall), the `Waypoint1..4` defender diamond recentred on it
  (vertices at `±17` on each axis, so the r=12 `ObjectiveAlertZone` circle inscribes), one defense
  bot (`ACHIEVER`, patrols/defends around it) and one attack bot (`ACHIEVER`, one-way route to the
  objective), both `TankAIController`.
- `scenes/maps/TeamArenaMap.tscn` — TEAM_ARENA template: one `KILLER` bot roaming the whole map,
  described above.

An earlier, separate "production" map (`Main.tscn`/`Map.tscn`, a 5×5 proof-of-concept predating
stable bot behavior) was retired once these two became the real game-mode templates — recoverable
from `git log` if ever needed, not reused.

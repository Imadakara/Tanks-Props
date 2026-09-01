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
under the root (`tank.gd`, which only holds `team`/`is_attacker()`), each independently
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
- `DisguiseController` / `CollisionDetector` — slot occupancy and the "hit while disguised by a
  moving tank" trigger. **Currently orphaned everywhere**: neither map has `DisguiseSlot` props
  placed on it (the old, retired production map used to), and `TankAIController` has no
  disguise-seeking logic at all — the mechanic is implemented and player-usable, just not exercised
  by any current map or by bots. Accepted gap, not scheduled.
- `HealthComponent` — multi-hit (`max_hits`, **default 2**, restoring the "two hits to kill, red
  paint job after the first" rule as a project-wide default), reused verbatim for the destructible
  objective, not tank-specific. `attackers_only` lets an objective ignore friendly fire;
  `free_on_destroy=false` on tanks hands cleanup to `RespawnController` instead of freeing the node;
  `invincible` is a point override (see the debug toggle buttons under "Game modes"), not part of
  normal balance. The "red paint" on a non-fatal hit is `tank.gd._on_damaged()` (material swap on
  `HullMesh`/turret mesh).
- `RespawnController` — on death, disables the tank in place (hidden, colliders off,
  `process_mode = DISABLED` on every sibling except itself and `HealthComponent`) instead of
  freeing it, then teleports/resets it after `GameConfig.respawn_cooldown_sec`.
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
`TeamSpawner.spawn_team() → MatchManager.setup(...) → ScoreManager.begin_match()` in its own
`_ready()`, rather than letting each manager act in its own `_ready()`. Two reasons this matters
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
own `_ready()` precedes the root's; and a round-series score (`series_wins_you`/
`series_wins_enemy`, `total_rounds = 3`) tracked by *persistent* team (your team vs. the bots), not
by side. `MatchManager._end_round()` calls `MatchState.record_round_result(winner)` before emitting
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
`DefenseSpawnZone` at `(28,28)`/`(-28,-28)`, radius 8. Each zone also gets 3
`Attack/DefenseWaypointN` markers on a straight line toward the objective at 25/50/75% —
`TargetObjectiveMap.tscn`'s roster points its attack/defense squads' `waypoint_name_prefix` at
`AttackWaypointN` (one-way, ends in `ATTACK_OBJECTIVE`)/`WaypointN` (looping patrol — the defense
squad predates the corner-zone waypoint work and still uses its own older markers, see "Map
inventory"); the waypoint collector (`_collect_waypoints()`) searches the whole current scene
recursively, not just root-level children, so it stays correct regardless of tree depth.

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
this mode is `GameConfig.round_timer_sec` = **150 s (2:30)**. The `ObjectiveAlertZone` (the ground
circle the AI uses for `State.ALERT`) is a **child of the objective node** (local `y = -1` so the
circle sits on the ground), freed together with the objective and simply absent on maps without one
(`TeamArenaMap.tscn`); every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`.
**TEAM_ARENA** (`TeamArenaMap.tscn`, no objective node): 3-round team deathmatch,
`GameConfig.team_arena_round_sec` = 180 s / round, round winner by kill count (ties by
`defense_wins_ties`), match winner by rounds won. Sides here are **fixed colour teams** — **Красные**
(team 0) and **Синие** (team 1) — never "attack"/"defense"; the HUD `TeamLabel`, score line and
result screen all say Красные/Синие in this mode (in TARGET_OBJECTIVE they say Атака/Оборона).

`match_mode` is an `@export_enum` on each map root, **stored in the `.tscn`** (`TargetObjectiveMap`
= 0, `TeamArenaMap` = 1). A missing value silently defaults to `TARGET_OBJECTIVE` — that regression
(TeamArenaMap running as objective: no kill scoring, timeout always a defense win) is exactly what
happens if the property line is dropped from the scene file.

Both maps run the **same round loop**: `map_scene.gd._setup_match_context()` creates a `ScoreManager`
+ a node named `"MatchManager"` running `scenes/main/match_manager.gd`, which picks its end-of-round
condition from `match_mode` (objective `destroyed` → attack / timeout → defense, vs. timeout →
winner-by-kills) then `MatchState.record_round_result` → `round_ended`. The same script also owns a
**final stage**: if every tank's `AmmoComponent` reports `ammo_depleted` in the same round (nobody
can do anything more), it stops `RoundTimer`, starts a `FinalStageTimer`
(`GameConfig.final_stage_duration_sec` = 30s, HUD shows a countdown), and on timeout resolves the
round by kill count — the same formula either mode's normal timeout already uses, just triggered
early. Side-swap between rounds (`hud.gd._on_restart_pressed`, `_has_side_swap()`) happens **only in
TARGET_OBJECTIVE** (where attack/defense roles genuinely alternate); TEAM_ARENA colour teams are
fixed for the whole match, so its restart button just reloads.

The **round counter** is `MatchState.current_round_num`, a real stored field — **incremented by
`advance_round()` when the *next* round starts** (`_on_restart_pressed`), never when the current
one ends. So the result screen still reads "Раунд 1/3" for round 1's outcome; the top line only
becomes "Раунд 2/3" after the reload. `rounds_played()` (sum of series wins) is separate and used
for `series_complete()`. `reset_series()` also zeroes `current_round_num` and `player_team`.

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

The **HUD match block** (top-center, all maps, `hud.gd`): line 1 `Раунд N/M | MM:SS`
(N = `current_round_num`), line 2 the mode-dependent overall score — TARGET_OBJECTIVE: series only
(`По раундам — Ты N : M Противник`); TEAM_ARENA: round kills + series, all by colour
(`Убийства  Красные K : L Синие      Раунды  N : M`, Красные always the left number) — line 3
`Цель: N/M попаданий` — objective health, TARGET_OBJECTIVE only, resolved via
group `"objective_health"` (same group `TankAIController` reads, not by node name — no
`OBJECTIVE: TARGET` prefix, the mode name lives in the map settings, not the HUD), line 4 the
player respawn countdown (`Респаун через N с`, `RespawnLabel`) shown only while
`PlayerTank/RespawnController.time_until_respawn() > 0`. The HUD resolves `MatchManager`/
`RoundTimer`/`ScoreManager`/objective **lazily** and polls them, because `map_scene.gd` creates
those nodes in code *after* the HUD's own `_ready()`.

Player invincibility is a debug toggle button (`Игрок: бессмертие ON/OFF`, bottom-right, **default
ON**), same pattern as `Objective: ON/OFF` / bot reaction toggles. Both default-ON toggles were
tuned for iterating on bot behavior without player death/respawn getting in the way — worth
revisiting the *default* (not the toggle itself) now that these maps are the real game, not a
sandbox.

### `scenes/tank/tank_ai_controller.gd` — the one universal bot brain (`TankAIController`)

Single AI system for the whole project — every map deploys the exact same node/script, not a
per-map or per-context system. Lives as a dormant sibling on every `Tank.tscn` instance (including
the player's, see "Tank as a composed entity" above) and lazily self-inits on first enabled
`_physics_process()` tick. A 12-state priority engine
(`IDLE/PATROL/DEFEND/HUNT/PURSUE/SEARCH/ATTACK_OBJECTIVE/ALERT/DEAD/AMMO_SEEK/AMMO_RETRIEVE/
AMMO_WAIT`) with a NavMesh-based driving stack (pure pursuit + emergency brake + stuck detector +
gap-scan detour), two roles (`ACHIEVER`/`KILLER` — `ACHIEVER` self-degrades to `KILLER` behavior at
init if the map has no objective), three difficulty tiers, and integrations with the shared
`RespawnController`/`HealthComponent`/`AmmoComponent` (death state, alert-on-hit, ballistic aim,
ammo-crate seeking). Objective/waypoint/ammo-zone lookups are group- or recursive-search based, not
name- or scene-structure-specific, so the same file works unmodified on any map. Known accepted
gap: no disguise-seeking logic (see `DisguiseController` above).

**Full architecture reference — states, priority ladder, driving-stack internals, per-tier
parameter tables, scene inventory — lives in the vault's Bot AI doc** (`Tank_Prop_Hunt_Bot_AI_Sandbox.md`),
not here; read it before non-trivial work on this file.

`scenes/maps/TeamArenaMap.tscn` is a separate scene (duplicated from `TargetObjectiveMap.tscn`)
purpose-built for testing the `KILLER` role — its roster sets `role: "KILLER"`, has 6 extra
`ObstacleN` static bodies spread across the map (vs. `TargetObjectiveMap.tscn`'s single cluster
near the objective), and its own rebaked NavMesh. It has no objective node and runs the
**TEAM_ARENA** mode (see "Game modes" above). Launch it explicitly (`run_project` with
`scene: "res://scenes/maps/TeamArenaMap.tscn"`, or point `run/main_scene` at it) — it's not the
default scene, see below.

### Map inventory

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` — a plain `Control` scene, two buttons, each
just calls `get_tree().change_scene_to_file()` at one of the maps below; carries no game logic of
its own. Launch either map directly via `run_project`'s `scene:` param (or repoint `run/main_scene`)
to skip the menu:

- `scenes/maps/TargetObjectiveMap.tscn` — TARGET_OBJECTIVE template: an `Objective`, one defense
  bot (`ACHIEVER`, patrols/defends around it) and one attack bot (`ACHIEVER`, one-way route to the
  objective), both `TankAIController`.
- `scenes/maps/TeamArenaMap.tscn` — TEAM_ARENA template: one `KILLER` bot roaming the whole map,
  described above.

An earlier, separate "production" map (`Main.tscn`/`Map.tscn`, a 5×5 proof-of-concept predating
stable bot behavior) was retired once these two became the real game-mode templates — recoverable
from `git log` if ever needed, not reused.

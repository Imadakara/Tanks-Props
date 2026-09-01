# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Tank Prop Hunt — a team tactical shooter with prop-hunt elements (disguise mechanic), Godot 4.7
(GDScript), 3D, Jolt physics. Local prototype vs bots, no networking.

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
  production and both test arenas alike: states/driving stack/params.
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
plain three-button launcher (by request), not any of the actual game/test scenes directly. Pick one
from there, or see "Map inventory" further down and point `run/main_scene` at a specific scene (or
pass `scene:` to `run_project`) to skip the menu when iterating on one map.

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
  via the bot-AI sandbox's obstacle-avoidance work (see the Bot AI Sandbox vault doc) when the bot
  visibly skidded sideways brushing a corner — same underlying `move_and_slide()` behavior applies to
  the player too, just less obvious since a human steers away from corners instinctively.
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
  `request_fire()` rather than cached in `_ready()` — a scene can override
  `GameConfig.reload_duration_sec` at its own root's `_ready()`, which Godot always runs *after*
  every child (including this state machine) is already ready, so caching would use a stale value.
- `DisguiseController` / `CollisionDetector` — slot occupancy and the "hit while disguised by a
  moving tank" trigger.
- `HealthComponent` — multi-hit (`max_hits`, **default 2** — by request, restoring the "two hits to
  kill, red paint job after the first" rule as a project-wide default, not just a per-scene config
  value), reused verbatim for the destructible objective, not tank-specific. `attackers_only` lets
  an objective ignore friendly fire; `free_on_destroy=false` on tanks hands cleanup to
  `RespawnController` instead of freeing the node; `invincible` is a point override for test scenes
  (see bot arena below), not part of normal balance. The "red paint" on a non-fatal hit is
  `tank.gd._on_damaged()` (material swap on `HullMesh`/turret mesh) — that logic was never missing,
  it just never got to fire while the default was 1 (instant kill, no non-fatal hit to paint red).
  Production (`team_spawner.gd`) already overrode this from `config/*_tank_config.json`
  (`max_hits: 2` there too) — raising the component's own default doesn't change production
  behavior, it just stops the bot-arena test scenes (`BotArena.tscn`/`KillerArena.tscn`, whose tanks
  are static `.tscn` instances that never go through `team_spawner.gd`) from silently reverting to
  one-hit-kill.
- `RespawnController` — on death, disables the tank in place (hidden, colliders off,
  `process_mode = DISABLED` on every sibling except itself and `HealthComponent`) instead of
  freeing it, then teleports/resets it after `GameConfig.respawn_cooldown_sec`.
- `TankAIController` — the single AI brain for the whole project (production and both test arenas
  alike, not a separate per-context system). Present on every `Tank.tscn` instance but inert
  (`enabled=false`) unless a spawner/scene turns it on; when enabled it flips every sibling's
  `is_player_controlled` to `false` and drives them through the same public contract the player
  uses (`ai_move_input`, `target_yaw`, `try_fire()`) — no duplicated movement/combat logic path for
  bots vs. player. States, roles, driving stack, ammo states: see the Bot AI vault doc.

Because every component gates on `is_player_controlled` independently and defaults to `true`,
spawning a second player-controlled-by-default tank without flipping that flag first means it
reads the same `Input`/keyboard as the real player. Always disable it (and hand off camera
activity, see below) before the instance is meaningfully alive in the tree.

### Scene bring-up ordering

`Main._ready()` (`scenes/main/main.gd`) explicitly sequences
`TeamSpawner.spawn_team() → MatchManager.begin_match() → ScoreManager.begin_match()` rather than
letting each manager act in its own `_ready()`. Two reasons this matters when adding new
per-match setup code: (1) `add_child()` on `current_scene` from *inside* a sibling's own `_ready()`
fails ("Parent node is busy setting up children") — the tree is still being built; the root's
`_ready()` runs last, after all declared children, so it's the safe place. (2) Managers that scan
the `"tanks"` group (`ScoreManager`, `MatchManager`) must run after spawning, not before.

Corollary that has bitten this repo twice: a node whose own `_ready()` reads a value another
sibling's `_ready()` is meant to set (e.g. HUD reading `tank.team` before `TeamSpawner` assigns it)
gets the stale default, because sibling `_ready()` order isn't the fix — reading from an autoload
that's set up before scene load (`MatchState`) is. Prefer that over reordering nodes when a value
needs to be correct *during* `_ready()`.

A related ordering pitfall specific to cameras: an about-to-be-activated bot's `CameraRig` also
defaults `is_active = true` and steals `Camera3D.current` the instant it enters the tree, inside
`CameraRig._ready()`. `team_spawner.gd` sets `is_active = false` on the orphaned instance *before*
`add_child()` to avoid a one-frame flicker; when a bot is instead added as a static node inside a
hand-built `.tscn` (no runtime `instantiate()`/`add_child()` step to intervene in), the fix instead
has to happen later — `TankAIController._initialize()` explicitly re-asserts `camera.current =
false`, which works regardless of sibling order since it only runs on the first `_physics_process()`
tick, well after every sibling's `_ready()` including `CameraRig`'s.

### Autoloads and per-tank config

`GameConfig` (balance knobs shared project-wide) and `MatchState` (survives
`get_tree().reload_current_scene()`, where ordinary `@export` fields on scene nodes don't).
`MatchState` now holds: `player_team: int` (the player's *side* this round, flipped by the HUD
restart button only when the scene has a `TeamSpawner`); `match_mode: Mode {TARGET_OBJECTIVE,
TEAM_ARENA}` — a **per-map setting**, not runtime detection: `main.gd` sets `TARGET_OBJECTIVE`;
`bot_arena.gd` has `@export_enum var match_mode` set in each scene file (`BotArena.tscn` = 0,
`KillerArena.tscn` = 1); the HUD reads it *lazily* since its own `_ready()` precedes the root's;
and a round-series score (`series_wins_you`/`series_wins_enemy`, `total_rounds = 3`) tracked by
*persistent* team (your team vs. the bots), not by side.
`MatchManager._end_round()` calls `MatchState.record_round_result(winner)` before emitting
`round_ended`; the series accumulates across `reload_current_scene()` and is reset only from the
main menu (`main_menu.gd`) or the "Новый матч" button after `series_complete()`. `config/player_tank_config.json` and
`config/bot_tank_config.json` hold per-profile physical stats (speed, turret turn rate, projectile
speed, `max_hits`) read once by `team_spawner.gd` — these are tank-profile data, not match balance,
which is why they're JSON next to `GameConfig` rather than fields on it.

### Spawn system — `SpawnZone` (unified across all maps, by request)

Every map (`Main.tscn`/`Map.tscn`, `BotArena.tscn`, `KillerArena.tscn`) now spawns and respawns
tanks the same way: `scenes/main/spawn_zone.gd` is a `Node3D` marking a circular area (`radius`,
`@export`) — team is encoded by node-name prefix, not a separate field, the same convention as
`Waypoint`/`AttackWaypoint` and the old `AttackSpawnPoint`/`DefenseSpawnPoint` markers it replaces
(`"AttackSpawnZone"` / `"DefenseSpawnZone"`). `pick_spawn_position()` picks a uniform-by-area random
point inside the circle (`sqrt(randf())`, not `randf()` — same technique as
`tank_ai_controller.gd`'s `_pick_random_point_near()`) and raycasts straight down
(`collision_mask = 1`, "environment") to find the actual ground surface under it, retrying up to
`max_attempts` times before giving up and returning the zone's own center as a deterministic
fallback. It also draws its own debug circle (`ImmediateMesh`, red for `Attack*`/blue for
`Defense*`/yellow otherwise) so a screenshot can confirm placement without guessing. Every caller
adds a small clearance on top (`Vector3(0, 0.3, 0)`) — spawning exactly on the raycast-hit y gives a
degenerate zero-depth floor contact that Jolt handles badly (`move_and_slide()` drops the body
through the floor instead of settling); a small gap lets it settle naturally over a few frames, same
fix already used for the player's original hardcoded spawn.

Three call sites, all funneling through the same `pick_spawn_position()`:
- `team_spawner.gd` (production, `Main.tscn`) — finds both zones once via
  `get_tree().current_scene.find_child(name, true, false)` (recursive — the zones live under `Map`
  on the production tree, unlike the two sandbox arenas below, which have no `Map` node at all) and
  gives every tank on a team, **including the player** (by request — "player spawns by the same
  rules as the bots"), its own independent random point.
- `respawn_controller.gd` — same recursive `find_child` lookup, called from `_on_respawn_timeout()`;
  replaces the old fixed-point-array pick. Works unmodified on the sandbox arenas too since it's
  scene-structure-agnostic.
- `bot_arena.gd` — the two sandbox arenas have no `TeamSpawner` (tanks are static `.tscn` children,
  not dynamically instanced), so `_spawn_from_zones()` (called once from `_ready()`) does the
  equivalent by hand: loop over the known tank node names, skip whichever aren't present with
  `get_node_or_null` (this script is shared between `BotArena.tscn`, which has `AttackBotTank`, and
  `KillerArena.tscn`, which doesn't — a hard `get_node` here crashed `_ready()` on `KillerArena.tscn`
  before this was caught live), route each to its zone by `tank.team`.

Zones default to opposite corners of the map (by request) — production `Map.tscn`:
`AttackSpawnZone` at `(-24,-24)`, `DefenseSpawnZone` at `(24,24)`, radius 7 (covers the old 5-point
clusters' ~5-unit spread with margin); both sandbox arenas (72×72): `(28,28)`/`(-28,-28)`, radius 8.
Each zone also gets 3 `Attack/DefenseWaypointN` markers on a straight line toward the objective at
25/50/75% — `team_spawner.gd` wires every production bot's `TankAIController.waypoint_name_prefix`
to `AttackWaypointN` (one-way, ends in `ATTACK_OBJECTIVE`) or `DefenseWaypointN` (looping patrol)
by team; the waypoint collector (`_collect_waypoints()`) searches the whole current scene
recursively, not just root-level children, specifically so it still finds them one level deeper
under `Map` on production. `BotArena.tscn`'s static `AttackBotTank` reuses the same
`AttackWaypointN` markers (`waypoint_name_prefix` set directly in the scene file), but its
defense `BotTank` keeps its own older `WaypointN` markers instead — `DefenseWaypointN` on that map
is decorative only, nothing points its prefix there.

`SpawnZone.face_center(tank)` (static, called via a `preload()`'d script reference — **not**
`class_name`: headless `run_project` doesn't pick up a freshly-added `class_name` without an editor
rescan, same gotcha as new files with `class_name` in general) orients the tank's forward
(`-basis.z`, confirmed against `tank_movement.gd`'s own forward convention) toward the map's XZ
origin right after every spawn/respawn — all three maps have their `Ground` centered at world
`(0,0)`, so "map center" never needs computing per-map. `look_at()` targets the tank's *own* Y (not
world 0) specifically to keep pitch/roll at zero on flat ground; a degenerate near-origin spawn
(distance < 0.01) is a no-op rather than an undefined `look_at()`.

Confirmed live on all three maps via `run_script`: repeated `pick_spawn_position()` calls
land inside each zone's radius on real ground; a forced destroy→timeout cycle on both a production
bot and a sandbox bot respawns it, fully reset, inside its own team's zone.

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

Two modes, keyed off `MatchState.match_mode` (see Autoloads above). **TARGET_OBJECTIVE**
("Destroy Target", `Main.tscn` + `BotArena.tscn`): a `DestructibleObjective` static body with a
`HealthComponent` (`attackers_only = true`) sits on the map; **objective destroyed → round ends
with an attack win; round timer expires with it intact → defense win**. Round timer for this mode
is `GameConfig.round_timer_sec` = **150 s (2:30)**. An earlier "Capture Zone" mode
(continuous-presence timer) was replaced and its code deleted — reimplement from the vault dev-plan
if ever needed. The `ObjectiveAlertZone` (the ground circle the sentry AI uses for `State.ALERT`)
is a **child of the objective node** on every map (local `y = -1` so the circle sits on the
ground), freed together with the objective and simply absent on maps without one (`KillerArena`);
every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`.
**TEAM_ARENA** (`KillerArena.tscn`, no objective node): 3-round team deathmatch,
`GameConfig.team_arena_round_sec` = 180 s / round, round winner by kill count (ties by
`defense_wins_ties`), match winner by rounds won.

Both bot arenas run the **same synthesized round loop**: `bot_arena.gd._setup_match_context()`
creates a node named `MatchManager` running `scenes/bot_arena/arena_match.gd`, which picks its
end-of-round condition from `match_mode` (objective `destroyed` → attack / timeout → defense, vs.
timeout → winner-by-kills) then `MatchState.record_round_result` → `round_ended`. Production
`match_manager.gd` (bound to `Map`/objective/final-stage) already does the objective-mode
conditions itself and is left alone. Side-swap between rounds (`hud.gd._on_restart_pressed`,
`_has_side_swap()`) happens only when the scene has a `TeamSpawner` (production only) — arena tanks
are static instances with fixed teams, so their restart button just reloads.

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
`Area3D.body_entered` → `AmmoComponent.add_ammo` (player and bots alike; bots don't path to
crates). The old field-wide `match_manager.gd` crate spawner (`CrateSpawnTimer`) was removed.
Full detail: `Tank_Prop_Hunt_Ammo_Drops.md`.

The **HUD match block** (top-center, all maps, `hud.gd`): line 1 `Раунд N/M | MM:SS`, line 2 the
mode-dependent overall score (series only for TARGET_OBJECTIVE; round kills + series for
TEAM_ARENA), line 3 `Цель: N/M попаданий` — objective health, TARGET_OBJECTIVE only, resolved
lazily via `find_child("DestructibleObjective")`/`"Objective"` (no `OBJECTIVE: TARGET` prefix — the
mode name lives in the map settings, not the HUD), line 4 the player respawn countdown
(`Респаун через N с`, `RespawnLabel`) shown only while
`PlayerTank/RespawnController.time_until_respawn() > 0`. The HUD resolves `MatchManager` /
`RoundTimer` / `ScoreManager` / objective **lazily** and polls them, because the bot arenas
synthesize those nodes in code *after* the HUD's own `_ready()` — so everything resolves by the
same node names everywhere.

Player invincibility on the bot arenas is now a debug toggle button (`Игрок: бессмертие ON/OFF`,
bottom-right, **default ON**), same pattern as `Objective: ON/OFF` / bot reaction toggles — not the
old hardcoded `_ready()` line.

### `scenes/tank/tank_ai_controller.gd` — the one universal bot brain (`TankAIController`)

Single AI system for the whole project — production (`Main.tscn`/`Map.tscn`, spawned dynamically by
`team_spawner.gd`) and both test arenas (`BotArena.tscn`/`KillerArena.tscn`, static `.tscn`
instances with `enabled = true` set directly in the scene file) all deploy the exact same node/
script, not separate per-context AI systems. Lives as a dormant sibling on every `Tank.tscn`
instance (including the player's, see "Tank as a composed entity" above) and lazily self-inits on
first enabled `_physics_process()` tick. A 12-state priority engine
(`IDLE/PATROL/DEFEND/HUNT/PURSUE/SEARCH/ATTACK_OBJECTIVE/ALERT/DEAD/AMMO_SEEK/AMMO_RETRIEVE/
AMMO_WAIT`) with a NavMesh-based driving stack (pure pursuit + emergency brake + stuck detector +
gap-scan detour), two roles (`ACHIEVER`/`KILLER` — `ACHIEVER` self-degrades to `KILLER` behavior at
init if the map has no objective), three difficulty tiers, and integrations with the shared
`RespawnController`/`HealthComponent`/`AmmoComponent` (death state, alert-on-hit, ballistic aim,
ammo-crate seeking). Objective/waypoint/ammo-zone lookups are group- or recursive-search based, not
name- or scene-structure-specific, so the same file works unmodified on any map.

Known accepted gap: no disguise-seeking logic — `PatrolWaypointN`/`DisguiseSlotN` markers on
`Map.tscn` are AI-orphaned (the mechanic itself is still player-usable).

**Full architecture reference — states, priority ladder, driving-stack internals, per-tier
parameter tables, scene inventory — lives in the vault's Bot AI doc** (`Tank_Prop_Hunt_Bot_AI_Sandbox.md`),
not here; read it before non-trivial work on this file.

`scenes/bot_arena/KillerArena.tscn` is a separate scene (duplicated from `BotArena.tscn`) purpose-
built for testing the `KILLER` role — its `TankAIController.role` is set to `KILLER` in the scene
file itself, has 6 extra `ObstacleN` static bodies spread across the map (vs. `BotArena.tscn`'s
single cluster near the objective), and its own rebaked NavMesh. Its objective node was removed and
it now runs the **TEAM_ARENA** mode (see "Game modes" above): a full 3-round loop via a code-
synthesized `MatchManager` (`scenes/bot_arena/arena_match.gd`). Launch it explicitly (`run_project`
with `scene: "res://scenes/bot_arena/KillerArena.tscn"`, or point `run/main_scene` at it) — it's not
the default scene, see below.

### Map inventory (by request — the project now has four distinct scenes, don't confuse them)

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` (by request) — a plain `Control` scene, three
buttons, each just calls `get_tree().change_scene_to_file()` at one of the scenes below; carries no
game logic of its own. The other three are unchanged, just no longer the default — launch any of
them directly via `run_project`'s `scene:` param (or repoint `run/main_scene`) to skip the menu:

- `scenes/main/Main.tscn` — the actual production game: 5×5, two teams, `Objective`/`MatchManager`,
  bots driven by `TankAIController` (same brain as the two test arenas below).
- `scenes/bot_arena/BotArena.tscn` — small-scale test map with an `Objective` and an ACHIEVER test
  bot (patrols/defends around it), same `TankAIController`.
- `scenes/bot_arena/KillerArena.tscn` — test map for the KILLER role + TEAM_ARENA mode (3-round
  team deathmatch loop), described above.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Tank Prop Hunt — a team tactical shooter with prop-hunt elements (disguise mechanic), Godot 4.7
(GDScript), 3D, Jolt physics. Local prototype vs bots, no networking.

Full design docs (concept, spec/ТЗ, dev plan with per-stage implementation history and gotchas,
and the bot-AI-sandbox doc for the `Bot` branch) live outside this repo, in
`C:\Users\PC\Documents\Personal Vault\Tank Props Docs\`. Code comments frequently say "see vault" —
that's this folder, not anything inside the repo. Read the relevant vault doc before doing
non-trivial work on a system it covers (game modes, AI, dev history) — it records *why*, not just
what the code does, including reasoning behind changes that were tried and reverted.

## Running / testing

No build step (GDScript is interpreted) and no automated test suite exists in this repo. Verify
changes by actually running the project — normally through the `godot-runtime` MCP server
(`run_project` with `background: true`, then `get_debug_output` immediately to catch script/scene
errors, then `run_script`/`take_screenshot`/`simulate_input` to drive and inspect a live session,
then `stop_project`). See the `godot-mcp-testing` skill for the full tool catalog and known
gotchas of that MCP server; don't rediscover them by trial and error.

`res://scenes/bot_arena/bot_sentry_controller.gd` has no counterpart in a formal test suite either
— its correctness is established the same way (live `run_script` assertions on state, not manual
play).

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
- `TankAIController` — the production bot brain (Patrol/Hold, Disguise, Observe, Attack). Present
  on every `Tank.tscn` instance but inert (`enabled=false`) unless a spawner turns it on; when
  enabled it flips every sibling's `is_player_controlled` to `false` and drives them through the
  same public contract the player uses (`ai_move_input`, `target_yaw`, `try_fire()`,
  `try_enter_disguise()`) — no duplicated movement/combat logic path for bots vs. player.

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
has to be a later sibling's `_ready()` explicitly re-asserting `camera.current = false` (see the
bot arena sandbox's `BotSentryController`, which is deliberately the last child so its `_ready()`
runs after `CameraRig`'s).

### Autoloads and per-tank config

`GameConfig` (balance knobs shared project-wide) and `MatchState` (currently just
`player_team: int`, exists solely because it must survive `get_tree().reload_current_scene()` —
ordinary `@export` fields on scene nodes don't). `config/player_tank_config.json` and
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
`bot_sentry_controller.gd`'s `_pick_random_point_near()`) and raycasts straight down
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
Each zone also gets 3 purely decorative `Attack/DefenseWaypointN` markers on a straight line toward
the objective at 25/50/75% — **not** wired into any AI controller (`tank_ai_controller.gd` untouched,
`bot_sentry_controller.gd`'s waypoint collector only reacts to the exact prefix it's configured
with) — except on `BotArena.tscn`, where `AttackWaypointN` **is** the live route the ATTACK
`AttackBotTank` already drives (see below); those 3 were recomputed here to actually originate from
the new corner zone instead of the old off-corner hardcoded spawn.

`SpawnZone.face_center(tank)` (static, called via a `preload()`'d script reference — **not**
`class_name`: headless `run_project` doesn't pick up a freshly-added `class_name` without an editor
rescan, same gotcha as new files with `class_name` in general) orients the tank's forward
(`-basis.z`, confirmed against `tank_movement.gd`'s own forward convention) toward the map's XZ
origin right after every spawn/respawn — all three maps have their `Ground` centered at world
`(0,0)`, so "map center" never needs computing per-map. `look_at()` targets the tank's *own* Y (not
world 0) specifically to keep pitch/roll at zero on flat ground; a degenerate near-origin spawn
(distance < 0.01) is a no-op rather than an undefined `look_at()`.

Deliberately out of scope for this pass (production combat AI, `tank_ai_controller.gd`, was never
touched): the spawn *mechanism* is now uniform everywhere, but nothing routes production bots along
the new production-map waypoints — they still patrol/hold from one shared shuffled pool exactly as
before. Confirmed live on all three maps via `run_script`: repeated `pick_spawn_position()` calls
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

### Current objective mode

The active win condition is "Destroy Target": a `DestructibleObjective` static body with a
`HealthComponent` (`attackers_only = true`) sits on the map; attackers win by destroying it,
defenders win if the round timer expires first. An earlier "Capture Zone" mode (continuous-presence
timer) was replaced and its code deleted — if that mechanic is ever needed again, it has to be
reimplemented from the vault dev-plan's description, not recovered from history-lite refactoring.

### `scenes/bot_arena/` — isolated bot-AI sandbox (branch `Bot`)

A second, self-contained map + AI controller (`BotArena.tscn` / `bot_sentry_controller.gd`),
deliberately kept separate from `TankAIController` so bot-behavior experiments can't destabilize
the production 5×5 flow. It reuses `Tank.tscn` and the shared components above unchanged, but
replaces the AI brain with its own priority-ordered state engine (role → home behavior, overridden
by "target currently visible" every think-tick) and a from-scratch "vision as an independent
camera" model — see the vault's Bot AI Sandbox doc for the full design, its iteration history, and
a list of found-but-not-yet-ported-to-production bugs (notably: `TankAIController._drive_toward()`
likely has an inverted turn-direction sign, found and fixed only in this sandbox's copy of the same
formula).

Obstacle avoidance is NavMesh-based (`NavigationRegion3D` + `NavigationAgent3D`), not raycasts — an
earlier reactive raycast/"lidar" version was fully retired after diminishing returns (each fix to a
corner-case oscillation opened a new one) and replaced with the standard NavMesh + A* approach; see
the vault doc §12 for the switch (and §11, kept as an archived history of the raycast era, since
`bot_sentry_controller.gd` no longer matches it). `agent_radius` on the baked mesh must exceed the
tank hull's half-diagonal (not just its half-width) or the path clips corners on turns.

NavMesh only knows the STATIC map — it has no idea a player tank is parked across the route. Layered
on top, purely for that dynamic case (never for steering choice, which stays NavMesh's job): pure
pursuit path-following (§12.6, lookahead projected onto the path, not the nearest vertex — a vertex-
anchored lookahead has a self-stalling equilibrium, found live), a short-range 3-ray emergency brake
that only halts (§12.6-12.7), a windowed-displacement stuck detector (instant velocity is fooled by
Jolt corner-contact jitter, §12.6), and — when actually stuck — a reverse followed by a gap-scan
detour (~17-ray fan, steers into the widest genuinely open gap, not a fixed ±angle guess that can
loop forever retrying the same wrong direction, §12.9) that forces `NavigationAgent3D.target_position`
to reassign itself afterward (confirmed live: Godot does **not** repath on its own just because the
agent moved — reassigning `target_position`, even to the same value, is what forces a fresh query,
§12.8). A runtime on-screen toggle (`enemy_reaction_enabled` on `BotSentryController`) lets the player
disable target-seeking/combat for testing while leaving this avoidance stack fully active — the bot
still treats the player as a physical obstacle either way. Vault doc §12.6-12.9 has the full
diagnostic history (each is a "tried X, live-tested, found a regression, dial it back" cycle — read
before changing any of `emergency_brake_*`/`stuck_*`/`nav_lookahead_distance`, the current numbers
are not arbitrary).

Both roles (`Role.ACHIEVER`/`Role.KILLER`) are fully implemented (vault doc §14). ACHIEVER's home
behavior is `PATROL` (fixed waypoints around the objective); KILLER's is `HUNT` — same driving stack,
random points across a rectangular area auto-detected from the `Ground` node's `BoxShape3D` AABB at
`_ready()` (no per-map hardcoding needed) — and on losing sight of a target it goes to `PURSUE` (the
last position it was actually SEEN at, not just its last known node position — those differ by up to
one `think_interval_sec`, which mattered enough to be a live-found bug, §14.3), then `SEARCH` (a
probabilistic sequence of a few MOVE/LOOK attempts near where the target was lost — by request, "don't
immediately give up and go back to scanning the whole map" — tuned for MEDIUM only right now, see
§14.8 for the exact probabilities and the ambiguity calls made turning the request into code) before
finally falling back to `HUNT`. The whole driving stack (NavMesh/pure pursuit/brake/stuck-detector/
gap-scan-detour) is shared across `PATROL`/`HUNT`/`PURSUE`/`SEARCH` through one parameterized
`_drive_to_point(delta, target_pos, reach_dist)` — don't reimplement it per-state. The test bot on
`BotArena.tscn` defaults to ACHIEVER; switching to KILLER for testing is manual (`role =
Role.KILLER`, inspector or script), not a scene toggle.

`BotArena.tscn` now has TWO ACHIEVER bots (by request) — `BotTank` (DEFENSE, unchanged: patrols
`WaypointN` in an infinite loop around the objective) and `AttackBotTank` (ATTACK, new): drives
`AttackWaypointN` (1→2→3) ONCE, then switches to `State.ATTACK_OBJECTIVE` — parks and fires at the
`Objective` node itself (found once in `_ready()`, same recursive-`find_child` pattern as the `Ground`
lookup for KILLER's hunt area) until it's destroyed, then sits in `IDLE` for good (a
`_objective_mission_complete` flag stops `_ensure_home_state()` from restarting the same one-way
route). Two per-instance knobs make this possible without the bots stepping on each other:
`waypoint_name_prefix` (which node-name prefix `_collect_waypoints()` matches — `"Waypoint"` for
defense, `"AttackWaypoint"` for attack, so neither bot picks up the other's markers) and
`waypoints_one_way` (false = old infinite patrol loop, true = drive the list once then hand off to
`ATTACK_OBJECTIVE`). Confirmed live end-to-end from a fresh scene load: `AttackBotTank` drove clear
across the map, reached `ATTACK_OBJECTIVE`, and the `Objective` node was gone (destroyed, `state`
settled on `IDLE`) with no manual intervention. Having two bots on one scene also surfaced a debug-UI
bug worth knowing about: the brain-debug label and the reaction-toggle button are both anchored to a
fixed screen position — with two bots showing them, they render on top of each other, unreadable.
Fixed with a per-instance `debug_ui_slot: int` (0 = old position, unused = don't touch the existing
defense bot's `.tscn` value) that offsets each bot's widgets down/up by one slot height, plus the bot's
node name baked into both the widget names (`click_element` resolves by name — same name on two bots
would hit whichever one it finds first) and their visible text.

**DEFEND deadlock fix (by request, live-found via screenshot):** `vision_range` (10.0 MEDIUM) is
wider than `fire_range` (8.0) by design — a target can be *seen* (triggering `DEFEND`) while still
out of *firing* range. `DEFEND` used to hard-zero movement unconditionally, so two bots that spotted
each other in that gap froze forever, aiming and never firing (never approaching either — nothing
else in `DEFEND` moves them). Fixed in `_enter_defend()`/`State.DEFEND` (`_physics_process()`):
while `dist > fire_range`, drive toward the target via the same `_drive_to_point()` NavMesh stack
everything else uses (reach_dist = `fire_range * 0.85`, a margin so it actually lands inside the
radius instead of hovering on the boundary); only stop and pure-aim once inside. `_nav_agent.target_position`
is refreshed once per think-tick (inside `_enter_defend()`, which already re-fires every tick the
target stays visible) rather than every physics frame — plenty for a 1v1 fight, and avoids forcing a
NavMesh repath 60×/sec for no benefit.

**Three follow-on bugs the deadlock fix exposed (by request, all fixed live):** approaching a target
enabled code paths that previously never ran long enough to matter. (1) A killed tank isn't freed
(`free_on_destroy=false`, it respawns) — `RespawnController` just hides it (`visible=false`), so
`is_instance_valid()` stayed true and the corpse's disabled collider made `_can_see()`'s raycast find
nothing (treated as "unobstructed") — bots kept firing at a dead tank's last position forever.
`_can_see(target)` now starts with `if not target.visible: return false`. (2) `State.ATTACK_OBJECTIVE`
had the same stop-and-aim-only bug as `DEFEND` did before this fix — the last `AttackWaypoint`'s
distance to the objective on this map is ~14m, over `fire_range` (8.0), so the attacking bot froze at
the end of its route forever, never approaching. Fixed the same way (`_drive_to_point()` when too
far), plus `_advance_waypoint()` now explicitly points `_nav_agent.target_position` at the objective
the moment it transitions into `ATTACK_OBJECTIVE` (previously left pointing at the last waypoint).
(3) After winning a fight, the defending bot span in place instead of resuming its patrol route — the
same `_has_hunt_target`-class staleness bug already documented once for KILLER/PURSUE→HUNT, now hit
by ACHIEVER/PATROL because `DEFEND`'s approach logic (from this same fix) overwrites
`_nav_agent.target_position` mid-patrol; `_on_target_lost()` now unconditionally resets
`_has_waypoint_target = false` too (previously only `_has_hunt_target`, inside the KILLER branch), so
`_drive_to_waypoint()` picks a fresh point and reassigns the nav target instead of trusting a stale one.

**Ballistic aiming (by request).** Bots used to aim by yaw only — `BarrelController.target_pitch`
was never touched by AI (stayed 0.0, gun always level) even though the projectile physically falls
under gravity (`projectile.gd`, kinematic integration, not raycast) — shots simply undershot at any
real distance. `_compute_ballistic_pitch(dist_xz, height_diff)` solves the standard projectile
equation as a quadratic in `tanθ`, picks the LOW-arc root (flat cannon shot, not a mortar lob), and
`_aim_and_fire()` now gates `try_fire()` on BOTH yaw and pitch tolerance being satisfied. Aiming
targets `target.global_position + _aim_offset` — a small random offset sized from the tank's actual
hull `CollisionShape3D` (`Vector3(1.2, 0.6, 1.8)`) so the shot always lands inside the hitbox, never
dead-center every time; the offset is rolled ONCE per targeting bout (`_reroll_aim_offset()`, called
from `_enter_defend()` only on a NEW target and once on entering `ATTACK_OBJECTIVE`), not every
frame — re-rolling continuously would make the aim angles jitter and never settle inside tolerance.
Confirmed live: a forced shot at a known distance actually connected (target's `current_hits` went
up), and a full unforced fight on `BotArena.tscn` showed real hits both ways with the barrel visibly
elevated. The "turn turret toward whoever just hit you" reaction (`_on_damaged()`) was *already*
implemented correctly — verified live rather than re-adding it.

`AttackBotTank`'s marching-to-objective phase gets a per-instance `forward_look_bias=0.8` override
(vs. the script's global default 0.7, still used by the defense patrol/KILLER hunt) — 80% forward-
biased turret wander, 20% full 360°, same underlying mechanism as the default, just tuned per this
one bot via the `.tscn`, not a script change.

**`OBJECTIVE: TARGET` label + invincibility toggle (test-only, both sandbox arenas).** `hud.gd`
looks up the objective via the hardcoded path `"Map/DestructibleObjective/HealthComponent"` —
production-only (`Map.tscn` lives under "Map"); on these two arenas there's no "Map" node at all
(Objective sits directly under `NavigationRegion3D`), so `ObjectiveLabel` silently stuck on its
default "Objective: --" text the whole time (not a `hud.gd` bug per se — correct on `Main.tscn`,
just not arena-agnostic). Rather than touch the shared `hud.gd`/`HUD.tscn`, `bot_arena.gd` (already
shared by both arenas) finds the objective itself via the same recursive `find_child("Objective",
true, false)` pattern `bot_sentry_controller.gd` already uses for `ATTACK_OBJECTIVE`, and overwrites
`$HUD/ObjectiveLabel.text` with `"OBJECTIVE: TARGET — X/Y попаданий"` — naming the objective mode
explicitly (there used to be a different one, Capture Zone, since removed — see "Current objective
mode" above) while also fixing the broken counter. A programmatically-built toggle button (same
pattern as `bot_sentry_controller.gd`'s reaction-toggle buttons — own `CanvasLayer`, bottom-right
corner, free of the other debug widgets) flips `HealthComponent.invincible` on that objective; text
reflects state (`"Objective: ON"` vulnerable / `"Objective: OFF"` invincible). Lives only in
`bot_arena.gd` — `Main.tscn` runs `main.gd` instead, so this cheat button structurally cannot appear
in a real match.

**`State.ALERT` — automatic defense-team alarm on first hit to the objective (by request).**
`ObjectiveAlertZone` reuses `spawn_zone.gd` verbatim (its name matches neither the `"Attack"` nor
`"Defense"` prefix, so `_draw_debug_circle()` colors it yellow automatically) — radius =
`DefenseSpawnZone.radius × 1.5`, centered on the objective's XZ position, present on all three maps
(geometry-only on `Main.tscn`, same as the `Attack/DefenseWaypointN` markers — `tank_ai_controller.gd`
still untouched). Every defense-team bot (`not is_attacker()`) subscribes in `_ready()` to
`Objective/HealthComponent.damaged`; the very first hit — from anyone — flips `_alert_triggered =
true` for good (no request for it to ever turn back off). `_ensure_home_state()` checks that flag
FIRST, ahead of the usual PATROL(ACHIEVER)/HUNT(KILLER)/IDLE pick, routing the bot into
`State.ALERT` — the same `_drive_to_point()` driving stack as HUNT/PATROL, but sampling uniformly
inside the CIRCLE (`sqrt(randf())`, not HUNT's rectangle). DEFEND (an actually-visible enemy) still
outranks it, same priority ladder as always — "searching for attackers" needs no bespoke logic since
target-scanning already runs every think-tick regardless of the current home state. `_has_alert_target`
gets the same `_on_target_lost()` staleness-reset treatment already applied twice to
`_has_waypoint_target`/`_has_hunt_target` (§ above) — DEFEND's approach logic can repoint
`_nav_agent.target_position` mid-alert, so the flag has to be cleared or the bot would spin in place
on return. `vision_range` — one field driving BOTH cones' range (`_can_see()` checks distance before
ever splitting into hull/turret cones) — bumped ×1.5 across all three difficulty tiers (MEDIUM
10→15, EASY 6→9, HARD 14→21), not just MEDIUM.

**ALERT is temporary, timer-driven, and the timer is CENTRALIZED (by request, three revisions).**
First cut used a geometric "enemy physically inside the circle" check — too strict in practice: the
defense bot already patrols right next to the objective, `vision_range` (15) comfortably covers the
whole alert circle, so an attacker entering it was almost always ALREADY visible directly,
triggering DEFEND (higher priority) before ALERT ever got a chance to show. Second cut replaced it
with a per-bot timer (`_time_since_objective_hit`, reset to 0 on every `Objective/HealthComponent.
damaged`) — but that timer lived in `BotSentryController._physics_process()`, which stops running
entirely while the bot is frozen for respawn (`process_mode = DISABLED`, see
`respawn_controller.gd`): a bot that died mid-alert came back with a stale timer, either missing an
active alarm or wrongly re-triggering one. Final cut moves the timer to `bot_arena.gd` (the scene
root orchestrator, never frozen) — `_time_since_objective_hit` (starts at `INF`) accumulates every
physics frame there, resets to 0 in the same `_on_objective_damaged()` that already updates the HUD
label; `BotSentryController` no longer stores or subscribes to anything, it just caches `_arena =
get_tree().current_scene` in `_ready()` and calls `_arena.time_since_objective_hit()` (a public
getter, not `.get()` on a private var) inside `_ensure_home_state()` each time. Every defense bot —
the one that's been alive since scene load and one that respawned two seconds ago — reads the exact
same clock, so "alarm on, existing AND newly-spawned defenders both see it" falls out for free.
Confirmed live: kill mid-alert, let the (never-frozen) arena timer run past the freeze while the
bot's own `_physics_process()` is provably not running, respawn, and the very next think-tick puts
the bot straight into `State.ALERT` — no fresh hit needed, matching whatever time is actually left
on the shared clock. Since transitions between home states became two-way (not just DEFEND→home
anymore), `_ensure_home_state()` clears all three driving-target flags (`_has_waypoint_target`/
`_has_hunt_target`/`_has_alert_target`) on every state change, not just the one pair that bit before
(§ above) — cheaper than reasoning about which one is stale this time.

**Respawn doesn't reset AI state on its own (by request — "a killed attacker comes back already
mid-fight with the objective").** `RespawnController` resets the tank's physical state
(position/health/ammo/`TankStateMachine`) but knows nothing about `BotSentryController.state` —
different layers, deliberately not coupled. A bot that died in `State.ATTACK_OBJECTIVE` used to come
back with that SAME state — and `ATTACK_OBJECTIVE` is never re-evaluated by `_ensure_home_state()`
(it's in that function's exception-guard, waiting to resolve on its own), so a bot teleported back to
its own spawn would immediately try to drive/shoot at the objective directly, skipping the whole
`AttackWaypointN` route. Fixed with a new `RespawnController.respawned` signal (emitted at the end of
`_on_respawn_timeout()`, after unfreezing) that `BotSentryController` subscribes to itself — the
decoupling stays intact, `RespawnController` doesn't need to know the subscriber exists.
`_on_respawned()` resets to a neutral `State.IDLE`, clears the current target and all three
driving-target flags, but leaves `_waypoint_index` alone (route progress isn't the same thing as
combat state, same reasoning already used in `_advance_waypoint()`) — the next think-tick picks a
fresh home state through the normal priority machinery, as if the bot just spawned.

**ALERT re-verified live — the mechanism works, its visible window is just narrow.** A live (not
forced) fight timeline: `DEFEND` while the attacker is alive and visible (outranks ALERT, expected);
flips to `ALERT` the instant the attacker dies and goes invisible while the objective-hit clock is
still under `alert_timeout_sec`; back to `DEFEND` once the attacker respawns and is visible again;
falls to `PATROL` once the clock runs out. Screenshotted the debug panel mid-ALERT to confirm it
renders (`"state: ALERT — expires in 5.1s unless objective hit again"`). The reason it's easy to
miss on screen: the defense bot patrols right next to the objective and `vision_range` (15) covers
almost the whole `ObjectiveAlertZone` (radius 12), so a live attacker inside the circle is almost
always ALREADY visible — DEFEND wins the priority race before ALERT gets a real chance to show; the
actual window is the few seconds between an attacker's death and its respawn.

**ALERT re-verified a second time, three fully-live respawns in a row — didn't reproduce.** Killed
`BotTank` once to force a respawn window, then let everything else run un-forced (real
`RespawnTimer`, real `AttackBotTank` fire, no manual `take_hit()`): each time it came back while
`_arena.time_since_objective_hit() < alert_timeout_sec`, `state` was `ALERT`, matching the debug
panel text (`"state: ALERT — expires in Xs..."`) screenshotted directly. One respawn landed during a
genuine lull (both bots waiting on their own respawn timers, nobody firing for >10s) and correctly
got `PATROL` — not a bug, exactly what "≤10s since the last hit" means. Found and closed one real
gap while re-checking: ALERT's condition didn't check that the objective still exists — it
`queue_free()`s on the 10th hit, but the arena clock (last hit was right before that) keeps
ticking, so a defender would keep "searching" around a target that's already gone for up to
`alert_timeout_sec` more seconds. Added an `is_instance_valid(_objective_node)` check, same pattern
already used by the `ATTACK_OBJECTIVE` branch elsewhere in this file.

**Respawn also didn't reset the one-way route progress (by request — "attacking bots must always
spawn following their waypoints").** `_on_respawned()` (§ above) correctly resets `state`, but
deliberately left `_waypoint_index` alone — same reasoning as `_advance_waypoint()` ("if a bot
somehow returns to PATROL, keep the last waypoint, don't roll back to the first"), which is right
for a bot that stayed put and got distracted, but wrong for respawn: the bot gets teleported back to
its own spawn, far from where it died. If it died having already reached the last `AttackWaypoint`
(right at the objective), `_waypoint_index` stayed on that last index — respawn drove it straight
back to that SAME last waypoint (not the first), it reached it almost immediately, and
`_advance_waypoint()` dropped it right back into `ATTACK_OBJECTIVE` — technically `PATROL` per
§ above, but with no visible march through the route. Fix: `_on_respawned()` now also does `if
waypoints_one_way: _waypoint_index = 0` — only for the one-way (attacker) route; the looping
defense patrol (`waypoints_one_way=false`) has no "route completed" concept and is untouched.
Confirmed live, unforced: killed `AttackBotTank` at the objective, let the real 10s `RespawnTimer`
fire, and it came back in `PATROL` at `waypoint_idx=1` (already past the first leg), driving through
the route rather than sitting back at the objective.

**ALERT trigger is now an OR of two independent conditions (by request — user caught a live case
where a defender spawned mid-bombardment and stayed in `PATROL`, but the timer mechanism itself
could not be reproduced technically despite 25+ forced and live checks in the same session).** The
timer alone has a gap: it only starts once the objective has actually been HIT — an attacker who
has walked into `ObjectiveAlertZone` but hasn't fired yet leaves the timer at `INF`, so a bot
spawning in that window still saw `PATROL`. Brought back the original geometric check (an attacker
physically inside the circle, retired earlier in this doc for being too strict AS THE ONLY
condition) as a second, independent path — same centralized orchestrator pattern as the timer, not
per-bot: `bot_arena.gd.enemy_in_alert_zone()` loops `get_tree().get_nodes_in_group("tanks")`,
filters `is_attacker() and tank.visible` (same dead-tank-exclusion pattern as `_can_see()` — a
respawn-frozen corpse must not count), and does a flat `Vector2` XZ-distance check against the
zone's own `radius` (`_alert_zone.get("radius")`, no `class_name` — same reflection pattern already
used elsewhere for this script). `_ensure_home_state()`'s condition is now `objective_alive and
(time_since_hit < alert_timeout_sec or enemy_in_zone)` — each half covers what the other misses: the
timer keeps ALERT alive for `alert_timeout_sec` after the attacker leaves the circle (e.g. retreats
after firing); the geo check catches an attacker already inside who hasn't fired yet. `DEFEND` (an
actually-visible target) still outranks ALERT either way, same priority ladder as always — this
brought back exactly the interaction that made the pure-geo version look broken originally (an
attacker just inside the circle is usually already visible too, so `DEFEND` wins the race first);
that's expected, not a regression — the geo check's real job is the case NPC vision doesn't cover
(behind an obstacle, or before the querying bot's own think-tick catches up).

The original user-reported case — timer-only ALERT missing on a fresh spawn — was never
technically reproduced (systematic forced + live retries across most of this session's diagnostics
all showed the timer firing correctly); the OR-fallback is a deliberate defensive measure requested
regardless of whether the exact root cause was ever pinned down, not a fix confirmed against a
reproduced failure.

Confirmed live via `run_script`, isolating each half of the OR independently (`BotArena.tscn`,
forced `_ensure_home_state()` calls, bypassing `_think()`'s own DEFEND check so the geo/timer
condition itself — not the priority race — is what's being tested): attacker teleported into the
zone with the timer already expired (`999s` stale) → `ALERT` (geo-only); timer forced fresh
(`0.0s`) with the attacker teleported far outside the zone → `ALERT` (timer-only); both false
(stale timer, attacker outside) → `PATROL`, confirming the OR doesn't misfire when neither
condition holds. Also smoke-tested `enemy_in_alert_zone()` on `KillerArena.tscn` (same shared code,
`ObjectiveAlertZone` present there too) — zone found, method callable, correctly `false` at each
tank's own spawn corner and `true` once `PlayerTank` was teleported into the zone.

The debug label (`_update_brain_debug_label()`, `State.ALERT` case) now branches three ways instead
of unconditionally showing the timer countdown — a stale/expired timer value while the geo check
alone holds ALERT open used to render a meaningless negative number (`"expires in -991.9s"`,
screenshotted before the fix): `"enemy in zone, timer Xs left"` when both conditions are live,
`"enemy in zone (timer expired)"` when only geo holds it, and the original `"expires in Xs..."` text
when only the timer holds it.

`scenes/bot_arena/KillerArena.tscn` is a separate scene (duplicated from `BotArena.tscn`, by direct
request) purpose-built for testing KILLER — its `BotSentryController.role` is set to `KILLER` in the
scene file itself (not the runtime default), it has 6 extra `ObstacleN` static bodies spread across
previously-empty parts of the 72×72 map (the original 5 all cluster in one small patch near
`Objective`), and `PlayerTank`/`BotTank` spawn at opposite corners instead of a few meters apart —
confirmed live: on a fresh load the bot drove clear across the map on its own and found the player
(`HUNT`→`DEFEND`) with zero manual intervention. Launch it explicitly (`run_project` with `scene:
"res://scenes/bot_arena/KillerArena.tscn"`, or point `run/main_scene` at it) — it's not the default
scene, see below.

### Map inventory (by request — the project now has four distinct scenes, don't confuse them)

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` (by request) — a plain `Control` scene, three
buttons, each just calls `get_tree().change_scene_to_file()` at one of the scenes below; carries no
game logic of its own. The other three are unchanged, just no longer the default — launch any of
them directly via `run_project`'s `scene:` param (or repoint `run/main_scene`) to skip the menu:

- `scenes/main/Main.tscn` — the actual production game: 5×5, two teams, `Objective`/`MatchManager`,
  the real `TankAIController` brain.
- `scenes/bot_arena/BotArena.tscn` — bot-AI sandbox with an `Objective` and an ACHIEVER test bot
  (patrols/defends around it).
- `scenes/bot_arena/KillerArena.tscn` — bot-AI sandbox for the KILLER role, described above.

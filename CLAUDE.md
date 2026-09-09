# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Editing this file invalidates the session prompt cache** — the next turn re-bills the whole
> instruction prefix at full price. Batch CLAUDE.md edits to the **end** of a session; don't
> drip-edit mid-task.

## Project

Tank Prop Hunt — a team tactical shooter with prop-hunt elements (disguise mechanic), Godot 4.7
(GDScript), 3D, Jolt physics. Local prototype vs bots, no networking yet — the three maps are built
as reusable game-mode templates (see "Map inventory") with a future networked PvP mode in mind, so
architecture favors universal/data-driven mechanisms over map-specific code wherever the two don't
conflict.

Full design docs live outside this repo, in `C:\Users\PC\Documents\Personal Vault\Tank Props Docs\`.
Code comments frequently say "see vault" — that's this folder, not anything inside the repo. Read
the relevant doc before non-trivial work on a system it covers. The reference docs describe how each
system works **now**; deep history is in `git log`.

- `Tank_Prop_Hunt_Gameplay_Concept.md` — **the design doc**: vision, pillars, core loop, feature
  list, the horizontal progression model (specializations / modules / build / mastery), target
  F2P meta shape. "What the game is", not implementation.
- `Tank_Prop_Hunt_Disguise_Progression_Model.md` — source doc for the progression model
  (sidegrade-not-upgrade; account → specializations → modules → build → mastery).
- `Tank_Prop_Hunt_Development_Plan.md` — **the roadmap**: §2 enumerates what's already built, then
  phases A–F (core stabilization → data/art → specialization+module system → meta shell &
  progression → networking → production) with per-stage DoD.
- `Tank_Prop_Hunt_Game_Modes.md` — **current-state reference for TARGET_OBJECTIVE / TEAM_ARENA**:
  rules, round/series flow, HUD block, round-loop code, full map list. "Game modes" below is a
  summary; that doc is the detail.
- `Tank_Prop_Hunt_Extraction_Loop_Concept.md` — **the design doc for the current core loop**: the
  four states of value, why this is deliberately *not* CTF, and the single connection the design
  rests on — **cargo forbids disguise**. Read before touching anything in EXTRACTION.
- `Tank_Prop_Hunt_Extraction_Loop_TZ.md` — the implementation spec derived from that concept
  (entities, ownership, where each rule lives).
- `Tank_Prop_Hunt_Extraction_Mode.md` — **current-state reference for EXTRACTION** (`KitchenMap.tscn`):
  `LootCrate` as the single physical embodiment of value in every state, `CargoHold` and its costs,
  destructible cover cubes with seeded hidden loot, warehouses with per-crate ripening, evacuation
  windows, the bot cycle.
- `Tank_Prop_Hunt_Kitchen_Map.md` — **the multi-level kitchen map's geometry rules** (ramp angles,
  ramp-to-platform joins, navmesh island pitfalls).
- `Tank_Prop_Hunt_Bot_AI_Sandbox.md` — the single universal bot AI (`TankAIController`): states,
  driving stack, per-tier params, scene inventory.
- `Tank_Prop_Hunt_Tank_Chassis.md` — **how the tank looks and reacts to terrain**: the `Hull`
  visual pivot (`hull_rig.gd`), running gear, terrain tilt / suspension; why the turret stays level
  and why `VehicleBody3D` was not used; per-side track/wheel speeds; the slope→speed multiplier;
  the edge brink → teeter → tumble system; the `TestGroundMap.tscn` proving ground.
- `Tank_Prop_Hunt_Ammo_Drops.md` — **ammo drops**: the `AmmoDropZone` prefab, drop/pickup/anti-overlap
  rules, per-map placement, `GameConfig` defaults.
- `Tank_Prop_Hunt_Disguise.md` — **disguise**: activation (player-only, key **M**), the
  `GameConfig`-driven prop, x-ray-silhouette player view, full break-trigger list including the two
  enemy-relative rules, the bot's `_can_see()` blindness gate.
- `Tank_Prop_Hunt_Modifications.md` — **the tank modification system**: the single HUD slot, the red
  `ModCrate`, and the mortar (barrel attachment, two-press lobbed special shot, own aiming camera +
  ground-ring reticle, `GameConfig.mortar_objective_damage`); bot pickup and use.
- `Tank_Prop_Hunt_Turrets.md` — **the stationary turret system**: the universal `Turret.tscn` prefab,
  its 3 states, difficulty presets, 10-HP destructible body, tank-cadence fire, near blind-zone,
  disguise blindness, ally→turret ALERT target-share, the debug FOV overlay.
- `Tank_Prop_Hunt_Map_Creation_Guide.md` — **step-by-step how-to for designers**: new map +
  `match_mode`, required-node skeleton, the `Objective`, `SpawnZone`s + roster JSON, `AmmoDropZone`s.
- `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md` — **step-by-step how-to for designers**: add / remove
  / move / resize `Obstacle*` / `HazardZone*` under `NavigationRegion3D`, and the mandatory manual
  NavMesh re-bake after any such change.

## Running / testing

No build step (GDScript is interpreted) and no automated test suite exists in this repo. Verify
changes by running the project — normally through the `godot-runtime` MCP server (`run_project`
with `background: true`, then `get_debug_output` immediately to catch script/scene errors, then
`run_script` / `take_screenshot` / `simulate_input` to drive and inspect a live session, then
`stop_project`). See the `godot-mcp-testing` skill for the full tool catalog and gotchas.

`res://scenes/tank/tank_ai_controller.gd` has no formal test suite — its correctness is established
the same way (live `run_script` assertions on state, not manual play).

**Batch calibration** — `tools/calibration/calibrate.gd` runs a whole map's scene-bring-up
invariants in **one** `run_script` (autoloads, `match_mode` / `total_rounds`, `MatchManager` /
`RoundTimer` / `ScoreManager`, borders, the tank component set, bot-AI enabled, root-upright,
kill-plane, plus per-mode checks). Launch a map, wait for bring-up (~3 s flat maps, ~6 s
`KitchenMap` — it bakes its navmesh), then paste the file's contents as the `run_script` `script`
arg (that tool takes inline source, not a `res://` path). It returns `{pass, summary, failed[],
passed[]}`; a non-empty `failed` is a regression to explain before shipping. Extend its
`_MAP_EXPECT` + per-map functions rather than writing one-off ad-hoc `run_script` checks.

**Current `run/main_scene`** (`project.godot`) points at `res://scenes/main_menu/MainMenu.tscn` — a
plain launcher, not a map scene. Pick one from there, or point `run/main_scene` at a specific map
(or pass `scene:` to `run_project`) to skip the menu when iterating on one map.

## Invariants — never violate these

Terse list; each points into the Architecture section below for the mechanism. These are the rules
whose breach is a silent-corruption / never-converges / runtime-error class bug, not a style
preference.

1. **The tank root never tilts.** Only `Hull` (visual pivot) and `Turret` (its child) tilt.
   forward/right, aim, turret yaw and the entire bot brain read the **root** basis. Sole
   carve-out: `TumbleController` during a cliff tumble — safe only because every root-basis reader
   is frozen meanwhile. → "Tank as a composed entity".
2. **World vs local gun angles.** The turret tilts, so a local gun angle ≠ a world angle.
   `BarrelController.target_pitch` is the *ordered* elevation in **world** terms. Any "is the gun
   on target?" check reads `world_pitch()` / `world_pitch_limits()`, **never `rotation.x`** — on a
   slope a compare against the local angle never converges and bots stop firing. Normal-shell world
   elevation is capped 20° (mortar raises it to 85° while aiming, then restores). → "Tank as a
   composed entity".
3. **No `await` before tree-independent setup in a map root's `_ready()`.** `await` (navmesh bake,
   dynamic obstacles) voids the "root `_ready()` beats every `_process()`" assumption that
   `ammo_drop_zone.gd` / `hud.gd` / `tank_ai_controller.gd` lazy-inits rely on. Anything needing no
   tree (copy `match_mode` into `MatchState`) goes at the very top, before any `await`. A lazy init
   that needs a code-created node waits for **that node**, not "one frame". → "Scene bring-up
   ordering".
4. **`add_child()` on `current_scene` from inside a sibling's own `_ready()` fails** ("Parent node
   is busy setting up children"). Per-match setup runs from the map root's `_ready()`, which
   finishes last. → "Scene bring-up ordering".
5. **A node's `_ready()` must not read a value another sibling's `_ready()` sets** (e.g. HUD
   reading `tank.team`). Sibling `_ready()` order is not the fix — read it from an autoload set up
   before scene load (`MatchState`). → "Scene bring-up ordering".
6. **Signal handler arity must match the emitted arity exactly** or it is a runtime error, not a
   warning. `HealthComponent.damaged` emits `(current_hits, max_hits, killer)`. → "Signals over
   polling".
7. **A freshly-added `class_name` is not seen by headless `run_project`** without an editor rescan.
   Use a `preload()`'d script reference instead (e.g. `SpawnZone.face_center`). → "Spawn system".
8. **`match_mode`'s script default is `-1`, a deliberate invalid sentinel** — keeps the `.tscn`
   line always serialized. Still `-1` at runtime ⇒ the line was dropped ⇒ `push_error` + fallback
   to TARGET_OBJECTIVE. Conversely **default-valued `@export` lines are legitimately absent from a
   `.tscn`** (`final_stage_enabled`, `map_border_enabled`) — not corruption, do not "restore" them.
   → "Game modes".
9. **Every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`** — it is freed with
   the objective and absent on maps without one. → "Game modes".
10. **Every component gates on `is_player_controlled` independently, default `true`.** Spawning a
    second tank without flipping that flag first makes it read the real player's keyboard. Disable
    it (and hand off camera activity) before it is alive in the tree. → "Tank as a composed entity".
11. **`ledge_max_slope_deg` must stay well above the ~44–45° climb limit**, and the centre/march
    support probes need generous vertical reach, or a tank perched nose-up on a steep ramp reads as
    "off a cliff". → "Tank as a composed entity" (ledge / brink / tumble).

## Architecture

Vault docs stay the source of truth for anything a section marks "full detail:
`Tank_Prop_Hunt_*.md`".

### Tank as a composed entity, not a god-object

`scenes/tank/Tank.tscn` is the single reusable scene for the player's tank and every bot
(`scenes/main/team_spawner.gd` instances it N times). All behavior lives in sibling components
under the root, each independently toggled between player and AI control via its own
`is_player_controlled: bool` (default `true` — see Invariant 10).

`tank.gd` (root) holds `team` / `is_attacker()` and the **team-colour mesh tint**
(`apply_team_visuals()`): `GameConfig.team_attack_color` / `team_defense_color` applied by a
recursive walk of the `Hull` and `Turret` subtrees (armour is code-built, no fixed node list)
minus the running gear and mortar attachment (`_DARK_PART_PREFIXES`). Called by `team_spawner.gd`
after `team` is assigned and by `RespawnController.on_respawned()`. The tint is always on. In
**debug mode only** a billboard `Label3D` "HP N/M" sits above the tank, refreshed on `damaged` /
`destroyed` / respawn; the mesh itself is never repainted for damage.

- `Hull` (`hull_rig.gd`, `@tool`) — the **visual** hull pivot. Every chassis mesh you see (armour
  boxes, glacis, sponsons, turret ring, road wheels, drive sprocket/idler, the `MultiMesh` track
  cleats) is built **in code** as its children; children get no `owner`, so a GUI save of
  `Tank.tscn` can't serialize them. Owns the **terrain tilt**: four downward corner rays give the
  support plane's pitch/roll plus the sag of a box collider resting on a slope edge, plus accel
  dive/squat and outward roll in a turn, exponentially damped and clamped to `max_tilt_deg`. The
  tank root never tilts; `Turret` is a child of this pivot (`Hull/Turret`), so the ring tilts with
  the deck and the turret keeps one degree of freedom — rotation about the tilted deck normal.
  Track/wheel speeds are per side (`v = v_forward ± ω·gauge`), so a neutral turn spins the tracks
  in opposite directions. Full detail: `Tank_Prop_Hunt_Tank_Chassis.md`.
- **Gun angles: world vs local.** `BarrelController.target_pitch` is the *ordered* elevation in
  **world** terms (that is what the player camera pitch, the bot ballistic solution and the mortar
  solution all produce). `barrel_controller.gd` converts it to a local angle by subtracting
  `mount_pitch()` (the ring's tilt along the turret's facing) and clamps *that* to
  `min_pitch_deg` / `max_pitch_deg` (elevation limits are set by the trunnions, not the horizon).
  On flat ground `mount_pitch()` is 0. Any "is the gun on target?" check reads `world_pitch()`,
  never `rotation.x` — on a slope those differ and a compare against the local angle never
  converges (three call sites in `tank_ai_controller.gd`, plus `world_pitch_limits()` to clamp the
  ballistic solution). By design, on a climb the gun can't depress to the horizon — on a 24° ramp
  the reachable world window is `[+7°, +42°]`, and the crosshair shows it honestly since it is
  built from the barrel's live basis. Normal-shell elevation cap is **20°**; the mortar raises the
  cap to 85° while aiming and restores it. Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §4.
- `CameraRig` (`SpringArm3D`) — on the **root** (must not rock with the hull). Player only;
  free-look orbit, `rotation.y = world_yaw − body.rotation.y` recomputed every physics frame so
  turning the hull never drags the camera. It **lifts as the aim rises**: `pivot_height` and
  `spring_length` interpolate by `smoothstep` over the up-pitch range so at the top of the aim the
  camera clears the turret roof and sits close behind; looking down is untouched. Camera
  `pitch_max_deg` 25° keeps a margin over the gun's 20°. GTA-style level-follow during a tumble
  (`set_tumble_follow(true)`).
- root **collider** (`CollisionShape3D` on the root) — a `ConvexPolygonShape3D`, not a box: same
  `1.2 × 0.6 × 1.8` bounding size at `+0.3` y, but the bottom **nose and tail edges are chamfered**
  (0.24 × 0.28, ≈40°; the sides stay square — that's where the tracks are). Result: lips up to
  **0.20** and ramps up to **44°** are climbed, so the ceiling is `floor_max_angle` (45°). Bounding
  half-extents are unchanged, so `disguise_controller.HULL_HALF_EXTENTS` and every AABB rule still
  hold. Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §3.1.
- `TankMovement` — tracks, reads `Input` or `ai_move_input` / `ai_turn_input`. Only forward/back +
  hull rotation are ever commanded (no strafe axis), but `move_and_slide()` will still glide the
  body sideways along a collision tangent when it contacts geometry at an angle. `_physics_process()`
  corrects for this every frame: after `move_and_slide()` it discards whatever component of the
  frame's actual resulting displacement/velocity is perpendicular to the hull's forward axis. The
  same behaviour applies to the player, just less visible since a human steers away from corners.
  This node also owns, for the same reason (it already holds vertical velocity, gravity,
  `is_on_floor()`):
  - **Fall damage** (`_track_fall_damage()`): while airborne it tracks peak height and on landing
    charges the *height difference* (not impact speed) as 0/1/2/3 HP by the `GameConfig.fall_damage_*`
    thresholds, via a normal `take_hit(killer = null)` so debug invincibility still applies and
    `ScoreManager` credits nobody. Reset on `RespawnController.respawned`. Only bites on multi-level
    maps; flat maps never reach the 8-unit floor threshold.
  - **Slope-speed multiplier** (`_slope_speed_multiplier()`, `slope_speed_*` exports, `penalty 0.9`
    / `min_mult 0.65`): uphill slower, downhill slightly faster, from `get_floor_normal()`, no
    extra ray. Flat ground ⇒ multiplier exactly 1.0.
  - **Carry-weight multiplier** (`_effective_move_speed()` → `ModificationController.carry_speed_multiplier()`
    → `Modification.carry_speed_multiplier`, default 1.0). Applied at every place a speed is ordered
    (normal drive, TEETER phase, and the "distance commanded" the step-up assist compares against),
    so a loaded tank never trips the assist by falling short of a figure it was never ordered to
    make. It is a *limit*, not an instantaneous speed — `acceleration` still ramps to it, so
    picking up or handing over a load mid-drive produces no jerk. Stacks multiplicatively with the
    slope multiplier and with `CargoHold.speed_multiplier()` — the EXTRACTION cargo bay is the load
    that actually bites today. No `Modification` sets a weight; the field is the generic hook.
  - **Step-up assist** (`step_up_*` exports): after `move_and_slide()`, if the tank advanced far
    less than commanded and a low near-vertical face is dead ahead with walkable ground ≤
    `step_up_max` (0.35) on top, lift the body onto it — the chamfer only clears 0.20 lips, and
    ramp feet / furniture-plate joints / a table edge under a ramp exceed that. No-ops on flat
    ground and on smooth ramps (it checks for a wall-like face, not a slope).
  - **Ledge / brink / tumble support model** (`_update_support()` + `_integrate_teeter()`,
    `ledge_*` / `teeter_*` exports). `CharacterBody3D.is_on_floor()` is binary "any contact", so one
    edge on a platform lip keeps the tank glued with ¾ of the hull over a pit. Support model: four
    **directional edge-marches** (F/B/L/R — step outward, find where ground ends; a drop steeper
    than `ledge_max_slope_deg` at that reach is a cliff, shallower is a slope) + a centre-ground
    probe + a horizontal wall pre-check per direction (a wall ahead ≠ a cliff) + a **gap tolerance**
    (`ledge_gap_tolerance` 0.5 m — a joint between furniture / a ramp lying on a table edge is a
    *seam*, and the march steps over it). `_com_margin` (signed: <0 = CoM on support with that much
    room, >0 = past the edge) varies **continuously** as the tank creeps toward a lip. CoM is a
    real offset (`center_of_mass`, low + slightly rear); on a slope the margin is shifted downhill
    by `center_of_mass.y·tan(slope)` (`com_slope_shift_enabled`) — a taller CoM or a downhill edge
    tips sooner. **Three stages, no abrupt switch:** **BRINK** — CoM within `teeter_brink_margin` of
    the edge but still on support: throttle auto-slows toward the void (`teeter_brake`, floored at
    40%), hull noses down to `teeter_prelean_deg`, steering still on, fully recoverable by turning
    away or reversing. **TEETER** — CoM past the edge: hull tip angle integrates upward
    (`teeter_gravity_gain`) vs reverse-throttle pull (`teeter_recover_gain`) + damping, steer off,
    drift toward void, still reversible. **POINT OF NO RETURN** — `_tip_angle ≥ teeter_ponr_deg`
    (26°), or airborne after a real brink / `jump_grace_sec` with no support: hands to
    `TumbleController` with the current angular velocity (no snap). A level launch (trampoline) has
    `_edge_approach ≈ 0` ⇒ never a tumble. Falling breaks disguise (`"fell"`) and overrides the
    mortar hull-freeze. `ledge_max_slope_deg` must stay well above the ~44–45° climb limit, and the
    centre/march probes need generous vertical reach (`_CENTER_REACH_DOWN`, `_EDGE_CLIMB_TAN`) or a
    tank perched nose-up on a steep ramp reads as "off a cliff" (Invariant 11). Flat maps: no edges
    found ⇒ `_com_margin` deeply negative ⇒ zero behaviour change. The hull tip for all stages is
    `hull_rig.gd` (`fall_tip_enabled`, reads `TankMovement.tip_angle()`). Detail:
    `Tank_Prop_Hunt_Tank_Chassis.md` §8.
- `TumbleController` (`tumble_controller.gd`) — the tank falling off a cliff and righting itself
  turtle-style after a cooldown. The root must stay upright (bots/aim/turret read its basis), so on
  the commit from `TankMovement` an **invisible `RigidBody3D` proxy** (same convex shape, env-only
  collisions) takes over: free fall — it gets the tank's linear velocity and only the teeter's
  actually-accumulated tip rate (`_tip_vel`, capped by `tumble_spin_max`); no baseline spin, no
  randomness. Tracks-vs-roof is decided by physics: the proxy is given the tank's real low centre
  of mass (`CENTER_OF_MASS_MODE_CUSTOM`, read from `TankMovement.center_of_mass` — one source of
  truth), which acts as a pendulum on impact and rolls the hull back onto its tracks, plus
  `proxy_angular_damp` (0.35) bleeding spin in flight — the mid-point where a clean fall lands on
  tracks at any throttle while a genuinely inverted tank still self-rights. Each frame the proxy's
  transform is copied onto the tank root so every code-built visual rides along. Sibling components
  are frozen (`process_mode`, the death-freeze idiom), the root collider is off. On settle: deck
  within ~35° of up ⇒ recover now; else wait `self_right_cooldown_sec`, kinematically flip the
  proxy upright (yaw kept), swap back to the `CharacterBody3D`, unfreeze,
  `set_tumble_follow(false)`, `hull_rig.reset_pose()`, emit `recovered` (`TankMovement` +
  `TankAIController` resync on it). Fall-damage-on-impact lives here (`GameConfig.fall_damage_*`).
  `self_right_cooldown_sec` is in `config/*_tank_config.json` (per-profile, upgradeable later);
  other thresholds are `@export`s. Death mid-tumble (fall damage / round-end `force_destroy`) ⇒
  `_abort_dead()` leaves the wreck for the normal respawn to right and does not touch the
  freeze/collider (RespawnController owns those on death); `respawned` also aborts.
  `TumbleController` is excluded from `RespawnController._set_frozen` so it can finish. **This is
  the only time the root is not upright** — safe because every reader of the root basis is frozen
  meanwhile. Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §8.1.
- `TurretController` — yaw. When `is_player_controlled`, reads `target_yaw` from `CameraRig`; for
  bots, the AI writes `target_yaw` directly. The turn is `rotate_toward(rotation.y, target_yaw,
  turn_speed*delta)` — constant angular velocity (not `lerp_angle` — non-linear feel).
- `BarrelController` — pitch, same follow-with-delay pattern (see "Gun angles" above).
- `WeaponController` — fires along the barrel's actual basis (no separate angle math); gated by
  `TankStateMachine.request_fire()`.
- `TankStateMachine` — `NORMAL / DISGUISED / DISGUISE_COOLDOWN / RELOAD`, the single authority other
  components consult (`can_fire()`, `can_enter_disguise()`, `break_disguise(reason)`). Timer
  durations come from `GameConfig`, but `reload_timer.wait_time` is re-read fresh in
  `request_fire()` rather than cached in `_ready()` — a defensive read so a future map that
  overrides `GameConfig.reload_duration_sec` from its own root's `_ready()` (which runs after every
  child) wouldn't get a stale value. No current map does this; both use the 3 s default.
- `DisguiseController` — the disguise mechanic (full detail: `Tank_Prop_Hunt_Disguise.md`).
  Player-usable: key **M** anywhere → tank looks like a `GameConfig`-configured obstacle prop (brown
  box for MVP; the meta-game picks the prop later; no per-map `DisguiseSlot` markers). The
  disguising player sees the prop with an x-ray silhouette of their tank; everyone else sees the
  prop only. Bots activate disguise only via three scripted ambush scenarios
  (`disguise_bot_enabled` + `disguise_s1/s2/s3_enabled` from the roster; see
  `Tank_Prop_Hunt_Disguise.md` §5.2), never opportunistically. A bot **won't acquire** a disguised
  enemy (`TankAIController._can_see()` returns false in `_scan_for_target()` while the target's
  `TankStateMachine` is `DISGUISED`, unless `GameConfig.ai_can_see_disguised_tanks`) — but a bot
  **already in `ATTACK` on that tank keeps firing** through the disguise (`_can_see(target,
  ignore_disguise=true)` in `_think()`). Break triggers: turret turn / move / fire / moving-tank
  bump (`CollisionDetector`) / projectile hit (`HealthComponent.damaged` →
  `break_disguise("projectile_hit")`; an `invincible` tank absorbs the shell, so no `damaged`, no
  break) / enemy within `GameConfig.disguise_enemy_proximity_break_dist` of the tank collider (when
  the prop is smaller than the tank on any axis) / enemy entering the prop's volume (when it's
  larger — the MVP prop's case; the prop collider is never a physics body). When disguise drops the
  bot re-acquires next think-tick. For bot pathfinding a disguised tank carries a prop-sized
  `DisguiseObstacle` `Area3D` on layer `disguise_obstacle` (4): the AI's gap-scan detour rays see
  the full prop footprint, but the emergency brake does not — so a bot with a disguised tank on its
  committed route drives up to the real hull, contact breaks the disguise, bot aggros (no A*
  re-plan; the static navmesh never held any tank).
- `CollisionDetector` — `Area3D` on the tank body; a *moving* tank of any team touching a
  `DISGUISED` tank breaks its disguise (`break_disguise("collision")`). Independent of the
  enemy-relative rules above.
- `ModificationController` — the single pickup-modification **slot**, a generic host. One slot per
  tank; pick up only when empty (`can_pick_up()`), both teams, no drop — `clear_slot()` on use (the
  modification calls it) or on respawn. A `Modification` `Resource` (`id` / `display_name` /
  `hud_short` + `behavior_scene: PackedScene`) carries no logic; `install()` instances its
  `behavior_scene` as a child (`setup(tank)` + `on_installed()`), and the controller forwards a
  fixed null-safe contract — `intercepts_fire` / `on_fire_pressed` / `blocks_hull_movement` /
  `hides_crosshair` for the player; `ai_usable` / `ai_engage_range` / `ai_prep_sec` /
  `ai_aim_solution` / `ai_fire_at` for `TankAIController`. Base contract:
  `scenes/modifications/modification_behavior.gd` (`extends Node3D`, no `class_name`, all methods
  no-op). `weapon_controller` / `tank_movement` / `hud` / `tank_ai_controller` all talk to this
  contract — no `id == &"mortar"` checks. A `Modification` with `behavior_scene = null` (passive
  mod) is legitimate; nothing ships one right now. One contract entry deliberately reads the
  **`Modification` resource**, not the behavior node: `carry_speed_multiplier()` — it has to work
  for passive mods, which have no behavior node, so the number lives on the `.tres`, the one
  documented exception to "numeric balance lives in `GameConfig`" (same precedent as
  `ObjectiveAlertZone.radius` in a map's `.tscn`). The only behavior so far is the **mortar**
  (`scenes/modifications/mortar/{mortar_behavior.gd,Mortar.tscn}`): a two-press lobbed special shot
  (aim mode → ground ring reticle → `WeaponController.fire_special(dir, speed, damage)`), the one
  mortar-specific node in `Tank.tscn` being `Turret/MortarCamera`. Bots pick it up and use it
  (`MOD_SEEK` / `MOD_RETRIEVE` / `MORTAR_ATTACK`). Full detail: `Tank_Prop_Hunt_Modifications.md`.
- `HealthComponent` — `take_hit(killer, damage := 1)`; `current_hits += damage`, `destroyed` at
  `current_hits >= max_hits`. Tanks use `max_hits` **3** (`config/*_tank_config.json`, script
  default also 3; normal `Projectile.damage` is 1; a non-fatal hit updates only the debug HP
  `Label3D`). The objective uses this as an **HP pool** — `match_manager.gd` sets its `max_hits =
  GameConfig.objective_hits_required` (**100**), a normal shell does 1, the mortar special does
  `GameConfig.mortar_objective_damage`. `attackers_only` lets an objective ignore friendly fire;
  `free_on_destroy = false` on tanks hands cleanup to `RespawnController`; `invincible` is a debug
  point override, not normal balance. `force_destroy(killer := null)` bypasses `invincible` /
  `attackers_only` but still routes through `destroyed` — for "removed from play regardless of
  debug immortality" (only caller today: fell below the map).
- `RespawnController` — on death, disables the tank in place (hidden, colliders off, `process_mode =
  DISABLED` on every sibling except itself and `HealthComponent`) instead of freeing it, then
  teleports/resets it after `GameConfig.respawn_cooldown_sec`. Its `_physics_process` (never frozen)
  also **force-kills any tank whose `global_position.y` drops below `_FELL_BELOW_Y` = -3** via
  `HealthComponent.force_destroy()` — works on the invincible player too; the respawn cycle then
  brings it back at its spawn zone. `halt()` (called on round end) permanently stops it for this
  scene load — no more respawn, fall-check off.
- `CargoHold` — the EXTRACTION cargo bay: holds value **as data** (no nodes) and imposes the two
  costs that make carrying a decision — `blocks_disguise()` (read by `DisguiseController`, the HUD
  and the bot alike) and a per-crate speed penalty (`speed_multiplier()`). Also owns the "a
  warehouse crate goes only into an empty hold, and blocks top-up" lock in `try_take()`, so no
  pickup site has to know that rule.
- `TankAIController` — the single AI brain (own section below). Present on every `Tank.tscn`
  instance but inert (`enabled = false`) unless a spawner turns it on; when enabled it flips every
  sibling's `is_player_controlled` to `false` and drives them through the same public contract the
  player uses — no duplicated movement/combat path for bots vs. player.

### Scene bring-up ordering

Every map's root script (`scenes/maps/map_scene.gd`) explicitly sequences `_build_map_borders() →
TeamSpawner.spawn_team() → MatchManager.setup(...) → ScoreManager.begin_match()` in its own
`_ready()`, rather than letting each manager act in its own.

`_build_map_borders()` — per-map `@export var map_border_enabled` (**default on**; a map carries the
line in its `.tscn` only when it sets `false`). Reads the `Ground` collision box and adds a 4-wall
solid red `MapBorders` ring (thickness 1 / height 3, flush with the ground edge) under
`NavigationRegion3D` — an impassable perimeter, code-generated to fit any ground size. It is a
physical block regardless of navmesh. A tank that still slips past — or a map that opts out — is
caught by the fell-below force-kill in `RespawnController`.

Why the root's `_ready()` owns per-match setup:
1. `add_child()` on `current_scene` from *inside* a sibling's own `_ready()` fails ("Parent node is
   busy setting up children") — the tree is still being built; the root's `_ready()` runs last.
2. `ScoreManager` / `MatchManager` scan the `"tanks"` group and must run after spawning.

A node whose own `_ready()` reads a value another sibling's `_ready()` sets (e.g. HUD reading
`tank.team` before `TeamSpawner` assigns it) gets the stale default. Sibling `_ready()` order is
not the fix — read the value from an autoload set up before scene load (`MatchState`).

**`await` in the root's `_ready()` voids the "my `_ready()` beats everyone's `_process()`"
assumption** that several nodes rely on: `ammo_drop_zone.gd`, `hud.gd`, `tank_ai_controller.gd` all
defer their setup to a first `_process` / `_physics_process` tick *because* the root finishes
first. Once the root awaits (navmesh bake, dynamic obstacles), those lazy inits run **inside** the
wait, on a half-built scene. Two rules follow: (1) anything needing no tree — like copying
`match_mode` into `MatchState` — goes at the **very top** of `_ready()`, before any `await`
(`_apply_match_mode_to_state()`); (2) a lazy init that needs a code-created node **waits for that
node**, not for "one frame" (`ammo_drop_zone._process` polls for `MatchManager` with a frame
budget).

Camera ordering pitfall: an about-to-be-activated bot's `CameraRig` defaults `is_active = true` and
steals `Camera3D.current` the instant it enters the tree, inside `CameraRig._ready()`.
`team_spawner.gd` sets `is_active = false` on the orphaned instance *before* `add_child()` to avoid
a one-frame flicker; `TankAIController._initialize()` also re-asserts `camera.current = false` as a
defensive backup on the first `_physics_process()` tick.

### Autoloads and per-tank config

`GameConfig` (balance knobs shared project-wide) and `MatchState` (survives
`get_tree().reload_current_scene()`, where ordinary `@export` fields on scene nodes don't).
`MatchState` holds: `player_team: int` (the player's *side* this round, flipped by the HUD restart
button); `match_mode: Mode {TARGET_OBJECTIVE, TEAM_ARENA, EXTRACTION}` — a **per-map setting**
(`map_scene.gd` `@export_enum`, set in each map's `.tscn`; the HUD reads it lazily since its own
`_ready()` precedes the root's); a round-series score (`series_wins_attack` / `series_wins_defense`,
`total_rounds`) tracked **by side, not by "the player's team"** — `record_round_result(winner_side)`
credits whichever side ("attack"/"defense") took the round. In TARGET_OBJECTIVE the player swaps
sides between rounds, so "the player's team" isn't stable; the attack/defense **bot squads** are
(fixed by roster). In TEAM_ARENA there's no swap, so "attack" is permanently team 0 / Красные and
"defense" team 1 / Синие. The series accumulates across `reload_current_scene()` and resets only
from the main menu or the "Новый матч" button after `series_complete()`.

Two unrelated JSON layers: `config/player_tank_config.json` / `config/bot_tank_config.json` hold
per-profile **physical stats** (speed, turret turn rate, projectile speed, `max_hits`,
`self_right_cooldown_sec`), read once by `team_spawner.gd` via `_apply_tank_config()` regardless of
roster — tank-profile data, not match balance. `config/roster_*.json` holds **who** (team / role /
difficulty / count / waypoint routes). Don't confuse the two.

### Spawn system — `TeamSpawner` + `SpawnZone` (one mechanism, every map)

Every map spawns bots dynamically — a future networked PvP mode needs match-start-time composition,
not tanks baked into a `.tscn` — so every map has its own `TeamSpawner` node instantiating
`Tank.tscn`; no map has static bot nodes.

**`scenes/main/team_spawner.gd`** (`TeamSpawner`) reads a JSON **roster** from `@export var
roster_config_path`. A roster is an array of "squad" dicts:

> If a roster (or any `config/*.json`) shows a whitespace-only diff after a Godot editor session,
> it's Godot's `text_editor/behavior/files/convert_indent_on_save` (default on) reindenting the
> file while it sits open in a script-editor tab — a per-machine editor setting, fixed by turning
> it off; see the `godot-editor-convert-indent` memory. `git checkout -- config/<file>.json`.

- `team` (0/1) — which `SpawnZone` the squad spawns from.
- `count` — bots in this squad; `0`/absent → `GameConfig.team_size` (the one place team size is
  read; both current rosters give a fixed explicit count instead, since neither map runs a full
  5×5 team).
- `reserve_for_player` (bool) — when `true` and this squad's `team == MatchState.player_team` that
  round, spawns one fewer bot (the player fills the slot). Neither current roster sets this — the
  player coexists *beside* a fixed bot roster; a future full-team map would set it on both squads.
- Any subset of `TankAIController` fields (`role`, `difficulty`, `waypoint_name_prefix`,
  `waypoints_one_way`, `hunt_area_center` / `_half_extents`, `forward_look_bias`, `debug_ui_slot`,
  the three `show_*_debug` flags) — applied only if the key is present (`_apply_squad_to_brain()`);
  an omitted key keeps the script's own `@export` default.

`PlayerTank` stays a static, hand-placed node on every map (`TeamSpawner` only configures/positions
it) — full "player is just another roster slot" unification is future networking work.

**`scenes/main/spawn_zone.gd`** (`SpawnZone`) — a `Node3D` marking a circular area (`@export
radius`); team is encoded by node-name prefix (`"AttackSpawnZone"` / `"DefenseSpawnZone"`), the same
convention as `Waypoint` / `AttackWaypoint`. `pick_spawn_position()` picks a uniform-by-area random
point inside the circle (`sqrt(randf())`) and raycasts straight down (`collision_mask = 1`) to find
the ground surface, retrying up to `max_attempts` times, else returning the zone centre. Every
caller adds a small clearance (`Vector3(0, 0.3, 0)`) — spawning exactly on the raycast-hit y gives a
degenerate zero-depth floor contact Jolt handles badly (`move_and_slide()` drops the body through
the floor); a small gap lets it settle. Two call sites, both through `pick_spawn_position()`:
`team_spawner.gd` and `respawn_controller.gd` (`_on_respawn_timeout()`), both doing a recursive
`find_child` so either stays correct if a map nests its zones.

Zones default to opposite corners — both flat maps (72×72): `AttackSpawnZone` / `DefenseSpawnZone`
at `(28,28)` / `(-28,-28)`, radius 8.

**Zone "role" is a Godot group, not a name pattern.** Every `spawn_zone.gd`-scripted node has an
`@export var zone_role: String` — non-empty ⇒ the node self-registers into that group in its own
`_ready()` (`add_to_group(zone_role)`). A consumer asks for "every zone of role X" with one
`get_nodes_in_group(X)`; node *names* are load-bearing only for human-readability and (for ordered
patrol routes) sort order within the group.

`TankAIController.waypoint_routes: Array[String]` (falls back to the legacy `waypoint_name_prefix`
string when empty — old rosters keep working) lists zone roles **in the order the bot walks them**,
concatenated into one continuous patrol loop, not several independent cycles. `TargetObjectiveMap`'s
roster has two squads (one bot each): the attacker follows role `AttackWaypointN` (one-way, ends in
`ATTACK_OBJECTIVE`); the defender follows `["DefenseWaypoint", "Waypoint"]` — corner-to-centre
approach from `DefenseSpawnZone` first, then the `Waypoint1..4` diamond around the objective,
looping forever as one combined 6-point route. **A zone whose role no roster squad's
`waypoint_routes` references is dead weight** — delete it, don't leave it "just in case"
(`Tank_Prop_Hunt_Map_Creation_Guide.md` §3.5).

The waypoint collector (`_collect_waypoints()`) and the disguise hide-zone finder
(`_nearest_mortar_hide_spot()`, role `"MortarHideZone"`) both search the whole current scene via
groups. Every circular waypoint/zone marker (patrol, spawn, ammo/mod drop, `ObjectiveAlertZone`, the
disguise `MortarHideZone1`/`2`) is the same `spawn_zone.gd`-scripted `Node3D` — see the
`spawn_zone.gd` bullet under "Debug mode" for the shared debug-circle visual (keyed off node *name*
prefix, purely cosmetic — unrelated to `zone_role`).

`SpawnZone.face_center(tank)` (static, called via a `preload()`'d script reference — **not**
`class_name`, per Invariant 7) orients the tank's forward (`-basis.z`) toward the map's XZ origin
after every spawn/respawn. `look_at()` targets the tank's *own* Y (not world 0) to keep pitch/roll
at zero on flat ground; a degenerate near-origin spawn (distance < 0.01) is a no-op.

### Signals over polling

Nearly everything (`TankStateMachine.state_changed`, `HealthComponent.damaged` / `destroyed`,
`AmmoComponent.ammo_changed`, `MatchManager.round_ended`) is signal-driven; HUD and AI subscribe.
The one deliberate exception is reading `Timer.time_left` in `_process()` for the countdown
display, since `Timer` has no per-tick signal.

`HealthComponent.damaged` carries `(current_hits, max_hits, killer)`. Godot does **not** drop a
signal's extra emitted arguments when a connected method declares fewer parameters — every handler
must match the emitted arity exactly, or it's a runtime error (Invariant 6).

### Game modes

Full reference: `Tank_Prop_Hunt_Game_Modes.md` + `Tank_Prop_Hunt_Extraction_Mode.md`. Summary
below.

Three modes, keyed off `MatchState.match_mode`, each map a template for one.

**TARGET_OBJECTIVE** (`TargetObjectiveMap.tscn`): an `Objective` static body with a
`HealthComponent` (`attackers_only = true`); **objective destroyed → attack win; round timer
expires with it intact → defense win**. Round timer is `GameConfig.round_timer_sec` = **180 s**.
**Buzzer-beater rule** (`match_manager._settling_last_shots`): at timeout the defense win is not
awarded immediately — a settle phase waits until the `"projectiles"` group empties, so a lobbed
mortar that then destroys the objective still gives attack the round via `_on_objective_destroyed`.
`_SETTLE_MAX_SEC` **must stay above `Projectile.max_lifetime_sec`** or a slow arc gets cut off and
its post-buzzer objective kill is silently rejected by the `_round_over` guard. The
`ObjectiveAlertZone` (the ground circle the AI uses for `State.ALERT`) is a **child of the objective
node** (local `y = -1`), freed with it and simply absent on maps without one; every reader of
`_alert_zone` uses `is_instance_valid()` (Invariant 9).

**TEAM_ARENA** (`TeamArenaMap.tscn`, no objective node): team deathmatch,
`GameConfig.team_arena_round_sec` = **180 s / round**, round winner by kill count (ties by
`defense_wins_ties`). Sides are **fixed colour teams** — **Красные** (team 0) / **Синие** (team 1) —
never "attack"/"defense"; the HUD `TeamLabel`, score line and result screen say Красные/Синие in
this mode (Атака/Оборона in TARGET_OBJECTIVE).

**EXTRACTION** (`KitchenMap.tscn`, mode 2) — deliberately **not** CTF: reaching your base does not
score. Value passes four states and only the last one counts — a loose `LootCrate` on the map ⇒
lots inside a `CargoHold` (no nodes) ⇒ a crate parked in your base circle, ripening **linearly** at
a per-rarity rate toward a per-rarity cap ⇒ **banked** by driving it into an open evacuation point.
Each crate is one of four **rarity tiers** (weights ~0.70/0.20/0.07/0.03), rolled at allocation from
the seed; the tier sets its raw-value range, ripen rate and cap, and its colour. The match is one
round ≈10 min: five evacuation windows, first at 120 s then every 120 s, and it **ends the moment
the last window closes** — `RoundTimer.wait_time` is set from `ExtractionManager.total_match_sec()`
(`first + interval*(count-1) + duration` = 640 s), there is no fixed `extraction_round_sec`.
Everything unbanked burns; the round never ends early. The load-bearing rule is
`CargoHold.blocks_disguise()` — **cargo forbids disguise** (and slows you per crate) — which welds
the economy to prop hunt; `DisguiseController`, the HUD and the bot all read that one predicate.
Loot hides inside ordinary `Obstacle` cubes: every cube carries a `HealthComponent` and is
destructible, only some hold loot (`loot_node_count`), and the allocation is seeded
(`MatchState.loot_seed`) — a loot cube is indistinguishable from an empty one and from a disguised
tank, which is the point. Nodes never respawn: the map is meant to run out of cover.
`ExtractionManager` (code-created node, like `ScoreManager`) owns allocation, deposits, ripening,
window scheduling, the beacon and banking. A warehouse **is** the crates parked in the base circle,
which is why raiding — and scouting a rich enemy base by eye — need no code of their own.

`match_mode` is an `@export_enum` on each map root, **stored in the `.tscn`** (`TargetObjectiveMap`
= 0, `TeamArenaMap` = 1, `KitchenMap` = 2). Its script default is **`-1`, a deliberate invalid
sentinel** (Invariant 8): both real values are then non-default, so Godot's editor always
serializes the line and a GUI scene-save can't strip it. Still `-1` in `_setup_match_context()` ⇒
the line is missing ⇒ `map_scene.gd` `push_error`s and falls back to `TARGET_OBJECTIVE`.
Default-valued option lines are legitimately absent from a `.tscn` — `TargetObjectiveMap` has no
`final_stage_enabled` / `map_border_enabled` line, `TeamArenaMap` has no `map_border_enabled` line;
not corruption, don't "restore" them.

All maps run the **same round loop**: `map_scene.gd._setup_match_context()` creates a `ScoreManager`
+ a node named `"MatchManager"` (`scenes/main/match_manager.gd`), which picks its end-of-round
condition from `match_mode`, then `MatchState.record_round_result` → `round_ended`. `map_scene.gd`
also listens on `round_ended` (`_on_round_ended_teardown`): once a round is decided it **freezes the
field for the result screen** — `TeamSpawner.halt()` + every `RespawnController.halt()` +
`HealthComponent.force_destroy()` on every tank including the player. Those deaths pass `killer =
null`, so `ScoreManager._on_tank_destroyed` skips them — the displayed kill count is untouched.

The **final stage** (also `map_scene.gd`): extra time (`GameConfig.final_stage_duration_sec` = 30 s,
HUD countdown, ammo crates keep dropping, tanks respawn with ammo), then the round resolves by kill
count. **Per-map opt-in** — `@export var final_stage_enabled` (script default `false`); only
`TeamArenaMap.tscn` carries the line (on). It starts **only** at the moment the main `RoundTimer`
expires *and* every still-alive (not respawning) tank is out of ammo. It is **not** triggered
mid-round by ammo running out while the clock is going.

Side-swap between rounds (`hud.gd._on_restart_pressed`, `_has_side_swap()`) happens **only in
TARGET_OBJECTIVE**; TEAM_ARENA / EXTRACTION colour teams are fixed for the whole match, so the
restart button just reloads.

A match is **best-of-3, decided by majority of round wins per side**: `series_complete()` is true as
soon as `series_wins_attack` or `series_wins_defense` reaches `rounds_to_win()` (`total_rounds / 2 +
1` = 2). `series_winner()` returns `"attack"` / `"defense"` / `"tie"`.

The **round counter** is `MatchState.current_round_num`, a real stored field — **incremented by
`advance_round()` when the *next* round starts** (`_on_restart_pressed`), never when the current one
ends. So the result screen reads "Раунд 1/3" for round 1's outcome; the top line becomes "Раунд
2/3" only after the reload. `reset_series()` also zeroes `current_round_num` and `player_team`.

**Ammo drops** (all maps): a self-contained prefab `scenes/ammo_crate/AmmoDropZone.tscn` — the root
node itself *is* the spawn-sized ground circle (`spawn_zone.gd` on the root) plus a high dummy
`Marker3D` child (`DropOrigin`, script `ammo_crate/ammo_drop_zone.gd`). Sits in each map's two empty
corners. Cadence is **map-level, not per-zone**: the drop zones join group `ammo_drop_zones`, the
lowest-`get_path()` one is the leader and owns the sole `DropTimer`; every `drop_interval_sec`
(30 s) the leader drops **one** `AmmoCrate` at a **random** zone (`shuffle` + first that accepts).
The crate falls kinematically to a random clear point in that zone's circle, never overlapping a
still-unpicked crate (`min_crate_separation`, per-zone cap `max_pending_crates` →
`GameConfig.ammo_crate_count` — these three stay per-zone; only the interval + round-end stop are
centralized on the leader). Pickup is `Area3D.body_entered` → `AmmoComponent.add_ammo`. Full detail:
`Tank_Prop_Hunt_Ammo_Drops.md`.

**Modification crates** (TARGET_OBJECTIVE and EXTRACTION maps): the same drop-zone leader also runs
a `MortarDropTimer` that drops one **red `ModCrate`** in *every* zone simultaneously (not one at a
random zone). A `ModCrate` fills the tank's `ModificationController` slot with the mortar mod when
empty. Cadence is `GameConfig.mortar_drop_interval_sec` (30 s) in TARGET_OBJECTIVE and the rarer
`mortar_drop_interval_container_sec` (75 s) in EXTRACTION, where the mortar is meant to be an
occasional complication. `TeamArenaMap.tscn` starts no such timer. Full detail:
`Tank_Prop_Hunt_Modifications.md`.

The **HUD match block** (top-center, all maps, `hud.gd`): line 1 `Раунд N/M | MM:SS`; line 2 the
mode-dependent overall score — TARGET_OBJECTIVE: series only (`По раундам — Атака N : M Оборона`);
TEAM_ARENA: round kills + series, all by colour (`Убийства  Красные K : L Синие      Раунды  N :
M`, Красные = `series_wins_attack`, always the left number); line 3 `Цель: N/M попаданий` —
objective health, TARGET_OBJECTIVE only, resolved via group `"objective_health"` (not by node
name); line 4 the player respawn countdown (`Респаун через N с`) shown only while
`PlayerTank/RespawnController.time_until_respawn() > 0`. The HUD resolves `MatchManager` /
`RoundTimer` / `ScoreManager` / objective **lazily** and polls them, because `map_scene.gd` creates
those nodes in code *after* the HUD's own `_ready()`.

### Debug mode

All debug scaffolding is gated behind a single session flag, **`MatchState.debug_enabled`**
(autoload, readable in every `_ready()`; survives `reload_current_scene()`; `reset_series()` does
**not** touch it). Set by a checkbox in the map-select menu (`main_menu.gd` → `_go()`), **default
checked / ON**. Launching a map scene directly (editor / `run_project` with `scene:`) leaves it at
its `true` default, so the dev workflow stays debuggy with no extra step.

What the flag gates (each also keeps its finer per-instance filter, e.g. the bot's `show_*_debug`
`@export`s):
- `map_scene.gd` — the `Игрок: бессмертие ON/OFF` button *and* the forced `_player_health.invincible
  = true` it sets (so with debug OFF the player is mortal); the `Objective: ON/OFF` button; the
  1/2/3 observer-camera keys; the `+ Бот (атака)` / `+ Бот (оборона)` buttons
  (`TeamSpawner.spawn_one_bot(team)`); the `Реакция ботов на игрока ON/OFF` button (toggles
  `MatchState.bots_ignore_player` — off = bots stop perceiving the `PlayerTank` node as an enemy,
  gated in `TankAIController._can_see()` / `_on_damaged()`; bot-vs-bot unaffected).
- `tank.gd` — the billboard `Label3D` "HP N/M" above each tank. The team-colour mesh tint
  (`apply_team_visuals()`) is **not** gated — it always applies.
- `tank_ai_controller.gd._initialize()` — FOV-cone / nav-path / brain-panel overlays (setup **and**
  the `_physics_process` update calls, so the meshes/labels are never touched when null). The FOV
  cones can clip at the first obstacle/tank blocking line of sight — gated by its own sub-toggle,
  `MatchState.fov_debug_clip_obstacles` (default **off**: full-radius cones, zero extra raycasts;
  flip it from code for a point-in-time LOS check, no UI button). Cost analysis: Bot AI vault doc
  §17.
- `spawn_zone.gd` — the on-ground debug circle. **Every circular area marker in the project is this
  one script / one visual** (per-instance `@export radius`, movable/scalable in the editor): spawn
  zones, the ammo/mod drop-zone circle (the `AmmoDropZone` prefab **root** runs this script),
  `ObjectiveAlertZone`, patrol waypoints, the disguise `MortarHideZone1`/`2`. Colour by name
  prefix: `Attack*` / `Defense*` — red/blue; a bare `Waypoint*` — also blue; `MortarHide*` —
  purple; team-neutral (`ObjectiveAlertZone` / `AmmoDropZone`) — yellow. An **editor-time mirror**
  of the same rings (`addons/zone_gizmos/zone_gizmo_plugin.gd`, a `@tool`
  `EditorNode3DGizmoPlugin`) draws identical circles in the viewport, reading the same `radius` /
  name convention — keep both in sync. `spawn_zone.gd` is itself `@tool`: dragging the node's Scale
  gizmo auto-converts the scale factor into `radius` and resets scale to `(1,1,1)`
  (`_sync_radius_from_scale()`, `NOTIFICATION_TRANSFORM_CHANGED`, editor-only) — `radius` is the one
  source of truth for both circles *and* the gameplay radius. A committed `.tscn` should never
  carry a non-identity `scale` on one of these nodes; if you see one, open in the editor and nudge
  the transform once to normalize it.

**RELEASE TODO (Steam / release prep):** the menu checkbox is a *development-stage* entry point in
the normal player-facing menu. Before release, gate debug mode behind a command-line flag / dev
build / debug export instead (or strip it). Duplicated in `MatchState.debug_enabled`'s doc-comment
and in a `project` memory — do not silently ship the visible checkbox.

### `scenes/tank/tank_ai_controller.gd` — the one universal bot brain (`TankAIController`)

Single AI system for the whole project — every map deploys the exact same node/script. Lives as a
dormant sibling on every `Tank.tscn` instance (player included) and lazily self-inits on the first
enabled `_physics_process()` tick. A **23-state** priority engine (`enum State`: `IDLE`, `PATROL`,
`ATTACK`, `HUNT`, `PURSUE`, `SEARCH`, `ATTACK_OBJECTIVE`, `ALERT`, `DEAD`, `AMMO_SEEK`,
`AMMO_RETRIEVE`, `AMMO_WAIT`, `MOD_SEEK`, `MOD_RETRIEVE`, `MORTAR_ATTACK`, `DISGUISE_APPROACH`,
`DISGUISE_PREP`, `DISGUISE`, `OBJECTIVE_CHECK`, `LOOT_SEEK`, `LOOT_DELIVER`, `EXTRACT_RUN`,
`FARM_NODE`) with a NavMesh-based driving stack (pure pursuit + emergency brake + stuck detector +
gap-scan detour; the emergency brake's forward ray ignores hits whose normal is a walkable slope,
`normal.y > 0.72`, so a rising ramp surface doesn't read as a wall). Two roles (`ACHIEVER` /
`KILLER` — `ACHIEVER` self-degrades to `KILLER` behaviour at init if the map has no objective),
three difficulty tiers. Integrates with the shared `RespawnController` / `HealthComponent` /
`AmmoComponent` / `ModificationController` (death state, alert-on-hit, ballistic aim, ammo-crate
seeking, mortar pickup and use). Objective / waypoint / ammo-zone lookups are group- or
recursive-search based, so the same file works unmodified on any map.

Disguise: bots activate only via scripted ambush scenarios (`disguise_s1/s2/s3`, roster-gated);
`_can_see()` hides a `DISGUISED` enemy from *acquisition* but not from a bot already fighting it
(`ignore_disguise` param — see `DisguiseController` and `Tank_Prop_Hunt_Disguise.md` §5).

In EXTRACTION the same brain runs the whole economic cycle with no new role (that mode has no sides
— both teams do the same thing): `FARM_NODE` shoots a cover cube without knowing whether it holds
anything, `LOOT_SEEK` drives to a crate, `LOOT_DELIVER` hauls it to the team warehouse,
`EXTRACT_RUN` performs the evacuation trip — empty to the warehouse for exactly one crate, then to
the announced point. The cycle outranks even the out-of-ammo gate (value must be moved even
unarmed); a loaded bot never commits to a fight, only snap-fires. An enemy **carrier** is a
priority target for both sides. Raiding needs no special code: `_nearest_free_loot()` takes loose
crates always but enemy-warehouse crates only when the bot can actually **see** them. A crate claim
goes to the *nearest* ally (ties by instance id, so two bots never re-pick in lockstep). Bots start
a run on the **announcement**, not the opening — the lead time exists so the trip can be completed.
Detail: `Tank_Prop_Hunt_Extraction_Mode.md` §7.

**Ledge check** (`ledge_check_enabled`, roster-gated, default off — a property of the *map*; flat
maps would only burn raycasts): the driving stack probes horizontally, so it sees a wall but not
the edge of a counter. A downward probe ahead feeds both `_check_emergency_brake()` and
`_scan_gap()`. A drop is judged by **steepness, not height** — descending a ramp is a drop too — by
comparing the drop at each probe distance against what a drivable slope would give (`dist *
tan(ledge_max_slope_deg) + ledge_slack`). Its fan is deliberately narrower than the brake's, or a
bot would stop mid-descent on seeing the void beside its own ramp. Detail:
`Tank_Prop_Hunt_Kitchen_Map.md`.

**Full architecture reference — states, priority ladder, driving-stack internals, per-tier
parameter tables, scene inventory — lives in `Tank_Prop_Hunt_Bot_AI_Sandbox.md`**; read it before
non-trivial work on this file.

### Obstacle prefab system — `scenes/obstacles/` (universal, every map)

Map geometry is **instances of prefab scenes**, not hand-built `StaticBody3D` + `CollisionShape3D`
+ `MeshInstance3D` triples inside each map `.tscn`. Nothing looks obstacles up by name.

- `Obstacle.tscn` (`obstacle.gd`, `@tool`, `extends StaticBody3D`) — any solid box: crate, block,
  wall-cover. `@export size: Vector3` / `@export color: Color` drive the child `BoxShape3D` +
  `BoxMesh` + material (defaults `2×1.25×2`, brown — matches `GameConfig.disguise_prop_*`).
  `collision_layer = 1` / `collision_mask = 0` baked into the prefab so the NavMesh baker sees it.
  It doubles as the disguise prop, and in EXTRACTION it carries a `HealthComponent` so every cube
  is destructible and some hide loot. **Wiped by the dynamic-obstacle pass.**
- `HazardZone.tscn` (`hazard_zone.gd`, `@tool`, `extends Area3D`) — impassable area, `@export size`,
  translucent-red material, `collision_layer = 4`.
- `Structure.tscn` (`structure.gd`, `@tool`) — **permanent level geometry** (furniture, walls,
  counters, shelves): the same box as `Obstacle` but in group `"structures"`, not `"obstacles"`.
  The split is load-bearing: the dynamic-obstacle pass deletes the whole `"obstacles"` group, so a
  map built from `Obstacle` would be wiped to bare floor by the menu checkbox.
- `ToyRamp.tscn` (`toy_ramp.gd`, `@tool`) — the only incline primitive. `@export run` / `rise` /
  `width` / `thickness` / `color`; place the node at the **bottom** of the incline and yaw it — the
  top end lands exactly `run` forward (along the node's `-Z`) and `rise` up. `rise = 0` gives a
  flat plank (bridges, and the landing pads that make diagonal ramps connect to platforms). Needed
  because the tank has no step-up: vertical connectivity rests entirely on slopes.

All three sub-resources in each prefab are `resource_local_to_scene = true` so per-instance `size` /
`color` don't bleed across instances. After add/move/resize/delete the per-map NavMesh needs a
manual re-bake (`Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md`).

`obstacle.gd` / `hazard_zone.gd` each self-register into a group at runtime (`"obstacles"` /
`"hazard_zones"`, editor-hint-guarded); `spawn_zone.gd` registers **every** circular zone marker
into `"zone_circles"` (on top of its optional `zone_role`). These three groups exist for the
dynamic-obstacle system.

### Dynamic obstacle system — random pre-match layout (per-map, opt-in)

Two presets per map: **static** (obstacles hand-placed in the editor — the default) or **dynamic**
(up to 30 brown cubes placed at random before the match, so networked players can't memorise cover
/ disguise spots). Chosen by a menu checkbox → `MatchState.dynamic_obstacles` (plain flag, not
debug-gated; survives `reload_current_scene()`). **HazardZones are never touched** — always
editor-placed, and they act as placement constraints for the dynamic pass.

- `scenes/obstacles/dynamic_obstacle_placer.gd` (`extends RefCounted`, no `class_name`, static API
  `populate(map_root, nav_region, seed) -> int`) — ≤ `MAX_OBSTACLES` (30) cubes, none inside any
  `"zone_circles"` circle (+ clearance), none inside any `"hazard_zones"` / `Objective` /
  `"turrets"` AABB (+ clearance), no cube-cube overlap, all within `Ground` minus `EDGE_MARGIN`.
  Fully analytic + synchronous (one down-ray per cube for ground Y); `RandomNumberGenerator` with an
  explicit `seed`, calls in fixed order ⇒ **deterministic**: same seed ⇒ byte-identical layout on
  any machine. That's the netcode hook — host sends one int, every peer builds the same map.
- `map_scene.gd._apply_dynamic_obstacles()` (`await`-ed from `_ready()` right after
  `_build_map_borders()`, before `TeamSpawner.spawn_team()`) — sets the region's
  `geometry_parsed_geometry_type = PARSED_GEOMETRY_STATIC_COLLIDERS` (colliders only — fast, no
  GPU→CPU mesh readback), then loops: `remove_child` every `"obstacles"` node → `populate()` →
  `bake_navigation_mesh()` + `await bake_finished` + `await physics_frame` → **connectivity check**
  (`NavigationServer3D.map_get_path` for attack-spawn↔defense-spawn and each spawn↔objective; a
  partial path — last point > 5 m from target — counts as broken). If a layout isolates something
  it **re-rolls the seed** (up to `_DYNAMIC_MAX_REROLLS` = 4), then proceeds with a `push_warning`
  if still broken. The seed left in `MatchState` is the one that produced a connected map — that's
  what rounds 2–3 and (future) netcode peers use. Bots lazy-init after `_ready()` so they start on
  the fresh nav map.
- **Layout lifetime = one match.** `dynamic_obstacles_seed` is held across rounds so rounds 2–3
  replay the same layout; zeroed by `MatchState.reset_series()` → next match re-rolls. Not
  persisted between sessions.
- **HazardZones don't carve the navmesh** — in either bake mode (`geometry_collision_mask = 5`
  effectively only cuts layer 1). Bots avoid hazards **reactively** — the AI's `_cast_ray_dist`
  avoidance rays (`collide_with_areas`, mask includes layer 3) see the `Area3D`, so the A* path may
  cross a hazard but gap-scan / emergency-brake deflect the bot. True carving would need
  `NavigationObstacle3D` (`affect_navigation_mesh`) — out of scope.
- Benign per-bake log noise: `agent_max_climb / agent_radius ... loses precision` — the map's
  navmesh values aren't multiples of `cell_size` / `cell_height`; fires for the editor bake too.

### Stationary turret system — `scenes/turret/` (universal, any map / any mode)

`Turret.tscn` is its own prefab — a "tank that can't move", dropped as an instance into any map's
`.tscn` per side (`@export team` on the root), no spawner or autoload. Full reference:
`Tank_Prop_Hunt_Turrets.md`. Points that touch the rest of the codebase:

- `turret.gd` (`@tool`, `extends StaticBody3D`, `collision_layer = 1`) — shell only: team +
  `apply_team_visuals()` (same reusable-`StandardMaterial3D` idiom as `tank.gd`), `body_size` cube
  sync, `HealthComponent` wiring (`max_hits` **10**, `free_on_destroy = true` — the node vanishes on
  death, **no respawn**), a debug `Label3D` "HP N/M" (gated by `MatchState.debug_enabled`),
  `add_to_group("turrets")`, and a `call_deferred` hook onto `MatchManager.round_ended` → disable
  `TurretAI` for the results screen (it's **not** in `"tanks"`, so `map_scene._on_round_ended_teardown`
  never `force_destroy`s it).
- `turret_ai.gd` (`extends Node`, no `class_name`) — 3-state brain (SEARCH 360° turret sweep /
  ATTACK / RELOAD), lazy `_initialize()` on the first enabled `_physics_process` tick like
  `TankAIController`. Reuses `turret_controller.gd` on `TurretPivot` and `barrel_controller.gd` on
  `Barrel` unchanged (both `is_player_controlled = false`, external `target_yaw` / `target_pitch`;
  their `CameraRig` / `TankStateMachine` lookups are null-safe). Fires plain `Projectile` (`damage`
  1) directly, `shooter = turret root`. MEDIUM `@export`s + EASY/HARD `_DIFFICULTY_PRESETS`. Fire
  cadence `shot_interval_sec` = **3 s** (= `GameConfig.reload_duration_sec`), 10-round `mag_size`,
  5 s `reload_sec`. `min_fire_range` (3 m, **XZ** distance) is a near **blind**-zone — a target
  inside it drops out of `_can_see()` entirely (acquire *and* hold), not just a fire gate. Narrow
  `detect_cone_deg` (18°) for acquisition, wide `track_cone_deg` (200°) for holding. `_can_see()`
  respects the disguise gate; the turret can't disguise or pick up crates/mods (no entry points;
  wrong collision layer).
- **ALERT target-share**: `TankAIController._notify_team_of_alert_target()` — after its loop over
  allied tanks in `State.ALERT` — also loops `get_nodes_in_group("turrets")` of the same team and
  calls `turret_ai.on_alert_target_shared(target)`. The turret slews its barrel to that target and
  enters ATTACK once it has real LOS/range (recon share, not vision teleport).
- **"Mortar on the objective kills the guard turret first"** is geometry, not redirect code: the
  test turret sits physically on the objective's top face (`ObjectiveTurret`, instance transform
  `(0,2,0)` under `NavigationRegion3D` in `TargetObjectiveMap.tscn`), so a plunging mortar arc
  aimed at the objective enters the turret's collider first and is consumed; a flat cannon shot
  passes under the turret and still reaches the objective's side.
- Debug FOV/fire-sector overlay (`show_fov_debug`, gated by `MatchState.debug_enabled`) — an
  `ImmediateMesh` child of the turret root, ground-plane fan rotated by the live turret yaw:
  detection-cone fill (colour by state), `fire_range` arc, `min_fire_range` inner arc, barrel line.
  Same obstacle-clip raycasts as `TankAIController`'s FOV debug (same `fov_debug_clip_obstacles`
  toggle, same default off), cast ground-level — a barrel-height ray from the turret's perch atop
  the objective sails over normal-height obstacles (`Tank_Prop_Hunt_Turrets.md` §4).

### Map inventory

`run/main_scene` is `scenes/main_menu/MainMenu.tscn` — a plain `Control` scene, four buttons, each
calling `get_tree().change_scene_to_file()` at one of the scenes below; no game logic of its own.
Launch any directly via `run_project`'s `scene:` param (or repoint `run/main_scene`) to skip the
menu.

- `scenes/maps/TargetObjectiveMap.tscn` — TARGET_OBJECTIVE template: an `Objective` at the map
  centre `(0,1,0)` (no central wall — the centre is the objective), the `Waypoint1..4` defender
  diamond around it, one defense bot (`ACHIEVER`) and one attack bot (`ACHIEVER`, one-way route to
  the objective), plus an `ObjectiveTurret` (`Turret.tscn` instance, `team = 1`) on top of the
  objective as a complication (see "Stationary turret system"). Balance knobs stay single-sourced:
  mortar damage is `GameConfig.mortar_objective_damage`, the alert-circle radius is
  `ObjectiveAlertZone.radius` in the `.tscn`; values live only in the two param tables
  (`Tank_Prop_Hunt_Modifications.md` §8, `Tank_Prop_Hunt_Map_Creation_Guide.md` §2.4).
- `scenes/maps/TeamArenaMap.tscn` — TEAM_ARENA template, purpose-built for the `KILLER` role: one
  `KILLER` bot roaming the whole map, `ObstacleN` bodies spread across the map (vs.
  `TargetObjectiveMap`'s single cluster on the defense approach), its own rebaked NavMesh, no
  objective node. Not the default scene — launch it explicitly.
- `scenes/maps/KitchenMap.tscn` — EXTRACTION template and the project's only **multi-level** map: a
  toy-scale kitchen (**24 units = 1 m**, tank ≈ 7.5 cm) on a 108×84 floor, six height tiers (floor
  0 · chairs/stool 10.8 · sink 15.6 · table 18 · counter 21.6 · shelf+cabinet 30 · shelf+fridge
  43.2) joined only by `ToyRamp` inclines. Bases sit on surfaces (attack on the table, defense on
  the counter) and double as **warehouses**; five `ExtractionPoint`-role markers spread over the
  tiers are the evacuation-point candidates. Its ~20 `Obstacle` cubes are cover, disguise props
  **and** the loot nodes at once. It bakes its navmesh at load (`bake_navmesh_on_start`) instead of
  storing it, and opts out of dynamic obstacles (`dynamic_obstacles_supported = false`). **Before
  editing its geometry read `Tank_Prop_Hunt_Kitchen_Map.md`** — ramps must stay ≤ 24° (a box
  `CharacterBody3D` stalls dead at ~28° despite `floor_max_angle` 45°), must end exactly on a
  platform edge, must not lie flat across a platform, and a diagonal ramp needs a flat coplanar
  landing or the navmesh silently splits into islands.
- `scenes/maps/TestGroundMap.tscn` — **not a map and not a mode**: the chassis proving ground
  (`test_ground.gd`). No `map_scene.gd`, no `MatchManager` / roster / HUD / navmesh — just the
  player tank, a dummy tank and a code-built course (ramps 6°…48°, a row of 0.04…0.40 lips,
  washboard, smooth waves, a side slope, a jump, an **"Обрыв"** raised platform with sheer edges for
  the brink/tumble system) plus a readout of hull pitch/roll, sag, the slope-speed multiplier and
  the edge state (`зазор ЦМ`, `подход %`, `крен`, TEETER / КУВЫРОК). Keys: `R` reset, `T` terrain
  tilt on/off, `Y` running-gear animation on/off, `F` readout. Re-measure the collider chamfer's
  limits here (ramps up to 44°, lips up to 0.20) after any change to the collider or to
  `move_speed` / `acceleration` rather than trusting a number from another map. Detail:
  `Tank_Prop_Hunt_Tank_Chassis.md` §10.

## External Godot skill library

`~/.claude/skills/godot/skills/` holds ~100 `godot-*` skills (the third-party `gd-agentic-skills`
pack + four first-party workflow skills). The full index — one-line purpose per skill plus a **USE
/ LATER / SKIP** classification for this project — lives in `Claude Common/godot-skill-catalog.md`,
kept cross-project on purpose. Consult that file before loading a `godot-*` skill here: most genre /
platform / 2D / adaptation skills are a paradigm mismatch for a 3D desktop tank shooter and the
catalog says which, while the LATER list flags the ones that become relevant at a named roadmap
phase (art, modules, meta shell, networking, production) so they aren't forgotten. The pack is a
reference to check against, not a source of truth — this `CLAUDE.md` and the vault docs win on any
conflict.

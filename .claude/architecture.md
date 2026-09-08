# Tank Prop Hunt — Architecture (detail)

Deep reference for every in-repo system. `CLAUDE.md` carries the one-paragraph map of
this file plus the load-bearing invariants; read that first, come here for the mechanism.
Vault docs (`C:\Users\PC\Documents\Personal Vault\Tank Props Docs\`) remain the source of
truth for anything marked "full detail: `Tank_Prop_Hunt_*.md`".

## Component + system detail

### Tank as a composed entity, not a god-object

`scenes/tank/Tank.tscn` is the single reusable scene for both the player's tank and every bot
(`scenes/main/team_spawner.gd` instances it N times). All behavior lives in sibling components
under the root (`tank.gd`, which holds `team`/`is_attacker()`, the **team-colour mesh tint**
via `apply_team_visuals()` — `GameConfig.team_attack_color`/`team_defense_color` applied by a
recursive walk of the `Hull` and `Turret` subtrees (the armour is code-built, there is no fixed
node list) minus the running gear and the mortar attachment (`_DARK_PART_PREFIXES`), called by
`team_spawner.gd` after `team` is assigned and by
`RespawnController` via `on_respawned()` — and, **debug-mode only**, a billboard `Label3D` "HP
N/M" above the tank updated on `damaged`/`destroyed`/respawn; this replaced the old red
"подранок" material swap so it doesn't fight the team tint), each independently
toggled between player and AI control via its own `is_player_controlled: bool`:

- `Hull` (`hull_rig.gd`) — the **visual** hull pivot: everything you see of the chassis (armour
  boxes, glacis, sponsons, turret ring, road wheels, drive sprocket/idler, the `MultiMesh` track
  cleats) is built **in code** as its children (`@tool`, children get no `owner`, so a GUI save of
  `Tank.tscn` can't serialize them). It also owns the **terrain tilt**: four downward rays at the
  hull corners give the support plane's pitch/roll plus the sag of a box collider resting on a
  slope edge, on top of which come accel dive/squat and outward roll in a turn, exponentially
  damped and clamped to `max_tilt_deg`. The tank **root never tilts** — forward/right, aim, turret
  yaw and the whole bot brain read the root's basis. `Turret` **is a child of this pivot**
  (`Hull/Turret`), so the ring tilts with the deck and the turret keeps exactly one degree of
  freedom, rotation about the tilted deck normal — the real thing. Track/wheel speeds are per side
  (`v = v_forward ± ω·gauge`), so a neutral turn spins the two tracks in opposite directions.
  Full detail: `Tank_Prop_Hunt_Tank_Chassis.md`.
- Because the turret tilts, **local gun angles are no longer world angles**, and that split is
  load-bearing. `BarrelController.target_pitch` keeps its old meaning — the *ordered* elevation in
  **world** terms (that is what the player's camera pitch, the bot's ballistic solution and the
  mortar solution all produce); `barrel_controller.gd` converts it to a local angle by subtracting
  `mount_pitch()` (the ring's own tilt along the turret's facing) and clamps *that* to
  `min_pitch_deg`/`max_pitch_deg`, because a real gun's elevation limits are set by the trunnions
  in the turret, not by the horizon. On flat ground `mount_pitch()` is 0 and behaviour is
  identical to before. Anything checking "is the gun on target" must read `world_pitch()`, never
  `rotation.x` — on a slope those differ and a comparison against the local angle would never
  converge, i.e. bots would stop firing (three call sites in `tank_ai_controller.gd` use it, plus
  `world_pitch_limits()` to clamp the ballistic solution). Consequence by design: on a climb the
  gun cannot depress to the horizon — measured on a 24° ramp, the reachable world window is
  `[+7°, +42°]`, and the crosshair shows it honestly since it is built from the barrel's live
  basis. Normal-shell elevation is capped at **20°** (the mortar raises the cap to 85° while
  aiming and restores it). Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §4.
- `CameraRig` stays on the **root** (the camera must not rock with the hull), but it now lifts as
  the aim rises: pitching the rig up swings the camera down and back (`y = −L·sin θ`), so the tank
  itself used to block the top of the frame — exactly where you are aiming. `pivot_height`
  2.0 → 3.0 and `spring_length` 6.0 → 3.2 interpolate by `smoothstep` over the up-pitch range, so
  at the top of the aim the camera clears the turret roof (0.87) at 1.65 and sits close behind.
  Looking down is untouched. Camera `pitch_max_deg` 25° keeps a margin over the gun's 20°.
- The tank's **collider** (`CollisionShape3D` on the root) is a `ConvexPolygonShape3D`, not a box:
  same `1.2 × 0.6 × 1.8` bounding size at `+0.3` y, but the bottom **nose and tail edges are
  chamfered** (0.24 × 0.28, ≈40°; the sides stay square — that's where the tracks are). A square
  box jams its front-bottom edge into any vertical face and stops dead: before the chamfer the
  tank could not mount even a **0.04** lip (7% of hull height) and stalled on a 36° ramp — which
  is what the "practical slope limit ~24-25°" folklore actually was. With it, lips up to **0.20**
  and ramps up to **44°** are climbed, so the ceiling is now `floor_max_angle` (45°) exactly as
  the engine promises. Bounding half-extents are unchanged, so
  `disguise_controller.HULL_HALF_EXTENTS` and every AABB rule built on it still hold. Detail:
  `Tank_Prop_Hunt_Tank_Chassis.md` §3.1.
- `TankMovement` — tracks, reads `Input` or `ai_move_input`/`ai_turn_input`. Only forward/back +
  hull rotation are ever commanded (no strafe axis exists), but `move_and_slide()` on its own will
  still glide the body sideways along a collision tangent when it contacts geometry at an angle —
  normal for a generic character, wrong for a tank. `_physics_process()` corrects for this every
  frame: after `move_and_slide()`, it discards whatever component of the frame's *actual* resulting
  displacement/velocity is perpendicular to the hull's forward axis, keeping only forward/back. Found
  via the bot-AI obstacle-avoidance work (see the Bot AI vault doc) when the bot visibly skidded
  sideways brushing a corner — same underlying `move_and_slide()` behavior applies to the player
  too, just less obvious since a human steers away from corners instinctively.
  It also owns **fall damage** (`_track_fall_damage()`), for the same reason: this is the only node
  that already holds vertical velocity, gravity and `is_on_floor()`. While airborne it tracks the
  peak height and on landing charges the *height difference* (not impact speed — that under-reads
  after a scrape along a ledge) as 0/1/2/3 HP by the `GameConfig.fall_damage_*` thresholds, via a
  normal `take_hit(killer = null)` so debug invincibility still applies and `ScoreManager` credits
  nobody. Reset on `RespawnController.respawned`. Only matters on multi-level maps; flat maps never
  reach the 8-unit floor threshold.
  It also scales the target speed by the **slope** under the tracks (`_slope_speed_multiplier()`,
  `slope_speed_*` exports; softened to `penalty 0.9` / `min_mult 0.65` — 1.1/0.5 crawled bots up
  kitchen ramps): uphill slower, downhill slightly faster, from `get_floor_normal()` — no second
  ray of its own. Same path for player and bots. Flat maps are unaffected (vertical normal ⇒
  multiplier exactly 1.0); it only bites on the kitchen and the proving ground.
  It also has a **step-up assist** (`step_up_*` exports): after `move_and_slide()`, if the tank
  advanced far less than commanded and a low near-vertical face is dead ahead with walkable ground
  ≤ `step_up_max` (0.35) on top, lift the body onto it — the box collider's chamfer only clears
  0.20 lips, and ramp feet / furniture-plate joints / a table edge under a ramp exceed that.
  No-ops on flat ground and on smooth ramps (it checks for a wall-like face, not a slope).
  It also owns the **ledge / brink / tumble system** (`_update_support()` + `_integrate_teeter()`,
  `ledge_*` / `teeter_*` exports), same reason again — this node holds gravity + `is_on_floor()`.
  `CharacterBody3D.is_on_floor()` is a binary "any contact", so one edge on a platform lip kept the
  tank glued with ¾ of the hull over a pit (and the root never tilts, so it couldn't topple).
  **Support model**: four **directional edge-marches** (F/B/L/R, step outward, find where ground
  ends — a drop steeper than `ledge_max_slope_deg` at that reach is a cliff, shallower is a slope;
  same "by steepness not height" idea as the bot `ledge_check`) + a centre-ground probe + a
  horizontal wall pre-check per direction (a wall ahead ≠ a cliff) + a **gap tolerance**
  (`ledge_gap_tolerance` 0.5 m — a joint between furniture / a ramp lying on a table edge is a
  *seam*, not a cliff: the march steps over it). Without it every seam briefly registered as an
  edge → the tank entered TEETER crossing it → a forward surge + nose-dip on every joint.
  `_com_margin` (signed: <0 CoM on support with that much room, >0 past the edge) varies
  **continuously** as the tank creeps toward a lip. CoM is a real offset (`center_of_mass`, low + slightly rear); on a slope the margin
  is shifted **downhill** by `center_of_mass.y·tan(slope)` (`com_slope_shift_enabled`) — a taller
  CoM / a downhill edge tips sooner. **Three stages, no abrupt switch** (this replaced an instant
  flip-to-tumble + camera yank): **BRINK** — CoM within `teeter_brink_margin` of the edge but still
  on support: tank auto-slows the throttle toward the void (`teeter_brake`, floored at 40%) and the
  hull noses down to `teeter_prelean_deg`, **steering still on**, fully recoverable by turning away
  or reversing. **TEETER** — CoM past the edge: hull tip angle integrates upward (`teeter_gravity_gain`)
  vs reverse-throttle pull (`teeter_recover_gain`) + damping, steer off, drift toward void, still
  reversible. **POINT OF NO RETURN** — `_tip_angle ≥ teeter_ponr_deg` (26°), or airborne after a
  real brink / `jump_grace_sec` with no support: hands to `TumbleController` **with the current
  angular velocity** (no snap). A level launch (trampoline) has `_edge_approach ≈ 0` ⇒ never a
  tumble. Falling breaks disguise (`"fell"`) / overrides mortar hull-freeze.
  `ledge_max_slope_deg` **must stay well above the ~44-45° climb limit**, and the centre/march
  probes need generous vertical reach (`_CENTER_REACH_DOWN`, `_EDGE_CLIMB_TAN`) or a tank perched
  nose-up on a steep ramp reads as "off a cliff" — both broke ramp climbing during development.
  Flat maps: no edges found ⇒ `_com_margin` deeply negative ⇒ zero behaviour change (verified: 0
  false brink/tumbles in 600 frames). Visual crest wobble ≈6° on a 44° ramp (the limit), no
  tumble. The hull tip for all stages is `hull_rig.gd` (`fall_tip_enabled`, reads
  `TankMovement.tip_angle()`). Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §8.
- `TumbleController` (`tumble_controller.gd`) — the tank falling off a cliff naturally (roof /
  side / belly landings) and righting itself turtle-style after a cooldown. The root must stay
  upright (bots/aim/turret read its basis), so on the commit from `TankMovement` an **invisible
  `RigidBody3D` proxy** (same convex shape, env-only collisions) takes over: **free fall, not a
  staged flip** — it gets the tank's linear velocity and *only* the teeter's actually-accumulated
  tip rate (`_tip_vel`, capped by `tumble_spin_max`); no baseline spin, no randomness, no
  speed term. Whether it lands on its tracks or its roof is decided by physics: the proxy is given
  the tank's **real low centre of mass** (`CENTER_OF_MASS_MODE_CUSTOM`, read from
  `TankMovement.center_of_mass` — one source of truth), which does nothing in free fall but acts as
  a pendulum **on impact** and rolls the hull back onto its tracks, plus `proxy_angular_damp` (0.35)
  bleeding spin in flight. Measured off the 18 m kitchen table: damp 0.15 ⇒ nearly always ends on
  its side; 0.4+ ⇒ always perfectly on tracks (self-right becomes dead code); 0.35 is the middle —
  clean falls land on tracks at any throttle, a genuinely inverted tank still rights normally. The
  old seed was artificial (1.0 baseline + speed·0.5 + random ≈ 4–5 rad/s, ~a revolution per second)
  and put the tank on its roof almost every time. Each frame the proxy's transform is
  copied onto the tank root so every code-built visual rides along. Sibling components are frozen
  (`process_mode`, the death-freeze idiom), the root collider is off. **Camera is GTA-style**
  (`camera_rig.set_tumble_follow(true)`): the *same* free mouse orbit (`_world_yaw`/`_pitch`) but
  built in a virtual **upright** frame at the tank's position — the tank spins freely on all axes,
  the camera follows the point and stays level (no reparent). On settle: deck within ~35° of up ⇒
  recover now; else wait `self_right_cooldown_sec`, kinematically flip the proxy upright (yaw
  kept), swap back to the `CharacterBody3D`, unfreeze, `set_tumble_follow(false)`,
  `hull_rig.reset_pose()`, emit `recovered` (`TankMovement` + `TankAIController` resync on it).
  Fall-damage-on-impact lives here now (`GameConfig.fall_damage_*`). `self_right_cooldown_sec` is
  in `config/*_tank_config.json` (per-profile, upgradeable later); other thresholds are `@export`s.
  Death mid-tumble (fall damage / round-end `force_destroy`) ⇒ `_abort_dead()` leaves the wreck for
  the normal respawn to right and does **not** touch the freeze/collider (RespawnController owns
  those on death); `respawned` also aborts. `TumbleController` is excluded from
  `RespawnController._set_frozen` so it can finish. **This is the only time the root is not
  upright** — a documented carve-out from the "root never tilts" invariant, safe because every
  reader of the root basis is frozen
  meanwhile. Detail: `Tank_Prop_Hunt_Tank_Chassis.md` §8.1.
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
  everyone else sees the prop only. Bots activate disguise only via three scripted ambush scenarios
  (`disguise_bot_enabled` + `disguise_s1/s2/s3_enabled` from the roster — `config/roster_target_objective.json`
  enables all three; see `Tank_Prop_Hunt_Disguise.md` §5.2), never opportunistically. A bot **won't acquire** a
  disguised enemy (`TankAIController._can_see()` returns false in `_scan_for_target()` while the
  target's `TankStateMachine` is `DISGUISED`, unless `GameConfig.ai_can_see_disguised_tanks`) — but a
  bot **already in `ATTACK` on that tank keeps firing** through the disguise (`_can_see(target,
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
  no `id == &"mortar"` checks. A `Modification` with `behavior_scene = null` is legitimate and
  used: `scenes/modifications/container.tres` is exactly that — the CONTAINER_EXTRACTION container
  occupies the slot and does nothing else, which is what gives "no other mod while carrying" for
  free and keeps `ai_usable()` false so a carrier isn't mistaken for a mortar carrier.
  The only behavior so far is the **mortar**
  (`scenes/modifications/mortar/{mortar_behavior.gd,Mortar.tscn}`): a two-press lobbed special shot
  (aim mode → ground ring reticle → `WeaponController.fire_special(dir, speed, damage)`), the one
  mortar-specific node in `Tank.tscn` being `Turret/MortarCamera`. Bots pick it up **and** use it
  (`MOD_SEEK`/`MOD_RETRIEVE`/`MORTAR_ATTACK`). Full detail: `Tank_Prop_Hunt_Modifications.md`.
- `HealthComponent` — `take_hit(killer, damage := 1)`; `current_hits += damage`, `destroyed` at
  `current_hits >= max_hits`. Tanks use `max_hits` **3** (`config/*_tank_config.json`, script
  default also 3 — raised from 2 so the mortar has a point vs tanks; normal `Projectile.damage` is
  1; a non-fatal hit updates only the debug HP `Label3D`, no mesh repaint). The objective uses this as an **HP pool** — `match_manager.gd` sets its
  `max_hits = GameConfig.objective_hits_required` (**100**), a normal shell does 1, the mortar
  special does `GameConfig.mortar_objective_damage`. `attackers_only` lets an objective ignore
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
  player too; the normal respawn cycle then brings it back at its spawn zone. `halt()` (called on
  round end, see round loop) permanently stops it for this scene load — no more respawn, fall-check
  off — so an already-dead tank's pending respawn is cancelled and a fresh kill doesn't schedule one.
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

**`await` in the root's `_ready()` silently voids the "my `_ready()` beats everyone's `_process()`"
assumption** that several nodes here lazily rely on (`ammo_drop_zone.gd`, `hud.gd`,
`tank_ai_controller.gd` all defer their setup to a first `_process`/`_physics_process` tick
*precisely because* the root finishes first). The moment the root started awaiting — navmesh bake,
dynamic obstacles — those lazy inits began running **inside** the wait, seeing a half-built scene.
Concrete damage found live: the ammo drop zone read `MatchState.match_mode` before it was assigned
(kitchen ran the mortar cadence on TARGET_OBJECTIVE's 30 s instead of 75 s) and missed its
`MatchManager.round_ended` subscription entirely (crates would keep dropping on the result screen).
Two rules follow: (1) anything that needs no tree — like copying the map's `match_mode` into
`MatchState` — goes at the **very top** of `_ready()`, before any `await`
(`_apply_match_mode_to_state()`); (2) a lazy init that needs a code-created node must **wait for
that node**, not for "one frame" (`ammo_drop_zone._process` now polls for `MatchManager` with a
frame budget). Both bugs predate the kitchen map on any map with dynamic obstacles enabled.

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
{TARGET_OBJECTIVE, TEAM_ARENA, CONTAINER_EXTRACTION}` — a **per-map setting**, not runtime detection: `map_scene.gd` has
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
(speed, turret turn rate, projectile speed, `max_hits`, `self_right_cooldown_sec`) read once by
`team_spawner.gd` — these are tank-profile data, not match balance, which is why they're JSON next
to `GameConfig` rather than fields on it. `self_right_cooldown_sec` (turtle self-right delay after
a tumble, see `TumbleController`) is the intended-upgradeable one. A second, unrelated JSON layer — `config/roster_*.json` — holds "who" (team/role/
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
  the three `show_*_debug` flags) — applied only if the key is present (`_apply_squad_to_brain()`),
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

Three modes, keyed off `MatchState.match_mode` (see Autoloads above), each map a template for one
mode (see "Map inventory"). **TARGET_OBJECTIVE** (`TargetObjectiveMap.tscn`): an `Objective` static
body with a `HealthComponent` (`attackers_only = true`) sits on the map; **objective destroyed →
round ends with an attack win; round timer expires with it intact → defense win**. Round timer for
this mode is `GameConfig.round_timer_sec` = **180 s (3 min)**. **Buzzer-beater rule**
(`match_manager._settling_last_shots`): at timeout the defense win is *not* awarded immediately —
first a settle phase waits until the `"projectiles"` group empties (every shot that was airborne
at the buzzer has landed), so a lobbed mortar that then destroys the objective still gives attack
the round via `_on_objective_destroyed`. `_SETTLE_MAX_SEC` (the stuck-projectile safety ceiling)
**must stay above `Projectile.max_lifetime_sec`** or a slow arc gets cut off and its post-buzzer
objective kill is silently rejected by the `_round_over` guard. The `ObjectiveAlertZone` (the ground
circle the AI uses for `State.ALERT`) is a **child of the objective node** (local `y = -1` so the
circle sits on the ground), freed together with the objective and simply absent on maps without one
(`TeamArenaMap.tscn`); every reader of `_alert_zone` uses `is_instance_valid()`, not `== null`.
**TEAM_ARENA** (`TeamArenaMap.tscn`, no objective node): team deathmatch,
`GameConfig.team_arena_round_sec` = 180 s / round, round winner by kill count (ties by
`defense_wins_ties`). Sides here are **fixed colour teams** — **Красные**
(team 0) and **Синие** (team 1) — never "attack"/"defense"; the HUD `TeamLabel`, score line and
result screen all say Красные/Синие in this mode (in TARGET_OBJECTIVE they say Атака/Оборона).

**CONTAINER_EXTRACTION** (`KitchenMap.tscn`, mode 2) — full detail:
`Tank_Prop_Hunt_Container_Extraction.md`. Five white `Container.tscn` pickups lie on the map; a
container rides in the tank's **existing `ModificationController` slot** (a passive `Modification`
with `behavior_scene = null`, so `can_pick_up()` alone enforces "no other mod while carrying" and
`ai_usable()` stays false), is delivered by driving into your own team's `SpawnZone` circle, and
drops at the death position when its carrier dies — capture-the-flag, not a respawning pickup.
`ContainerManager` (node created by `map_scene.gd` like `ScoreManager`, **before** `MatchManager`,
which subscribes to its `all_delivered`) owns layout / delivery polling / drop-on-death, and is
`halt()`ed first in `_on_round_ended_teardown` so the result-screen freeze doesn't spill containers.
Sides are fixed colour teams (Красные/Синие) as in TEAM_ARENA — `hud.gd._is_color_team_mode()`
covers both. The match is a **single round** of `GameConfig.container_round_sec` (300 s):
`MatchState.apply_mode_defaults(mode)` sets `total_rounds = 1` on every map load, so the existing
`series_complete()` math ends the match after it; the round also ends early when all five are
delivered. Winner = more deliveries, ties by `defense_wins_ties`.

`match_mode` is an `@export_enum` on each map root, **stored in the `.tscn`** (`TargetObjectiveMap`
= 0, `TeamArenaMap` = 1, `KitchenMap` = 2). Its script default is **`-1`, a deliberate invalid sentinel**: both real
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
winner-by-kills) then `MatchState.record_round_result` → `round_ended`. `map_scene.gd` also listens
on `round_ended` (`_on_round_ended_teardown`): once a round is decided it **freezes the field for
the result screen** (MVP) — `TeamSpawner.halt()` + every `RespawnController.halt()` (no more
spawns / respawns until the scene reloads) + `HealthComponent.force_destroy()` on every tank
including the player. Those deaths pass `killer = null`, so `ScoreManager._on_tank_destroyed`
skips them — the displayed kill count (and, in TEAM_ARENA, the count the winner was derived from,
already locked in `_end_round`) is untouched. The same script also owns
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

**Ammo drops** (all maps): a self-contained prefab `scenes/ammo_crate/AmmoDropZone.tscn` — the
root node itself *is* the spawn-sized ground circle (`spawn_zone.gd` on the root, so `radius` is
tuned right on the instance + editor gizmo, same as `MortarHideZone` — no separate `DropArea`
child) plus a high dummy `Marker3D` child (`DropOrigin`, script `ammo_crate/ammo_drop_zone.gd`,
its `_area = get_parent()`) — sits in each map's two empty corners
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

**Modification crates** (`TARGET_OBJECTIVE` and `CONTAINER_EXTRACTION` maps): the same drop-zone
leader also runs a `MortarDropTimer` that drops one **red `ModCrate`** in *every* zone
simultaneously (not one at a random zone like ammo). A `ModCrate` fills the tank's
`ModificationController` slot with the mortar mod when the slot is empty. Cadence is
`GameConfig.mortar_drop_interval_sec` (30 s) in TARGET_OBJECTIVE and the rarer
`mortar_drop_interval_container_sec` (75 s) in CONTAINER_EXTRACTION, where the slot is mainly
wanted for the container. `TeamArenaMap.tscn` (`TEAM_ARENA`) starts no such timer. Full detail:
`Tank_Prop_Hunt_Modifications.md`.

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
  (`_setup_bot_spawn_buttons()`, calls `TeamSpawner.spawn_one_bot(team)`); the single
  `Реакция ботов на игрока ON/OFF` button (`_setup_ignore_player_toggle_button()`, toggles
  `MatchState.bots_ignore_player` — off = bots stop perceiving the `PlayerTank` node as an enemy,
  gated in `TankAIController._can_see()`/`_on_damaged()`; bot-vs-bot unaffected).
- `tank.gd` — the billboard `Label3D` "HP N/M" above each tank (`_setup_hp_label()`), refreshed on
  `damaged`/`destroyed`/`on_respawned()`. The team-colour mesh tint (`apply_team_visuals()`) is
  **not** gated — it always applies.
- `tank_ai_controller.gd._initialize()` — FOV-cone / nav-path / brain-panel overlays (setup **and**
  the `_physics_process` update calls, so the overlay meshes/labels are never touched when null).
  The FOV cones can visually clip at the first obstacle/tank blocking line of sight (one raycast
  per fan segment, same collision mask as `_can_see()`) instead of drawing through walls — gated by
  its own sub-toggle, `MatchState.fov_debug_clip_obstacles` (default **off**: full-radius cones,
  zero extra raycasts even with `debug_enabled`/`show_fov_debug` on; flip it from code for a
  point-in-time LOS check, no UI button) — detail and cost analysis in the Bot AI vault doc, §17.
- `spawn_zone.gd` — the on-ground debug circle. **Every circular area marker in the project is now
  this one script/one visual** (per-instance `@export radius`, movable/scalable in the editor, no
  separate hardcoded radius anywhere): spawn zones, the ammo/mod drop-zone circle (the
  `AmmoDropZone` prefab **root** runs this script), `ObjectiveAlertZone`, patrol waypoints (`Waypoint*`/
  `AttackWaypoint*`/`DefenseWaypoint*` on `TargetObjectiveMap.tscn`, each tagged with its
  `zone_role` — see "Патруль по вейпоинтам" in `tank_ai_controller.gd`'s header; a role no roster
  squad's `waypoint_routes` references is dead weight, delete it rather than leave it — see
  `Tank_Prop_Hunt_Map_Creation_Guide.md` §3.5), and the
  disguise-ambush `MortarHideZone1`/`MortarHideZone2` (see "Маскировка бота"
  below). Color by name prefix: `Attack*`/`Defense*` — red/blue; a bare `Waypoint*` (the defender's
  diamond, no team prefix in its name) is **also** blue, matching the old `_build_waypoint_debug()`
  convention of "not Attack → defense colour"; `MortarHide*` — purple; genuinely team-neutral zones
  (`ObjectiveAlertZone`/`AmmoDropZone`) — yellow. An **editor-time mirror** of the same rings (`addons/zone_gizmos/
  zone_gizmo_plugin.gd`, a `@tool` `EditorNode3DGizmoPlugin`) draws identical circles in the Godot
  viewport while placing/tuning a zone, reading the same `radius`/name convention — keep both in
  sync when touching either. `spawn_zone.gd` is itself `@tool`: dragging the node's Scale
  gizmo/Transform in the inspector auto-converts the scale factor into `radius` and resets scale
  back to `(1,1,1)` (`_sync_radius_from_scale()`, on `NOTIFICATION_TRANSFORM_CHANGED`,
  editor-only) — `radius` (not node scale) is always the one source of truth for both circles
  *and* the actual gameplay radius (`pick_spawn_position()`/AI alert-detect), so resizing by
  dragging scale in the editor can no longer show a circle that doesn't match what the game
  uses. `radius`'s own setter calls `update_gizmos()`, so editing it directly in the inspector
  also redraws the gizmo ring immediately. A committed `.tscn` should never carry a non-identity
  `scale` on one of these nodes — if you see one, it predates this mechanism; open in the editor
  and nudge the transform once to normalize it.

**RELEASE TODO (Steam / release prep):** the menu checkbox is a *development-stage* entry point —
it's in the normal player-facing menu. Before release, change how debug mode is entered: drop it
from the visible menu and gate it behind a command-line flag / dev build / debug export instead
(or strip it entirely). This note is duplicated in `MatchState.debug_enabled`'s doc-comment and in
a `project` memory — do not silently ship the visible checkbox.

### `scenes/tank/tank_ai_controller.gd` — the one universal bot brain (`TankAIController`)

Single AI system for the whole project — every map deploys the exact same node/script, not a
per-map or per-context system. Lives as a dormant sibling on every `Tank.tscn` instance (including
the player's, see "Tank as a composed entity" above) and lazily self-inits on first enabled
`_physics_process()` tick. A 21-state priority engine
(`IDLE/PATROL/ATTACK/HUNT/PURSUE/SEARCH/ATTACK_OBJECTIVE/ALERT/DEAD/AMMO_SEEK/AMMO_RETRIEVE/
AMMO_WAIT/MOD_SEEK/MOD_RETRIEVE/MORTAR_ATTACK/DISGUISE_APPROACH/DISGUISE_PREP/DISGUISE/
OBJECTIVE_CHECK/CONTAINER_SEEK/CONTAINER_DELIVER`) with a
NavMesh-based driving stack (pure
pursuit + emergency brake + stuck detector + gap-scan detour; the emergency brake's forward ray
sits at y+0.4 and used to hit a rising ramp surface ~0.9 m before the foot and freeze the bot
there — it now ignores hits whose normal is walkable-slope-ish, `normal.y > 0.72`), two roles
(`ACHIEVER`/`KILLER` —
`ACHIEVER` self-degrades to `KILLER` behavior at init if the map has no objective), three difficulty
tiers, and integrations with the shared
`RespawnController`/`HealthComponent`/`AmmoComponent`/`ModificationController` (death state,
alert-on-hit, ballistic aim, ammo-crate seeking, plus mortar pickup **and use** — attackers head
for a drop zone only in a 10 s window after a mortar drop (coordinating so two bots take different
zones; nothing there → straight back to normal) and lob at the objective while not seeking fights,
though a visible tank shooting them after the shot takes priority; defenders grab a seen crate and
lob at tanks; a low-ammo bot grabs a mortar if the zone has no ammo crate; full detail in
`Tank_Prop_Hunt_Modifications.md`). Objective/waypoint/ammo-zone lookups are group- or recursive-search based, not
name- or scene-structure-specific, so the same file works unmodified on any map. Bots activate
disguise only via scripted ambush scenarios (`disguise_s1/s2/s3`, roster-gated); `_can_see()` hides
a `DISGUISED` enemy from *acquisition* but not from a bot already fighting it (`ignore_disguise`
param — see `DisguiseController` above and `Tank_Prop_Hunt_Disguise.md` §5).
In CONTAINER_EXTRACTION the same brain runs a container loop with no new role: carrying a container
outranks even the out-of-ammo gate (deliver first, snap-fire only, never commit to a fight); an
enemy *carrier* is a priority target for both sides (mirrors the mortar-carrier priority);
`CONTAINER_SEEK` counts as a "peaceful errand" alongside `AMMO_*`/`MOD_*` (resumable after combat)
and sits below the ammo branches in `_ensure_home_state()`. Two bots won't chase the same container
(`_container_taken_by_other_bot`, same idiom as `_zone_taken_by_other_bot`).
**Ledge check** (`ledge_check_enabled`, roster-gated, default off — it's a map property, and flat
maps would just burn raycasts): the driving stack only ever probed *horizontally*, so it sees a wall
but not the edge of a counter. A downward probe ahead now feeds both `_check_emergency_brake()` and
`_scan_gap()`. Crucially a drop is **not** judged by height — descending a ramp is a drop too — but
by steepness: the drop at each probe distance is compared against what a drivable slope would give
(`dist * tan(ledge_max_slope_deg) + ledge_slack`), so ramps pass and cliffs don't. Its fan is
deliberately narrower than the brake's, or a bot would stop mid-descent on seeing the void beside
its own ramp. Detail: `Tank_Prop_Hunt_Container_Extraction.md` §7.1.

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

Map geometry is **instances of prefab scenes**, not hand-built `StaticBody3D` +
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
- `Structure.tscn` (`structure.gd`, `@tool`) — **permanent level geometry** (furniture, walls,
  counters, shelves): technically the same box as `Obstacle` (`@export size`/`color`), but in group
  `"structures"`, not `"obstacles"`. That split is load-bearing, not cosmetic: the dynamic-obstacle
  pass deletes the whole `"obstacles"` group, so a map built from `Obstacle` would be wiped to bare
  floor by the menu checkbox. `Obstacle` stays what it always was — swappable cover that doubles as
  the disguise prop.
- `ToyRamp.tscn` (`toy_ramp.gd`, `@tool`) — the only incline primitive (ruler / book / race-track
  piece / plank). `@export run`/`rise`/`width`/`thickness`/`color`; place the node at the **bottom**
  of the incline and yaw it — the top end lands exactly `run` forward (along the node's -Z, the
  project's usual forward) and `rise` up. `rise = 0` gives a flat plank (the sink bridge, and the
  landing pads that make diagonal ramps connect to platforms). Needed because the tank has no
  step-up: vertical connectivity rests entirely on slopes. Placement rules: see "Map inventory".

All three sub-resources in each prefab are `resource_local_to_scene = true` so per-instance
`size`/`color` don't bleed across instances. Nothing looks obstacles up by name. After
add/move/resize/delete the per-map NavMesh still needs a manual re-bake
(`Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md`).

`obstacle.gd`/`hazard_zone.gd` each self-register into a group at runtime (`"obstacles"` /
`"hazard_zones"`, editor-hint-guarded); `spawn_zone.gd` registers **every** circular zone marker
into `"zone_circles"` (on top of its optional `zone_role`). These three groups exist for the
dynamic-obstacle system below.

### Dynamic obstacle system — random pre-match layout (per-map, opt-in)

Two presets per map: **static** (obstacles hand-placed in the editor — the default, the
`Obstacle*` nodes in the `.tscn`) or **dynamic** (up to 30 brown cubes placed at random before
the match, so networked players can't memorise cover / disguise spots). Chosen by a menu checkbox
→ `MatchState.dynamic_obstacles` (plain flag, not debug-gated; survives `reload_current_scene()`
like `debug_enabled`). **HazardZones are never touched** — always editor-placed, and they act as
placement constraints for the dynamic pass.

- `scenes/obstacles/dynamic_obstacle_placer.gd` (`extends RefCounted`, no `class_name`, static
  API `populate(map_root, nav_region, seed) -> int`) — MVP rules: ≤ `MAX_OBSTACLES` (30) cubes,
  none inside any `"zone_circles"` circle (+ clearance), none inside any `"hazard_zones"` /
  `Objective` / `"turrets"` AABB (+ clearance), no cube-cube overlap (centre distance ≥
  `OBSTACLE_SIZE.x + OBSTACLE_GAP`), all within `Ground` minus `EDGE_MARGIN`. One `Obstacle.tscn`
  type only for now. Fully analytic + synchronous (one down-ray per cube for ground Y);
  `RandomNumberGenerator` with an explicit `seed`, calls in fixed order → **deterministic**: same
  seed ⇒ byte-identical layout on any machine (verified). That's the netcode hook — host sends one
  int, every peer builds the same map.
- `map_scene.gd._apply_dynamic_obstacles()` (`await`-ed from `_ready()` right after
  `_build_map_borders()`, before `TeamSpawner.spawn_team()`) — sets the region's
  `geometry_parsed_geometry_type = PARSED_GEOMETRY_STATIC_COLLIDERS` (colliders only — fast, no
  GPU→CPU mesh readback / no "parse RenderingServer meshes at runtime" warning), then loops:
  `remove_child` every `"obstacles"` node (static cubes first pass, own dynamic cubes on a
  re-roll) → `populate()` → `bake_navigation_mesh()` + `await bake_finished` + `await physics_frame`
  → **connectivity check** (`NavigationServer3D.map_get_path` for attack-spawn↔defense-spawn and
  each spawn↔objective; a partial path — last point > 5 m from target — counts as broken). If a
  layout isolates something it **re-rolls the seed** (up to `_DYNAMIC_MAX_REROLLS` = 4), then
  proceeds with a `push_warning` if still broken. The seed left in `MatchState` is the one that
  produced a connected map — that's what rounds 2–3 and (future) netcode peers use. Bots lazy-init
  after `_ready()` so they start on the fresh nav map.
- **Layout lifetime = one match.** `dynamic_obstacles_seed` is held across rounds
  (`reload_current_scene()` keeps the autoload) so rounds 2–3 replay the same layout; zeroed by
  `MatchState.reset_series()` (menu / «Новый матч») → next match re-rolls. Not persisted between
  sessions.
- **HazardZones don't carve the navmesh** — never did, in either bake mode
  (`geometry_collision_mask = 5` effectively only cuts layer 1; verified against the shipped
  editor navmesh too). Bots avoid hazards **reactively** — the AI's `_cast_ray_dist` avoidance
  rays (`collide_with_areas`, mask includes layer 3) see the `Area3D`, so the A* path may cross a
  hazard but gap-scan / emergency-brake deflect the bot. `STATIC_COLLIDERS` for the dynamic rebake
  therefore changes nothing about hazard behaviour. True carving would need `NavigationObstacle3D`
  (`affect_navigation_mesh`) — out of scope.
- Benign per-bake log noise: `agent_max_climb / agent_radius ... loses precision` — the map's
  navmesh values aren't multiples of `cell_size`/`cell_height`; fires for the editor bake too.

### Stationary turret system — `scenes/turret/` (universal, any map / any mode)

`Turret.tscn` is its own prefab — a "tank that can't move", dropped as an instance into any map's
`.tscn` per side (`@export team` on the root), no spawner or autoload. Full reference:
`Tank_Prop_Hunt_Turrets.md`. Key points that touch the rest of the codebase:

- `turret.gd` (`@tool`, `extends StaticBody3D`, `collision_layer=1`) — shell only: team +
  `apply_team_visuals()` (same reusable-`StandardMaterial3D` idiom as `tank.gd`), `body_size` cube
  sync, `HealthComponent` wiring (`max_hits` **10**, `free_on_destroy=true` — the node vanishes on
  death, **no respawn**), a debug `Label3D` "HP N/M" (gated by `MatchState.debug_enabled`),
  `add_to_group("turrets")`, and a `call_deferred` hook onto `MatchManager.round_ended` →
  disable `TurretAI` for the results screen (it's **not** in `"tanks"`, so
  `map_scene._on_round_ended_teardown` never `force_destroy`s it).
- `turret_ai.gd` (`extends Node`, no `class_name`) — 3-state brain (SEARCH 360° turret sweep /
  ATTACK / RELOAD), lazy `_initialize()` on first enabled `_physics_process` tick like
  `TankAIController`. Reuses `turret_controller.gd` on `TurretPivot` and `barrel_controller.gd` on
  `Barrel` unchanged (both `is_player_controlled=false`, external `target_yaw`/`target_pitch`; their
  `CameraRig`/`TankStateMachine` lookups are null-safe). Fires plain `Projectile` (`damage` 1)
  directly, `shooter = turret root`. MEDIUM `@export`s + EASY/HARD `_DIFFICULTY_PRESETS` (same
  pattern as the bot). Fire cadence `shot_interval_sec` = **3 s** (= `GameConfig.reload_duration_sec`,
  "shoots like a tank"), 10-round `mag_size`, 5 s `reload_sec`. `min_fire_range` (3 m, **XZ**
  distance) near **blind**-zone — a target inside it drops out of `_can_see()` entirely (acquire
  *and* hold: drive right up to the turret's base and it loses you, back to SEARCH), not just a
  fire gate. Narrow `detect_cone_deg` (18°, like a tank's `secondary_cone_deg`) for
  acquisition, wide `track_cone_deg` (200°) for holding. `_can_see()` respects the disguise gate
  (`TankStateMachine.DISGUISED` + `GameConfig.ai_can_see_disguised_tanks`); the turret itself can't
  disguise / can't pick up crates or mods (no entry points; wrong collision layer).
- **ALERT target-share**: `TankAIController._notify_team_of_alert_target()` — after its existing
  loop over allied tanks in `State.ALERT` — also loops `get_nodes_in_group("turrets")` of the same
  team and calls `turret_ai.on_alert_target_shared(target)`. The turret slews its barrel to that
  target and enters ATTACK once it has real LOS/range (recon share, not vision teleport).
- **"Mortar on the objective kills the guard turret first"** is geometry, not redirect code: the
  test turret sits physically on the objective's top face (`ObjectiveTurret`, instance transform
  `(0,2,0)` under `NavigationRegion3D` in `TargetObjectiveMap.tscn`), so a plunging mortar arc
  aimed at the objective enters the turret's collider first and is consumed; a flat cannon shot
  passes under the turret and still reaches the objective's side.
- Debug FOV/fire-sector overlay (`show_fov_debug`, gated by `MatchState.debug_enabled`) — an
  `ImmediateMesh` child of the turret root, ground-plane fan rotated by the live turret yaw:
  detection-cone fill (colour by state), `fire_range` arc, `min_fire_range` inner arc, barrel line.
  Same spirit as `TankAIController`'s FOV debug, including the obstacle-clip raycasts (same
  `MatchState.fov_debug_clip_obstacles` toggle, same default off) — cast ground-level (not from the
  actual elevated barrel; see `Tank_Prop_Hunt_Turrets.md` §4 for why `ObjectiveTurret` specifically
  needed that), since a barrel-height ray from its perch atop the objective sails over
  normal-height obstacles.

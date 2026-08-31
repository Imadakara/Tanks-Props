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

**Current `run/main_scene`** (`project.godot`) points at `res://scenes/bot_arena/BotArena.tscn`
(an isolated bot-AI sandbox, see below and the vault's Bot AI Sandbox doc), not at the production
game (`res://scenes/main/Main.tscn`) — this is deliberate for the current `Bot` branch, not a
misconfiguration. Point it back at `Main.tscn` to run the actual 5×5 game.

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
- `HealthComponent` — multi-hit (`max_hits`), reused verbatim for the destructible objective, not
  tank-specific. `attackers_only` lets an objective ignore friendly fire; `free_on_destroy=false`
  on tanks hands cleanup to `RespawnController` instead of freeing the node; `invincible` is a
  point override for test scenes (see bot arena below), not part of normal balance.
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

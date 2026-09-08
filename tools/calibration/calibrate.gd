extends RefCounted
## Batch calibration harness for the godot-runtime MCP `run_script` path.
##
## One launch, many assertions. Detects the running map from
## `scene_tree.current_scene.scene_file_path`, runs the shared invariant checks plus the
## per-map ones, returns a compact verdict instead of forcing launch -> check -> launch.
##
## Usage (see also CLAUDE.md "Running / testing"):
##   1. mcp__godot-runtime__run_project  scene: "res://scenes/maps/<Map>.tscn"  background: true
##   2. mcp__godot-runtime__get_debug_output   (catch parse/scene errors first)
##   3. wait real time so TeamSpawner + every lazy `_physics_process` init has run (bots,
##      ammo zones, HUD, ContainerManager all defer to the first tick): ~3 s for the flat
##      maps, ~6 s for KitchenMap (it bakes its navmesh at load).
##   4. mcp__godot-runtime__run_script  script: <paste the contents of this file>
##      (the MCP `run_script` tool takes inline GDScript source, not a res:// path)
##   5. mcp__godot-runtime__stop_project
##
## Return: { scene, mode, pass: bool, summary: "N/M", passed: [...], failed: ["name: detail", ...] }
## `pass` is true only when `failed` is empty. Treat every `failed` line as a regression to
## explain before shipping — same bar as a red test.
##
## TestGroundMap has no MatchManager/mode; it gets its own minimal branch.
## Extend `_MAP_EXPECT` + the per-map functions when a map gains an invariant worth locking.

const _MODE_NAMES := ["TARGET_OBJECTIVE", "TEAM_ARENA", "CONTAINER_EXTRACTION"]

## Per-map expectations. Keyed by scene basename (no dir, no extension).
const _MAP_EXPECT := {
	"TargetObjectiveMap": {
		"mode": 0, "total_rounds": 3, "round_sec": 180.0,
		"objectives": 1, "turrets_min": 1, "containers": 0,
		"final_stage": false, "border": true,
	},
	"TeamArenaMap": {
		"mode": 1, "total_rounds": 3, "round_sec": 180.0,
		"objectives": 0, "turrets_min": 0, "containers": 0,
		"final_stage": true, "border": true,
	},
	"KitchenMap": {
		"mode": 2, "total_rounds": 1, "round_sec": 300.0,
		"objectives": 0, "turrets_min": 0, "containers": 5,
		"final_stage": false, "border": false,  # kitchen furniture is the boundary; .tscn sets map_border_enabled = false
	},
}

const _TANK_COMPONENTS := [
	"Hull", "CameraRig", "TankMovement", "TankStateMachine", "WeaponController",
	"AmmoComponent", "HealthComponent", "DisguiseController", "CollisionDetector",
	"RespawnController", "TankAIController", "ModificationController", "TumbleController",
]

var _passed: Array[String] = []
var _failed: Array[String] = []


func execute(scene_tree: SceneTree) -> Variant:
	var cs := scene_tree.current_scene
	if cs == null:
		return {"pass": false, "failed": ["current_scene is null - scene never loaded"]}

	var scene_path: String = cs.scene_file_path
	var base := scene_path.get_file().get_basename()

	if base == "TestGroundMap":
		_check_test_ground(scene_tree, cs)
		return _verdict(base, "PROVING_GROUND")

	if not _MAP_EXPECT.has(base):
		return {
			"pass": false,
			"failed": ["unknown map '%s' - add it to _MAP_EXPECT" % base],
			"scene": scene_path,
		}

	var exp: Dictionary = _MAP_EXPECT[base]
	_check_common(scene_tree, cs, exp)
	match int(exp["mode"]):
		0: _check_target_objective(scene_tree, cs)
		1: _check_team_arena(scene_tree, cs)
		2: _check_kitchen(scene_tree, cs)
	return _verdict(base, _MODE_NAMES[int(exp["mode"])])


# ---- shared invariants -------------------------------------------------------

func _check_common(st: SceneTree, cs: Node, exp: Dictionary) -> void:
	var root := st.root
	var game_config := root.get_node_or_null("GameConfig")
	var match_state := root.get_node_or_null("MatchState")
	_expect("autoload GameConfig", game_config != null, "not found under root")
	_expect("autoload MatchState", match_state != null, "not found under root")
	if match_state == null:
		return

	_expect("MatchState.match_mode == %d" % exp["mode"],
		int(match_state.match_mode) == int(exp["mode"]),
		"got %d (a dropped `match_mode` line in the .tscn falls back to 0)" % int(match_state.match_mode))
	_expect("MatchState.total_rounds == %d" % exp["total_rounds"],
		int(match_state.total_rounds) == int(exp["total_rounds"]),
		"got %d" % int(match_state.total_rounds))

	var mm := cs.get_node_or_null("MatchManager")
	var sm := cs.get_node_or_null("ScoreManager")
	_expect("MatchManager node exists", mm != null, "cs has no child 'MatchManager'")
	_expect("ScoreManager node exists", sm != null, "cs has no child 'ScoreManager'")
	if mm != null:
		var rt := mm.get_node_or_null("RoundTimer")
		_expect("RoundTimer exists", rt != null, "MatchManager has no child 'RoundTimer'")
		if rt != null:
			_expect("RoundTimer.wait_time == %.0f" % exp["round_sec"],
				is_equal_approx(rt.wait_time, float(exp["round_sec"])),
				"got %.1f" % rt.wait_time)

	var has_border := _find_by_name(cs, "MapBorders") != null
	if bool(exp["border"]):
		_expect("MapBorders ring built", has_border,
			"map_border_enabled default is true but no 'MapBorders' node found")
	else:
		_expect("MapBorders absent (opted out)", not has_border,
			"map's .tscn sets map_border_enabled = false, but a 'MapBorders' node exists")

	# tanks
	var tanks := st.get_nodes_in_group("tanks")
	_expect("group 'tanks' non-empty", tanks.size() > 0, "0 tanks - TeamSpawner did not run (wait longer?)")

	var player := cs.get_node_or_null("PlayerTank")
	_expect("PlayerTank node exists", player != null, "no child 'PlayerTank'")
	if player != null:
		for comp in _TANK_COMPONENTS:
			_expect("PlayerTank/%s present" % comp, player.get_node_or_null(comp) != null, "missing sibling component")
		var p_ai := player.get_node_or_null("TankAIController")
		if p_ai != null:
			_expect("PlayerTank AI disabled", not bool(p_ai.enabled), "player's TankAIController.enabled is true")
		var p_mv := player.get_node_or_null("TankMovement")
		if p_mv != null and "is_player_controlled" in p_mv:
			_expect("PlayerTank TankMovement.is_player_controlled", bool(p_mv.is_player_controlled), "is false on the player")

	var bot_count := 0
	for t in tanks:
		if t == player:
			continue
		bot_count += 1
		var ai := t.get_node_or_null("TankAIController")
		if ai != null:
			_expect("bot '%s' AI enabled" % t.name, bool(ai.enabled), "TankAIController.enabled is false on a bot")
	_expect("at least one bot spawned", bot_count > 0, "roster produced no bots")

	# Invariant: the tank root never tilts (only Hull/Turret do). Soft tolerance - needs a
	# couple of settle seconds before it holds; a large value here is a real regression.
	for t in tanks:
		if not (t is Node3D):
			continue
		var rx: float = abs(rad_to_deg((t as Node3D).rotation.x))
		var rz: float = abs(rad_to_deg((t as Node3D).rotation.z))
		_expect("root upright: %s" % t.name, rx < 3.0 and rz < 3.0,
			"rotation x=%.1f z=%.1f deg (root must stay level; if this is a live tumble, re-run after settle)" % [rx, rz])
		var y: float = (t as Node3D).global_position.y
		_expect("%s above kill plane" % t.name, y > -3.0, "y=%.1f (fell below the map)" % y)


# ---- per-map ---------------------------------------------------------------

func _check_target_objective(st: SceneTree, cs: Node) -> void:
	var objs := st.get_nodes_in_group("objective_health")
	_expect("exactly 1 objective", objs.size() == 1, "group 'objective_health' has %d" % objs.size())
	var gc := st.root.get_node_or_null("GameConfig")
	if objs.size() == 1 and gc != null:
		var o = objs[0]
		if "max_hits" in o:
			_expect("objective max_hits == objective_hits_required",
				int(o.max_hits) == int(gc.objective_hits_required),
				"objective max_hits=%d, GameConfig.objective_hits_required=%d" % [int(o.max_hits), int(gc.objective_hits_required)])
	var alert := _find_by_name(cs, "ObjectiveAlertZone")
	_expect("ObjectiveAlertZone present", is_instance_valid(alert), "not found (should be a child of the objective)")
	var turrets := st.get_nodes_in_group("turrets")
	_expect("guard turret present", turrets.size() >= 1, "group 'turrets' is empty; expected the ObjectiveTurret")


func _check_team_arena(st: SceneTree, cs: Node) -> void:
	var objs := st.get_nodes_in_group("objective_health")
	_expect("no objective node", objs.size() == 0, "TEAM_ARENA carries %d objective(s)" % objs.size())
	var mscn := cs
	if "final_stage_enabled" in mscn:
		_expect("final_stage_enabled == true", bool(mscn.final_stage_enabled), "TeamArenaMap should opt into the final stage")


func _check_kitchen(st: SceneTree, cs: Node) -> void:
	var cm := cs.get_node_or_null("ContainerManager")
	_expect("ContainerManager node exists", cm != null, "no child 'ContainerManager'")
	var gc := st.root.get_node_or_null("GameConfig")
	if cm != null and gc != null and "total_containers" in cm:
		# total_containers is set once at layout and never decremented, so this is
		# timing-independent - unlike get_nodes_in_group("containers"), which shrinks as
		# soon as a bot picks one up (a carried container leaves the group).
		_expect("ContainerManager laid out container_count containers",
			int(cm.total_containers) == int(gc.container_count),
			"total_containers=%d, GameConfig.container_count=%d" % [int(cm.total_containers), int(gc.container_count)])
	var structures := st.get_nodes_in_group("structures")
	_expect("kitchen has Structure geometry", structures.size() > 0, "group 'structures' is empty")
	if "bake_navmesh_on_start" in cs:
		_expect("bake_navmesh_on_start == true", bool(cs.bake_navmesh_on_start), "kitchen should bake its navmesh at load")
	if "dynamic_obstacles_supported" in cs:
		_expect("dynamic_obstacles_supported == false", not bool(cs.dynamic_obstacles_supported), "kitchen must opt out of dynamic obstacles")
	# Carry weight: the container is deliberately heavy (30% slower) — that slowdown is what makes
	# a carrier want an escort and cover. Checked end-to-end (resource value -> controller forward
	# -> TankMovement limit) because it crosses three files and has no visible failure mode: a
	# broken forward just silently restores full speed.
	var mod_res: Resource = load("res://scenes/modifications/container.tres")
	_expect("container.tres carry_speed_multiplier == 0.7",
		is_equal_approx(float(mod_res.carry_speed_multiplier), 0.7),
		"got %.3f" % float(mod_res.carry_speed_multiplier))
	var player := cs.get_node_or_null("PlayerTank")
	if player != null:
		var slot := player.get_node_or_null("ModificationController")
		var mv := player.get_node_or_null("TankMovement")
		if slot != null and mv != null and slot.can_pick_up():
			var base: float = mv.move_speed
			_expect("empty slot -> full move speed",
				is_equal_approx(mv._effective_move_speed(), base),
				"got %.2f of %.2f" % [mv._effective_move_speed(), base])
			slot.install(mod_res)
			var loaded: float = mv._effective_move_speed()
			slot.clear_slot()
			_expect("carrying container -> 70%% of move speed",
				is_equal_approx(loaded, base * 0.7),
				"got %.2f, expected %.2f" % [loaded, base * 0.7])
			_expect("speed limit restored after handover",
				is_equal_approx(mv._effective_move_speed(), base),
				"got %.2f" % mv._effective_move_speed())


func _check_test_ground(st: SceneTree, cs: Node) -> void:
	_expect("no MatchManager (proving ground)", cs.get_node_or_null("MatchManager") == null, "TestGroundMap unexpectedly has a MatchManager")
	var tanks := st.get_nodes_in_group("tanks")
	_expect("player + dummy tank present", tanks.size() >= 2, "expected >= 2 tanks, got %d" % tanks.size())
	_expect("PlayerTank present", cs.get_node_or_null("PlayerTank") != null, "no 'PlayerTank'")


# ---- helpers -------------------------------------------------------------

func _expect(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed.append(name)
	else:
		_failed.append("%s -- %s" % [name, detail] if detail != "" else name)


func _find_by_name(root: Node, target: String) -> Node:
	if root.name == target:
		return root
	for c in root.get_children():
		var hit := _find_by_name(c, target)
		if hit != null:
			return hit
	return null


func _verdict(scene: String, mode: String) -> Dictionary:
	var total := _passed.size() + _failed.size()
	return {
		"scene": scene,
		"mode": mode,
		"pass": _failed.is_empty(),
		"summary": "%d/%d" % [_passed.size(), total],
		"failed": _failed,
		"passed": _passed,
	}

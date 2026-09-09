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
##      ammo zones, HUD, ExtractionManager all defer to the first tick): ~3 s for the flat
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

const _MODE_NAMES := ["TARGET_OBJECTIVE", "TEAM_ARENA", "EXTRACTION"]

## Per-map expectations. Keyed by scene basename (no dir, no extension).
const _MAP_EXPECT := {
	"TargetObjectiveMap": {
		"mode": 0, "total_rounds": 3, "round_sec": 180.0,
		"objectives": 1, "turrets_min": 1,
		"final_stage": false, "border": true,
	},
	"TeamArenaMap": {
		"mode": 1, "total_rounds": 3, "round_sec": 180.0,
		"objectives": 0, "turrets_min": 0,
		"final_stage": true, "border": true,
	},
	"KitchenMap": {
		"mode": 2, "total_rounds": 1, "round_sec": 640.0,  # 120 + 120*4 + 40 — момент закрытия 5-го (последнего) окна эвакуации
		"objectives": 0, "turrets_min": 0,
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
	var em := cs.get_node_or_null("ExtractionManager")
	_expect("ExtractionManager node exists", em != null, "no child 'ExtractionManager'")
	var gc := st.root.get_node_or_null("GameConfig")
	var structures := st.get_nodes_in_group("structures")
	_expect("kitchen has Structure geometry", structures.size() > 0, "group 'structures' is empty")
	if "bake_navmesh_on_start" in cs:
		_expect("bake_navmesh_on_start == true", bool(cs.bake_navmesh_on_start), "false")
	if "dynamic_obstacles_supported" in cs:
		_expect("dynamic_obstacles_supported == false", not bool(cs.dynamic_obstacles_supported), "true")

	# --- Экономический цикл (Tank_Prop_Hunt_Extraction_Loop_Concept.md) ---
	# Кубы-укрытия обязаны быть РАЗРУШАЕМЫ ВСЕ до одного: если пробный выстрел мгновенно отличает
	# ресурсный узел от пустого укрытия, ставка «ресурс / пусто / враг» обесценивается (§6).
	var cubes := st.get_nodes_in_group("obstacles")
	_expect("map has cover cubes", cubes.size() > 0, "group 'obstacles' is empty")
	var undamageable := 0
	var with_loot := 0
	for c in cubes:
		if c.get_node_or_null("HealthComponent") == null:
			undamageable += 1
		if "loot_value" in c and int(c.loot_value) > 0:
			with_loot += 1
	_expect("every cube is destructible", undamageable == 0, "%d cube(s) without HealthComponent" % undamageable)
	# Каждый лутовый куб: ярус редкости 0..3 и сырое значение в диапазоне ЭТОГО яруса.
	if gc != null:
		var rar_bad := 0
		for c in cubes:
			if not ("loot_value" in c) or int(c.loot_value) <= 0:
				continue
			var rr: int = int(c.loot_rarity)
			if rr < 0 or rr >= gc.loot_rarity_weights.size():
				rar_bad += 1
			elif int(c.loot_value) < gc.loot_rarity_raw_min[rr] or int(c.loot_value) > gc.loot_rarity_raw_max[rr]:
				rar_bad += 1
		_expect("loot rarity + raw value consistent", rar_bad == 0,
			"%d loot node(s) with a bad rarity or out-of-range raw value" % rar_bad)
	# Лут роздан, но НЕ во все кубы — иначе стрельба по любому укрытию всегда окупалась бы.
	var loose := st.get_nodes_in_group("loot_crates").size()
	if gc != null:
		_expect("loot allocated across cubes", with_loot + loose >= 1 and with_loot <= cubes.size(),
			"loot cubes=%d, crates already out=%d, cubes=%d" % [with_loot, loose, cubes.size()])
		_expect("some cubes are empty", with_loot < cubes.size(),
			"every cube holds loot - the farming gamble is gone")
	_expect("extraction points exist", st.get_nodes_in_group("ExtractionPoint").size() > 0,
		"no zone_role 'ExtractionPoint' markers - evacuation impossible")

	# Трюм и его связка с маскировкой — центральная сцепка концепции (§5).
	var player := cs.get_node_or_null("PlayerTank")
	if player != null:
		var hold := player.get_node_or_null("CargoHold")
		var disguise := player.get_node_or_null("DisguiseController")
		_expect("PlayerTank/CargoHold present", hold != null, "missing cargo hold component")
		if hold != null and disguise != null and gc != null:
			_expect("empty hold does not block disguise", not hold.blocks_disguise(), "blocked while empty")
			_expect("empty hold has no speed penalty", is_equal_approx(hold.speed_multiplier(), 1.0),
				"got %.3f" % hold.speed_multiplier())
			hold.try_take(100, false, false)
			_expect("loaded hold blocks disguise", hold.blocks_disguise(), "cargo does not block disguise")
			_expect("disguise controller agrees", disguise.blocked_by_cargo(), "controller disagrees with hold")
			_expect("loaded hold slows the tank",
				hold.speed_multiplier() < 1.0, "got %.3f" % hold.speed_multiplier())
			# «Главный замок» (§4): со склада берут ровно один и только в пустой трюм.
			_expect("warehouse pickup refused into a loaded hold",
				not hold.try_take(100, true, true), "a stored crate was accepted into a non-empty hold")
			hold.clear()
			_expect("warehouse pickup accepted into an empty hold",
				hold.try_take(100, true, true), "a stored crate was refused into an empty hold")
			_expect("no top-up after a warehouse withdrawal",
				not hold.try_take(100, false, false), "loose loot was added on top of a withdrawn crate")
			hold.clear()

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

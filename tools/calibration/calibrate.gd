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
## Режим TARGET_OBJECTIVE (0) сейчас без карты — его шаблон TargetObjectiveMap удалён, логика режима
## в коде осталась; карте этого режима понадобится своя запись здесь и своя per-map функция.
const _MAP_EXPECT := {
	"TeamArenaMap": {
		"mode": 1, "total_rounds": 3, "round_sec": 180.0,
		"objectives": 0, "turrets_min": 0,
		"final_stage": true, "border": true,
	},
	"KitchenMap": {
		"mode": 2, "total_rounds": 1, "round_sec": 640.0,  # 120 + 120*4 + 40 — момент закрытия 5-го (последнего) окна эвакуации
		"objectives": 0, "turrets_min": 2,  # две NPC objective-цели, у каждой турель на крыше
		"npc_targets": 2,
		"final_stage": false, "border": false,  # kitchen furniture is the boundary; .tscn sets map_border_enabled = false
	},
}

const _TANK_COMPONENTS := [
	"Hull", "CameraRig", "TankMovement", "TankStateMachine", "WeaponController",
	"AmmoComponent", "HealthComponent", "DisguiseController", "CollisionDetector",
	"RespawnController", "TankAIController", "ModificationController", "TumbleController",
	"CargoHold", "Chassis",
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
		1: _check_team_arena(scene_tree, cs)
		2: _check_kitchen(scene_tree, cs)
	if exp.has("npc_targets"):
		_check_npc_targets(scene_tree, int(exp["npc_targets"]))
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
		# Игровой класс: карта подменила PlayerTank на класс из лобби (map_scene._enter_tree).
		var p_ch := player.get_node_or_null("Chassis")
		if p_ch != null:
			_expect("PlayerTank chassis == MatchState.player_chassis",
				StringName(p_ch.chassis_id) == StringName(match_state.player_chassis),
				"tank is '%s', lobby chose '%s'" % [p_ch.chassis_id, match_state.player_chassis])

	# Класс применён к каждому танку: визуальный пивот и HP совпадают с узлом Chassis.
	for t in tanks:
		var ch := t.get_node_or_null("Chassis")
		var hull := t.get_node_or_null("Hull")
		var hp := t.get_node_or_null("HealthComponent")
		if ch == null or hull == null or hp == null:
			continue
		_expect("chassis applied: %s" % t.name,
			is_equal_approx(float(hull.chassis_scale), float(ch.size_scale)) and int(hp.max_hits) == int(ch.max_hits),
			"hull scale %.3f vs %.3f, max_hits %d vs %d" % [float(hull.chassis_scale), float(ch.size_scale),
				int(hp.max_hits), int(ch.max_hits)])

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

## NPC objective-цели (scenes/objective_target/): третья сторона, своя охрана, не протекает в
## командную objective (группа "objective_health" пуста, счёт команд их не видит).
func _check_npc_targets(st: SceneTree, expected: int) -> void:
	var gc := st.root.get_node_or_null("GameConfig")
	var targets := st.get_nodes_in_group("objective_targets")
	_expect("NPC objective targets == %d" % expected, targets.size() == expected, "got %d" % targets.size())
	_expect("NPC targets not in 'objective_health'", st.get_nodes_in_group("objective_health").is_empty(),
		"a team objective group is populated - team bots/HUD would treat the NPC target as theirs")
	_expect("turrets >= NPC targets", st.get_nodes_in_group("turrets").size() >= expected,
		"%d turret(s)" % st.get_nodes_in_group("turrets").size())
	for t in targets:
		var h: Node = t.get_node_or_null("Core/HealthComponent")
		_expect("%s core HP pool" % t.name, h != null and gc != null and int(h.immune_team) == 2
			and (int(t.core_max_hits) > 0 or int(h.max_hits) == int(gc.objective_hits_required)),
			"core HealthComponent missing / immune_team != 2 / max_hits != objective_hits_required")
		var tr: Node = t.get_node_or_null("Turret")
		_expect("%s turret is NPC" % t.name, tr != null and int(tr.team) == 2, "turret missing or team != 2")
		if not bool(t.guard_enabled):
			continue
		var g: Node = t._guard
		_expect("%s guard spawned" % t.name, is_instance_valid(g), "no guard tank")
		if not is_instance_valid(g):
			continue
		var ai: Node = g.get_node("TankAIController")
		_expect("%s guard is NPC, bound to its target" % t.name,
			int(g.team) == 2 and ai._npc_guard == t and ai._waypoints.size() == 4,
			"team %d, bound %s, %d waypoint(s)" % [int(g.team), ai._npc_guard == t, ai._waypoints.size()])
		_expect("%s guard: infinite ammo, no cargo" % t.name,
			bool(g.get_node("AmmoComponent").infinite) and int(g.get_node("CargoHold").capacity) == 0,
			"infinite=%s capacity=%d" % [g.get_node("AmmoComponent").infinite, int(g.get_node("CargoHold").capacity)])


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
	for c in cubes:
		if c.get_node_or_null("HealthComponent") == null:
			undamageable += 1
	_expect("every cube is destructible", undamageable == 0, "%d cube(s) without HealthComponent" % undamageable)
	# Баланс выпадения грузится из config/extraction_*.json (ExtractionManager). Проверяем, что
	# конфиг загрузился (ярусы есть) и раздача им консистентна.
	if em != null:
		_expect("rarity tiers loaded from JSON", int(em.rarity_count()) >= 1,
			"ExtractionManager.rarity_count() == 0 — config/extraction_*.json не загрузился")
	# Раздача выпадения по кубам: у каждого разыгранного узла валидный drop_kind (0 LOOT … 5 SHIELD),
	# у лут-узлов (drop_kind == 0) ярус в пределах таблицы и сырое значение в диапазоне ЭТОГО яруса.
	if em != null:
		var rar_cap: int = int(em.rarity_count())
		var bad := 0
		var with_drop := 0   # drop_kind != NOTHING
		for c in cubes:
			if not ("drop_kind" in c):
				continue
			var dk: int = int(c.drop_kind)
			if dk < 0 or dk > 5:
				bad += 1
				continue
			if dk != 1:  # 1 == FarmDrop.NOTHING
				with_drop += 1
			if dk == 0:  # FarmDrop.LOOT
				var rr: int = int(c.loot_rarity)
				if rr < 0 or rr >= rar_cap or int(c.loot_value) <= 0:
					bad += 1
				elif int(c.loot_value) < int(em.rarity_raw_min(rr)) or int(c.loot_value) > int(em.rarity_raw_max(rr)):
					bad += 1
		var loose := st.get_nodes_in_group("loot_crates").size()
		_expect("farm drop-kinds valid + loot values in tier range", bad == 0, "%d bad node(s)" % bad)
		# Таблица что-то раздала (узел ещё жив ЛИБО ящик уже выбит — бот мог начать фарм до проверки).
		_expect("farm table produced drops", with_drop + loose > 0, "no node yields anything")
		# Не каждый куб что-то даёт — ставка «ресурс / пусто / враг» жива.
		_expect("some cubes yield nothing", with_drop < cubes.size(),
			"every cube holds something - the farming gamble is gone")
	_expect("extraction points exist", st.get_nodes_in_group("ExtractionPoint").size() > 0,
		"no zone_role 'ExtractionPoint' markers - evacuation impossible")

	# Две точки выхода на окно: одна ближе к базе каждой команды (никогда две «свои» для одной).
	# Вывоз к чужой точке — ×GameConfig.extraction_far_point_multiplier.
	if em != null and em.has_method("_pick_active_points") and st.get_nodes_in_group("ExtractionPoint").size() >= 2:
		em._pick_active_points()
		var aps: Array = em._active_points
		_expect("announce picks two evac points on KitchenMap", aps.size() == 2,
			"got %d (expected one near each base)" % aps.size())
		if aps.size() == 2:
			var t0: int = int(em._active_near_team.get((aps[0] as Node3D).get_instance_id(), -1))
			var t1: int = int(em._active_near_team.get((aps[1] as Node3D).get_instance_id(), -1))
			_expect("evac points sit on opposite sides", (t0 == 0 and t1 == 1) or (t0 == 1 and t1 == 0),
				"near-team tags: %d, %d" % [t0, t1])
			var far_for0: Node3D = aps[0] if t0 == 1 else aps[1]   # точка НЕ у базы команды 0
			var near_for0: Node3D = aps[0] if t0 == 0 else aps[1]
			var mfar: float = float(em._bank_multiplier(far_for0, 0))
			var mnear: float = float(em._bank_multiplier(near_for0, 0))
			_expect("far point scores x extraction_far_point_multiplier",
				is_equal_approx(mfar, float(gc.extraction_far_point_multiplier)),
				"got x%.2f, config x%.2f" % [mfar, float(gc.extraction_far_point_multiplier)])
			_expect("own near point scores x1", is_equal_approx(mnear, 1.0), "got x%.2f" % mnear)
		# оставленное состояние безвредно (читается только при window_state == OPEN), но приберём
		em._active_points.clear()
		em._active_near_team.clear()
	if em != null:
		var em_src2 := FileAccess.get_file_as_string("res://scenes/main/extraction_manager.gd")
		_expect("_bank applies the point multiplier", em_src2.find("_bank_multiplier(") != -1,
			"_physics_process must pass _bank_multiplier() into _bank()")
	# Выгрузка/банк — только у стоящего/едущего танка. Гружёный танк, проваливающийся сквозь объём
	# зоны, раньше выгружал лут «в воздухе», и на fall-смерти добыча появлялась на складе вместо
	# места гибели. Нужны ВСЕ ТРИ флага, каждый ловит своё: is_on_floor() — ровный свободный полёт
	# (крена нет, кувырка нет); is_active() — кувырок (is_on_floor застревает на true); is_falling()
	# — крен на кромке BRINK/TEETER (is_on_floor честно true, кувырок ещё не начался).
	if em != null:
		var em_src := FileAccess.get_file_as_string("res://scenes/main/extraction_manager.gd")
		_expect("deposit/bank skips airborne tanks", em_src.find("is_on_floor()") != -1,
			"ExtractionManager._physics_process must skip airborne tanks for deposit/bank")
		_expect("deposit/bank skips tumbling tanks", em_src.find("is_active()") != -1,
			"ExtractionManager._physics_process must skip tumbling tanks for deposit/bank")
		_expect("deposit/bank skips teetering tanks", em_src.find("is_falling()") != -1,
			"ExtractionManager._physics_process must skip teetering tanks for deposit/bank")

	# Выпавшая добыча проецируется на достижимый навмеш: место снесённого куба само по себе —
	# консервативная навмеш-дыра (см. obstacle.gd), бот к упавшему туда ящику не доедет.
	if em != null:
		_expect("ExtractionManager has _reachable_drop_point()", em.has_method("_reachable_drop_point"),
			"loot-drop navmesh projection missing")
		if em.has_method("_reachable_drop_point"):
			# точка заведомо вне навмеша и далеко (высоко над картой) — границы отвергают проекцию,
			# возвращается вход без изменений (лут не телепортируется через полкарты)
			var far: Vector3 = Vector3(0.0, 500.0, 0.0)
			_expect("far off-navmesh drop point left as-is", em._reachable_drop_point(far, 4.0, 3.0) == far,
				"projection ignored its distance guard - loot would teleport across the map")
			# точка у базы (заведомо на навмеше) — сдвиг в пределах фарм-границы, не дальше
			var b0 = em._bases[0]
			if b0 != null:
				var near: Vector3 = (b0 as Node3D).global_position
				var moved: float = near.distance_to(em._reachable_drop_point(near, 4.0, 3.0))
				_expect("walkable drop point stays put", moved <= 4.5, "moved %.1f" % moved)

	# Трюм и его связка с маскировкой. «Груз блокирует маскировку» — больше НЕ общее правило, а
	# черта среднего класса; штраф скорости — общий (GameConfig, 15% за ящик), грузовой освобождён.
	# Ожидания читаются из класса танка игрока (Chassis), чтобы проверка работала на любом классе.
	var player := cs.get_node_or_null("PlayerTank")
	if player != null:
		var hold := player.get_node_or_null("CargoHold")
		var disguise := player.get_node_or_null("DisguiseController")
		var chassis := player.get_node_or_null("Chassis")
		_expect("PlayerTank/CargoHold present", hold != null, "missing cargo hold component")
		if hold != null and disguise != null and gc != null and chassis != null:
			_expect("hold capacity comes from chassis", int(hold.capacity) == int(chassis.cargo_capacity),
				"hold %d vs chassis %d" % [int(hold.capacity), int(chassis.cargo_capacity)])
			_expect("empty hold does not block disguise", not hold.blocks_disguise(), "blocked while empty")
			_expect("empty hold has no speed penalty", is_equal_approx(hold.speed_multiplier(), 1.0),
				"got %.3f" % hold.speed_multiplier())
			hold.try_take(100, false)
			var want_block: bool = bool(chassis.cargo_blocks_disguise)
			_expect("loaded hold blocks disguise only for the chassis trait", hold.blocks_disguise() == want_block,
				"blocks=%s, chassis trait=%s" % [hold.blocks_disguise(), want_block])
			_expect("disguise controller agrees", disguise.blocked_by_cargo() == hold.blocks_disguise(),
				"controller disagrees with hold")
			var want_mult: float = 1.0
			if bool(chassis.cargo_speed_penalty_enabled):
				want_mult = 1.0 - float(gc.cargo_speed_penalty_per_lot)
			_expect("one crate speed multiplier matches the rule", is_equal_approx(hold.speed_multiplier(), want_mult),
				"got %.3f, want %.3f" % [hold.speed_multiplier(), want_mult])
			# Вместимость: любой ящик (сырой / дозревший) — 1 место, набор до вместимости класса.
			hold.clear()
			var cap: int = int(hold.capacity)
			var took := 0
			for i in range(cap + 2):  # пробуем набрать БОЛЬШЕ вместимости, чередуя сырой/дозревший
				if hold.try_take(50, i % 2 == 0):
					took += 1
			_expect("hold fills to class capacity, mixed raw/ripe", took == cap,
				"took %d, capacity %d" % [took, cap])
			_expect("hold reports full at capacity", hold.is_full(), "is_full() false at %d lots" % hold.lot_count())
			hold.clear()
			# Подбор — ДЕЙСТВИЕ, а не телепорт. Танк появляется в круге своей базы, и Area3D ящика
			# шлёт body_entered на телепорт: без запрета воскресший танк всасывал собственный лут,
			# выпавший при гибели у базы, и следующим кадром выгружал его на склад.
			_expect("CargoHold has block_pickup()", hold.has_method("block_pickup"), "missing")
			if hold.has_method("block_pickup"):
				hold.block_pickup()
				_expect("post-respawn block refuses pickup", not hold.try_take(50, false),
					"hold accepted loot while the post-respawn block was active")
				hold._pickup_block_left = 0.0
				_expect("pickup works once the block expires", hold.try_take(50, false),
					"hold refuses loot with no block active")
				hold.clear()
			var rc_src := FileAccess.get_file_as_string("res://scenes/tank/respawn_controller.gd")
			_expect("RespawnController arms the pickup block", rc_src.find("block_pickup()") != -1,
				"_on_respawn_timeout must call CargoHold.block_pickup() after the spawn teleport")

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

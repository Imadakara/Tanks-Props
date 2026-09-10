extends Node
## ExtractionManager — ВСЕ правила режима EXTRACTION в одном месте.
## Концепция: `Tank_Prop_Hunt_Extraction_Loop_Concept.md`, техрешения: `Tank_Prop_Hunt_Extraction_Loop_TZ.md`.
##
## Заводится из кода корнем карты (`map_scene.gd._setup_match_context()`) тем же приёмом и в том же
## порядке, что `ScoreManager`/`MatchManager`, и обязательно ПОСЛЕ `TeamSpawner.spawn_team()` —
## подписка на гибель танков требует полного состава в группе "tanks".
##
## Что он делает и, главное, чего НЕ делает:
##  - раздаёт добычу по обычным кубам-укрытиям (детерминированно, по зерну);
##  - принимает выгрузку на склад и банкует в открытом окне эвакуации (вывоз к чужой базе — ×1.5);
##  - ведёт расписание окон и выбирает две точки выхода (по одной ближе к базе каждой команды);
##  - рассыпает трюм погибшего.
## Он НЕ хранит склад списком и НЕ реализует отдельную «механику рейда»: склад — это физически
## лежащие в круге базы `LootCrate`, а рейд — обычный подбор ящика вражеским танком. См.
## `scenes/loot/loot_crate.gd`.

const LootCrateScene := preload("res://scenes/loot/LootCrate.tscn")
## Бонусы, которые может отдать разрушенный лут-узел (см. `_spawn_bonus_crate` / farm_drop_weights).
## Патроны / аптечка / щит — универсальный `Pickup` (тип задаётся строкой kind_id, числа — в
## config/pickups.json); мортира — отдельный `ModCrate` (условный подбор).
const PickupScene := preload("res://scenes/pickups/Pickup.tscn")
const ModCrateScene := preload("res://scenes/mod_crate/ModCrate.tscn")
const ExtractionPointRole := "ExtractionPoint"

## Что даёт разрушенный лут-узел. Ролится ПЕРВЫМ, до яруса редкости (only LOOT дальше роллит ярус +
## ценность). Порядок = ключи `farm_drop_weights` в config/extraction_*.json.
enum FarmDrop { LOOT, NOTHING, AMMO, MOD, MEDKIT, SHIELD }
const _FARM_KEYS := ["loot", "nothing", "ammo", "mortar", "medkit", "shield"]  # индекс = FarmDrop

## Дефолты баланса — фолбэк, если config/extraction_*.json отсутствует / битый (некритично, как
## у team_spawner._load_json_config). Реальные значения — в JSON карты.
const _DEF_FARM := {"loot": 0.40, "nothing": 0.40, "ammo": 0.10, "mortar": 0.02, "medkit": 0.05, "shield": 0.03}
const _DEF_TIERS := [
	{"name": "Обычный", "weight": 0.70, "raw_min": 1, "raw_max": 10, "ripen_per_sec": 1, "ripen_cap": 75, "color": [0.62, 0.64, 0.66]},
	{"name": "Редкий", "weight": 0.20, "raw_min": 5, "raw_max": 15, "ripen_per_sec": 2, "ripen_cap": 150, "color": [0.28, 0.55, 1.0]},
	{"name": "Эпический", "weight": 0.07, "raw_min": 10, "raw_max": 25, "ripen_per_sec": 3, "ripen_cap": 300, "color": [0.62, 0.3, 0.9]},
	{"name": "Легендарный", "weight": 0.03, "raw_min": 20, "raw_max": 50, "ripen_per_sec": 4, "ripen_cap": 500, "color": [1.0, 0.55, 0.12]},
]

## Куда и как далеко вниз ищем опору под точкой (гибель носителя, разрушенный куб).
const _GROUND_PROBE_UP: float = 2.0
const _GROUND_PROBE_DOWN: float = 60.0
## Полувысота ящика — центр встаёт на эту высоту над опорой (то же, что у LootCrate/Pickup/ModCrate).
const _REST_OFFSET: float = 0.3
## Проекция точки выпадения ящика на ближайшую точку навмеша (см. `_reachable_drop_point`) — ящик
## оказывается там, куда бот реально доедет. `_EPS` — ближе этого точка и так на навмеше,
## проецировать незачем.
## ФАРМ: куб-укрытие запечён в навмеш как препятствие, после сноса на его месте остаётся
## КОНСЕРВАТИВНАЯ дыра проходимости (`obstacle.gd`) — навпуть бота обрывается на её кромке, а ящик,
## упавший в центр бывшего куба, физически подбираем, но недостижим по навмешу. Границы тесные:
## дыра от куба `2×2` + инфляция на радиус агента ≈ 3, дальше/разновысотнее «ближайшая» точка — это
## уже соседний ярус, туда лут двигать нельзя.
## СМЕРТЬ: танк мог свалиться в яму / за кромку, где навмеша нет вовсе — тогда лут лучше вынести на
## ближайший достижимый край (кто-то подберёт), чем оставить в недосягаемой яме. Границы шире —
## перепад до пары ярусов кухни, — но не через всю карту: улетевший ПОД карту по kill-plane танк за
## этими пределами, его добыче пропасть не жалко (патология).
const _NAV_PROJECT_EPS: float = 0.05
const _NAV_FARM_MAX_XZ: float = 4.0
const _NAV_FARM_MAX_Y: float = 3.0
const _NAV_DEATH_MAX_XZ: float = 20.0
const _NAV_DEATH_MAX_Y: float = 25.0
## Раскладка ящиков на складе: кольцо внутри круга базы, чтобы они не сливались в кучу и каждый
## можно было подобрать отдельно (склад делим по ящикам — концепт §7).
const _PARK_RING_FRACTION: float = 0.55
const _PARK_SLOTS: int = 12
## Высота и «толщина» столба над точкой выхода.
const _BEACON_HEIGHT: float = 40.0

signal window_announced(point: Node3D, seconds_to_open: float)
signal window_opened(point: Node3D)
signal window_closed()
signal loot_banked(team: int, value: int)

enum WindowState { CLOSED, ANNOUNCED, OPEN }

var banked: Array[int] = [0, 0]  # вывезено, по командам 0/1 — единственный счёт победы
var window_state: int = WindowState.CLOSED
## ПЕРВАЯ из активных точек — для внешних null-проверок «окно активно» (бот, HUD). Полный список —
## `_active_points` (в окне их ДВЕ: по одной ближе к базе каждой команды).
var active_point: Node3D = null

var _bases: Array = [null, null]  # SpawnZone каждой команды = её склад
var _points: Array = []  # кандидаты на точку выхода
## Активные точки текущего окна (1–2 шт). `_active_near_team`: instance_id точки → команда, к чьей
## базе точка ближе (0/1); -1 — нейтральная (вырожденный случай: одна общая точка).
var _active_points: Array[Node3D] = []
var _active_near_team: Dictionary = {}
var _elapsed: float = 0.0
var _next_window_index: int = 0
var _window_open_at: float = 0.0
var _window_close_at: float = 0.0
var _rng := RandomNumberGenerator.new()
var _halted: bool = false
## Баланс из config/extraction_*.json (путь — @export extraction_config_path на корне карты),
## читается в setup(). `_rarity` — массив словарей яруса; LootCrate берёт смысл яруса через
## геттеры rarity_*() ниже.
var _farm_weights: PackedFloat32Array = PackedFloat32Array()
var _rarity_weights: PackedFloat32Array = PackedFloat32Array()
var _rarity: Array = []
## Танки, которым запрещена автовыгрузка, пока они не покинут круг своей базы. Иначе ящик, взятый
## со склада для вывоза, тем же кадром лёг бы обратно. Ключ — instance id танка.
var _deposit_lock: Dictionary = {}
var _park_cursor: int = 0
var _beacons: Array[MeshInstance3D] = []  # столб над каждой активной точкой


func setup() -> void:
	add_to_group("extraction_manager")
	var scene := get_tree().current_scene
	_load_config(String(scene.get("extraction_config_path")) if scene.get("extraction_config_path") != null else "")
	_bases[0] = scene.find_child("AttackSpawnZone", true, false) as Node3D
	_bases[1] = scene.find_child("DefenseSpawnZone", true, false) as Node3D
	_points = get_tree().get_nodes_in_group(ExtractionPointRole)
	_points.sort_custom(func(a, b): return String(a.get_path()) < String(b.get_path()))
	if _points.is_empty():
		push_warning("ExtractionManager: на карте нет точек роли ExtractionPoint — эвакуация невозможна")
	if MatchState.loot_seed == 0:
		MatchState.loot_seed = randi() % 2147483646 + 1
	_rng.seed = MatchState.loot_seed
	_allocate_loot_nodes()
	_schedule_next_window()


func halt() -> void:
	_halted = true
	set_physics_process(false)
	_clear_beacons()


# --- Конфиг баланса (config/extraction_*.json) ------------------------------------------------

## Читает JSON-файл баланса выпадения. Отсутствует / битый — дефолты `_DEF_*` (некритично, тот же
## приём, что у `team_spawner._load_json_config`).
func _load_config(path: String) -> void:
	var data: Dictionary = {}
	if path != "" and FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			data = parsed
		else:
			push_warning("ExtractionManager: битый JSON %s — беру дефолты" % path)
	else:
		push_warning("ExtractionManager: конфиг '%s' не найден — беру дефолты" % path)

	var fw: Dictionary = data.get("farm_drop_weights", _DEF_FARM)
	_farm_weights = PackedFloat32Array()
	for key in _FARM_KEYS:
		_farm_weights.append(float(fw.get(key, 0.0)))

	var tiers: Array = data.get("rarity_tiers", _DEF_TIERS)
	_rarity.clear()
	_rarity_weights = PackedFloat32Array()
	for t in tiers:
		var col := Color(1, 1, 1)
		var cv: Variant = t.get("color")
		if cv is Array and (cv as Array).size() >= 3:
			col = Color(float(cv[0]), float(cv[1]), float(cv[2]))
		_rarity.append({
			"name": String(t.get("name", "?")),
			"raw_min": int(t.get("raw_min", 1)),
			"raw_max": int(t.get("raw_max", 1)),
			"ripen_per_sec": int(t.get("ripen_per_sec", 1)),
			"ripen_cap": int(t.get("ripen_cap", 1)),
			"color": col,
		})
		_rarity_weights.append(float(t.get("weight", 0.0)))
	if _rarity.is_empty():
		push_warning("ExtractionManager: в конфиге нет rarity_tiers — лут будет пустым")


# --- Смысл яруса редкости (для LootCrate, у которого своего доступа к конфигу нет) ------------

func rarity_count() -> int:
	return _rarity.size()

func _ri(i: int) -> int:
	return clampi(i, 0, maxi(_rarity.size() - 1, 0))

func rarity_name(i: int) -> String:
	return String(_rarity[_ri(i)]["name"]) if not _rarity.is_empty() else "?"

func rarity_raw_min(i: int) -> int:
	return int(_rarity[_ri(i)]["raw_min"]) if not _rarity.is_empty() else 0

func rarity_raw_max(i: int) -> int:
	return int(_rarity[_ri(i)]["raw_max"]) if not _rarity.is_empty() else 0

func rarity_ripen_per_sec(i: int) -> int:
	return int(_rarity[_ri(i)]["ripen_per_sec"]) if not _rarity.is_empty() else 0

func rarity_ripen_cap(i: int) -> int:
	return int(_rarity[_ri(i)]["ripen_cap"]) if not _rarity.is_empty() else 0

func rarity_color(i: int) -> Color:
	return _rarity[_ri(i)]["color"] if not _rarity.is_empty() else Color(1, 1, 1)


# --- Добыча: раздача по кубам ------------------------------------------------------------------

## Лут раздаётся среди ОБЫЧНЫХ кубов-укрытий (группа "obstacles"), а не по особым узлам: ресурсный
## узел обязан быть неотличим от укрытия и от замаскированного танка (концепт §6) — иначе игрок
## приучится стрелять по помеченным кубам бесплатно и маскировка умрёт как явление.
##
## КАЖДЫЙ куб роллит `farm_drop_weights` — веса из JSON и есть литеральная вероятность на куб
## («ничего» — такой же исход таблицы, как лут/патроны/…, и он же регулирует, насколько карта
## пустая). Прежде раздача обрезалась до `loot_node_count` кубов, остальные молча оставались
## `NOTHING` — на карте с 21 кубом и `loot_node_count = 10` фактический P(лут) падал вдвое ниже
## записанного в конфиге; лишний лимит убран.
##
## Порядок обхода — по `get_path()`: при одинаковом `MatchState.loot_seed` цепочка роллов `_rng`
## ложится на кубы 1:1, раскладка байт-в-байт одинакова у всех пиров (задел под сеть). От порядка
## РАЗРУШЕНИЯ кубов раскладка не зависит — узлы не респавнятся.
func _allocate_loot_nodes() -> void:
	var cubes: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if is_instance_valid(o) and "loot_value" in o:
			cubes.append(o)
	cubes.sort_custom(func(a, b): return String(a.get_path()) < String(b.get_path()))
	if cubes.is_empty():
		push_warning("ExtractionManager: на карте нет кубов группы obstacles — добывать нечего")
		return
	for i in range(cubes.size()):
		# На каждый узел: сперва ЧТО он даст (farm_drop_weights), и только если «лут» — ярус + сырая
		# ценность.
		var drop: int = _roll_farm_drop()
		cubes[i].drop_kind = drop
		if drop == FarmDrop.LOOT:
			var rar: int = _roll_rarity()
			cubes[i].loot_rarity = rar
			cubes[i].loot_value = _rng.randi_range(rarity_raw_min(rar), rarity_raw_max(rar))


## Взвешенный выбор индекса из массива весов по зерну. Веса не обязаны быть нормированы.
func _weighted_pick(w: PackedFloat32Array) -> int:
	var total: float = 0.0
	for x in w:
		total += x
	if total <= 0.0:
		return 0
	var r: float = _rng.randf() * total
	var acc: float = 0.0
	for i in range(w.size()):
		acc += w[i]
		if r < acc:
			return i
	return w.size() - 1


## Что даст этот узел при разрушении — индекс FarmDrop по `farm_drop_weights` из JSON.
func _roll_farm_drop() -> int:
	return _weighted_pick(_farm_weights) if not _farm_weights.is_empty() else int(FarmDrop.NOTHING)


## Ярус ЛУТА по весам ярусов (`rarity_tiers[i].weight` из JSON).
func _roll_rarity() -> int:
	return _weighted_pick(_rarity_weights) if not _rarity_weights.is_empty() else 0


## Вход для куба, который только что развалился (`obstacle.gd._on_destroyed`). Менеджер сам читает
## у куба `drop_kind` / `loot_value` / `loot_rarity` (розданы в `_allocate_loot_nodes`) и решает,
## что уронить. `node` же — `ignore_body` для рейкаста опоры: его коллайдер в этот момент ЕЩЁ ЖИВ
## (queue_free() отрабатывает после сигнала destroyed), без исключения луч нашёл бы КРЫШУ куба и
## ящик завис бы на его высоте, физически неподбираемый.
## `extra_exclude` — ещё тела, которые луч должен пропустить: у objective-цели
## (scenes/objective_target/) `node` — не само тело, а корень-префаб, тело цели и турель на её
## крыше — отдельные коллайдеры, оба ещё живы в момент вызова.
func spawn_node_drop(node: Node3D, extra_exclude: Array = []) -> void:
	if _halted:
		return
	var dk: int = int(node.get("drop_kind"))
	if dk == FarmDrop.NOTHING:
		return
	# Проецируем на проходимое место ДО спавна: место снесённого куба само по себе — навмеш-дыра,
	# в которую бот не доедет (см. _reachable_drop_point).
	var ignore: Array = [node]
	ignore.append_array(extra_exclude)
	var ground: Vector3 = _reachable_drop_point(
			_ground_under(node.global_position, ignore), _NAV_FARM_MAX_XZ, _NAV_FARM_MAX_Y)
	if dk == FarmDrop.LOOT:
		if int(node.get("loot_value")) > 0:
			_spawn_crate(ground, int(node.get("loot_value")), int(node.get("loot_rarity")), false)
		return
	_spawn_bonus_crate(ground, dk)


# --- Ящики -------------------------------------------------------------------------------------

## Бонус из фарма (не лут): ящик патронов / аптечка / щит — универсальный `Pickup`; мортира —
## отдельный `ModCrate`. Ставится сразу на опору (без падения с неба), как и лут-ящик.
func _spawn_bonus_crate(ground_point: Vector3, drop_kind: int) -> void:
	if drop_kind == FarmDrop.MOD:
		var mc: Node3D = ModCrateScene.instantiate()
		get_tree().current_scene.add_child(mc)
		mc.fall_to(ground_point, ground_point.y + _REST_OFFSET, 1.0)  # start_y == rest_y → сразу на опоре
		return
	var kid: StringName = &""
	match drop_kind:
		FarmDrop.AMMO: kid = &"ammo"
		FarmDrop.MEDKIT: kid = &"medkit"
		FarmDrop.SHIELD: kid = &"shield"
	if kid == &"":
		return
	var p: Node3D = PickupScene.instantiate()
	p.kind_id = kid
	get_tree().current_scene.add_child(p)
	p.place_at(ground_point)


func _spawn_crate(ground_point: Vector3, value: int, rarity: int, frozen: bool) -> Node3D:
	var crate: Node3D = LootCrateScene.instantiate()
	crate.base_value = value
	crate.rarity = rarity
	crate.frozen = frozen
	crate.picked_up.connect(_on_crate_picked_up)
	get_tree().current_scene.add_child(crate)
	crate.set_loose(ground_point)
	return crate


## Ящик подобран. Единственное, что менеджеру тут нужно, — заметить ВЫЕМКУ СО СКЛАДА: пока танк не
## покинул круг базы, автовыгрузка для него запрещена, иначе только что взятый на вывоз ящик лёг бы
## обратно тем же кадром и рейс был бы невозможен. Замок снимается, как только танк выехал из круга
## (см. _physics_process) — вернулся передумав, значит и правда вернул груз на склад.
func _on_crate_picked_up(crate: Node, by_tank: Node) -> void:
	if int(crate.owner_team) >= 0:
		_deposit_lock[by_tank.get_instance_id()] = true


## Ближайшая точка навмеша к `raw`, если она РЯДОМ и на ТОЙ ЖЕ высоте (границы — от вызывающего:
## `_NAV_FARM_*` для фарма, `_NAV_DEATH_*` для россыпи при гибели). Иначе — сам `raw` без изменений.
## Зачем: место снесённого куба и дно ямы, куда мог свалиться танк, — навмеш-дыры; ящик там
## физически подбираем, но бот к нему по навпути не доедет. Детерминизм цел — `map_get_closest_point`
## однозначен при том же запечённом навмеше (карта печётся детерминированно, `bake_navmesh_on_start`).
## `closest` — точка НА полигоне навмеша (он приподнят/приспущен относительно реальной геометрии),
## поэтому настоящую опору под ней всё равно доищем лучом, как для любого спавна.
func _reachable_drop_point(raw: Vector3, max_xz: float, max_y: float) -> Vector3:
	var map: RID = get_viewport().find_world_3d().get_navigation_map()
	if not map.is_valid():
		return raw
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(map, raw)
	var xz: float = Vector2(closest.x - raw.x, closest.z - raw.z).length()
	if xz <= _NAV_PROJECT_EPS or xz > max_xz or absf(closest.y - raw.y) > max_y:
		return raw
	return _ground_under(Vector3(closest.x, raw.y, closest.z))


## Опора под точкой. Ничего не нашли (танк провалился ниже карты / куб висел над пустотой) —
## возвращаем саму точку: ящик хотя бы не исчезнет из игры бесследно.
func _ground_under(p: Vector3, ignore_bodies: Array = []) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
	var origin: Vector3 = p + Vector3(0.0, _GROUND_PROBE_UP, 0.0)
	var q := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * _GROUND_PROBE_DOWN)
	q.collision_mask = 1
	var rids: Array[RID] = []
	for b in ignore_bodies:
		if is_instance_valid(b) and b is CollisionObject3D:
			rids.append((b as CollisionObject3D).get_rid())
	q.exclude = rids
	var hit: Dictionary = space.intersect_ray(q)
	return hit["position"] if not hit.is_empty() else p


## Место для ящика на складе: точки по кольцу внутри круга базы, по очереди. Ящики не сваливаются
## в одну кучу — каждый видно и каждый можно подобрать отдельно (склад делим, концепт §7).
func _park_slot(base: Node3D) -> Vector3:
	var radius: float = float(base.get("radius")) * _PARK_RING_FRACTION
	var angle: float = TAU * float(_park_cursor % _PARK_SLOTS) / float(_PARK_SLOTS)
	var ring: int = _park_cursor / _PARK_SLOTS
	_park_cursor += 1
	var r: float = radius * (1.0 - 0.28 * float(ring % 3))
	return _ground_under(base.global_position + Vector3(cos(angle) * r, 0.0, sin(angle) * r))


# --- Основной цикл: выгрузка, банк, окна --------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _halted:
		return
	_elapsed += delta
	_tick_window()
	for tank in get_tree().get_nodes_in_group("tanks"):
		if not is_instance_valid(tank):
			continue
		_watch_tank(tank)
		var health: Node = tank.get_node_or_null("HealthComponent")
		if health == null or not health.is_alive:
			continue
		var hold: Node = tank.get_node_or_null("CargoHold")
		if hold == null:
			continue
		var team: int = int(tank.team)
		if team < 0 or team >= _bases.size():
			continue  # NPC-сторона (охрана objective-целей) — ни базы, ни банка
		var base: Node3D = _bases[team]
		var in_base: bool = base != null and _inside(tank, base)
		# В какой из активных точек стоит танк (окно открыто). Точек в окне до двух — берём первую,
		# в чей круг он попал.
		var here_point: Node3D = null
		if window_state == WindowState.OPEN:
			for p in _active_points:
				if is_instance_valid(p) and _inside(tank, p):
					here_point = p
					break
		var window_here: bool = here_point != null
		var key: int = tank.get_instance_id()
		if not in_base:
			_deposit_lock.erase(key)  # покинул базу — автовыгрузка снова разрешена
		if not in_base and not window_here:
			continue

		# Выгрузка/банк — только у танка, который СТОИТ ИЛИ ЕДЕТ по зоне сам, а не проваливается
		# сквозь её объём. Обе зоны (база, точки выхода) стоят на приподнятых ярусах кухни, поэтому
		# траектория падения с верхнего яруса протыкает их цилиндр (радиус ~8, ±
		# `extraction_zone_height_tolerance`). Без этой отсечки гружёный танк выгружал трюм «в
		# воздухе»: к моменту смерти трюм уже пуст, `_on_tank_destroyed` рассыпать нечего — добыча
		# появлялась на складе вместо места гибели.
		#
		# Три флага, и все три нужны: каждый ловит случай, невидимый для остальных.
		#   1. НЕ НА ЗЕМЛЕ — свободный полёт. Съехал с кромки ровно или улетел с трамплина: крена
		#      нет (`_tip_angle == 0`), кувырок не запускается (`_edge_approach ≈ 0`) — оба флага
		#      ниже молчат, ловит только `is_on_floor()`.
		#   2. КУВЫРОК — `is_on_floor()` тут бесполезен: сиблинги заморожены (`process_mode`),
		#      `move_and_slide()` не идёт, и значение застревает на последнем `true`.
		#   3. КРЕН НА КРОМКЕ (BRINK / TEETER) — танк ещё касается опоры, `is_on_floor()` честно
		#      `true`, кувырок ещё не начался, но танк уже валится в пустоту.
		if tank.has_method("is_on_floor") and not tank.is_on_floor():
			continue
		var tc: Node = tank.get_node_or_null("TumbleController")
		if tc != null and tc.has_method("is_active") and tc.is_active():
			continue
		var mv: Node = tank.get_node_or_null("TankMovement")
		if mv != null and mv.has_method("is_falling") and mv.is_falling():
			continue

		# Банк ВЫШЕ выгрузки: если точка выхода окажется рядом с базой, вывоз должен побеждать —
		# он окончателен, а склад лишь промежуточен.
		if window_here and hold.is_loaded():
			_bank(hold, team, _bank_multiplier(here_point, team))
			continue
		if in_base and hold.is_loaded() and not _deposit_lock.has(key):
			_deposit(hold, team, base)


## Выгрузка на свой склад: каждый лот становится физическим ящиком в круге базы и начинает
## дозревать. Лот, помеченный `frozen` (побывал на чьём-то складе — в т.ч. украденный), дальше не
## растёт: грабёж выгоден, но не выгоднее честной добычи (концепт §7).
func _deposit(hold: Node, team: int, base: Node3D) -> void:
	for lot in hold.take_all():
		var crate: Node3D = LootCrateScene.instantiate()
		crate.base_value = int(lot["value"])
		crate.rarity = int(lot.get("rarity", 0))
		crate.frozen = bool(lot["frozen"])
		crate.picked_up.connect(_on_crate_picked_up)
		get_tree().current_scene.add_child(crate)
		crate.set_stored(_park_slot(base), team)


## Вывоз: весь трюм в счёт команды. `mult` — множитель за точку (см. `_bank_multiplier`): вывоз в
## точку у чужой базы даёт ×`GameConfig.extraction_far_point_multiplier`, в свою ближнюю — ×1.
func _bank(hold: Node, team: int, mult: float = 1.0) -> void:
	var gained: int = 0
	for lot in hold.take_all():
		gained += int(lot["value"])
	if gained <= 0:
		return
	var scored: int = int(round(float(gained) * mult))
	banked[team] += scored
	loot_banked.emit(team, scored)


## Множитель очков за вывоз в ЭТУ точку для ЭТОЙ команды. Точка ближе к базе врага, а не к своей
## (`_active_near_team[point] != team`) → ×`GameConfig.extraction_far_point_multiplier` (награда за
## то, что везли дальше, через территорию врага). Своя ближняя точка или нейтральная (вырожденный
## случай, одна точка на всех) → ×1.
func _bank_multiplier(point: Node3D, team: int) -> float:
	if point == null:
		return 1.0
	var near_team: int = int(_active_near_team.get(point.get_instance_id(), -1))
	return GameConfig.extraction_far_point_multiplier if near_team >= 0 and near_team != team else 1.0


## Накоплено на складе команды — считается по РЕАЛЬНО лежащим ящикам, отдельного счётчика нет:
## один источник истины, склад невозможно рассинхронизировать с тем, что видно на карте.
func stored_value(team: int) -> int:
	var sum: int = 0
	for c in get_tree().get_nodes_in_group("loot_crates"):
		if is_instance_valid(c) and int(c.owner_team) == team:
			sum += c.current_value()
	return sum


func loose_crate_count() -> int:
	var n: int = 0
	for c in get_tree().get_nodes_in_group("loot_crates"):
		if is_instance_valid(c) and int(c.owner_team) < 0:
			n += 1
	return n


## Круг зоны по XZ плюс допуск по высоте — на многоуровневой карте под базой/точкой выхода проходит
## пол, и без ограничения по Y всё засчитывалось бы этажом ниже. Тот же допуск, что у доставки.
func _inside(tank: Node3D, zone: Node3D) -> bool:
	var radius: float = float(zone.get("radius"))
	var flat: float = Vector2(tank.global_position.x - zone.global_position.x,
			tank.global_position.z - zone.global_position.z).length()
	if flat > radius:
		return false
	return absf(tank.global_position.y - zone.global_position.y) <= GameConfig.extraction_zone_height_tolerance


# --- Окна эвакуации ----------------------------------------------------------------------------

## Расписание известно заранее (концепт §8) — считается арифметикой от старта раунда, а не
## таймерами: так в любой момент можно сказать, когда следующее окно, не заводя лишних узлов.
## Всего окон — `extraction_window_count`; после последнего окон больше нет, и в момент его
## закрытия заканчивается матч (RoundTimer выставлен на `total_match_sec()`).
func _schedule_next_window() -> void:
	if _next_window_index >= GameConfig.extraction_window_count:
		_window_open_at = INF
		_window_close_at = INF
		return
	_window_open_at = GameConfig.extraction_first_window_sec \
		+ GameConfig.extraction_window_interval_sec * float(_next_window_index)
	_window_close_at = _window_open_at + GameConfig.extraction_window_duration_sec


## Полная длина матча = момент закрытия последнего окна. Единый источник и для RoundTimer
## (map_scene.gd читает отсюда при setup), и для расписания выше.
func total_match_sec() -> float:
	return GameConfig.extraction_first_window_sec \
		+ GameConfig.extraction_window_interval_sec * float(maxi(GameConfig.extraction_window_count - 1, 0)) \
		+ GameConfig.extraction_window_duration_sec


func _tick_window() -> void:
	if is_inf(_window_open_at):
		return
	match window_state:
		WindowState.CLOSED:
			if _elapsed >= _window_open_at - GameConfig.extraction_announce_lead_sec:
				_announce()
		WindowState.ANNOUNCED:
			if _elapsed >= _window_open_at:
				window_state = WindowState.OPEN
				_update_beacons()
				window_opened.emit(active_point)
		WindowState.OPEN:
			if _elapsed >= _window_close_at:
				window_state = WindowState.CLOSED
				active_point = null
				_active_points = []
				_active_near_team = {}
				_clear_beacons()
				_next_window_index += 1
				_schedule_next_window()
				window_closed.emit()


## Точки объявляются заранее, но заранее НЕ известны: выбираются из кандидатов тем же зерном.
## Предсказуемая география породила бы кемп у одной точки (концепт §8).
func _announce() -> void:
	if _points.is_empty():
		return
	_pick_active_points()
	if _active_points.is_empty():
		return
	active_point = _active_points[0]
	window_state = WindowState.ANNOUNCED
	_update_beacons()
	window_announced.emit(active_point, _window_open_at - _elapsed)


## Две точки на окно: одна ближе к базе команды 0, другая — к базе команды 1. НИКОГДА две «свои»
## для одной команды — обе стороны должны иметь короткий и длинный вариант вывоза. Каждая тянется
## тем же зерном из своего подмножества кандидатов (разбивка по тому, к чьей базе точка ближе).
## Вырожденный случай — все кандидаты ближе к одной базе, или точка всего одна: тогда одна общая
## нейтральная точка без множителя, как было раньше (`near_team = -1`).
func _pick_active_points() -> void:
	_active_points = []
	_active_near_team = {}
	var b0: Node3D = _bases[0]
	var b1: Node3D = _bases[1]
	var near: Array = [[], []]  # near[0] — кандидаты ближе к базе 0, near[1] — к базе 1
	if b0 != null and b1 != null:
		for p in _points:
			var d0: float = p.global_position.distance_to(b0.global_position)
			var d1: float = p.global_position.distance_to(b1.global_position)
			near[0 if d0 <= d1 else 1].append(p)
	if not near[0].is_empty() and not near[1].is_empty():
		var p0: Node3D = near[0][_rng.randi_range(0, near[0].size() - 1)]
		var p1: Node3D = near[1][_rng.randi_range(0, near[1].size() - 1)]
		_active_points = [p0, p1]
		_active_near_team = {p0.get_instance_id(): 0, p1.get_instance_id(): 1}
	else:
		var p: Node3D = _points[_rng.randi_range(0, _points.size() - 1)] as Node3D
		_active_points = [p]
		_active_near_team = {p.get_instance_id(): -1}


## Ближайшая к позиции `from` активная точка — куда боту ехать в рейс (см. `tank_ai_controller`).
func nearest_active_point(from: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for p in _active_points:
		if not is_instance_valid(p):
			continue
		var d: float = from.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## Сколько секунд до ближайшего события окна: до открытия (пока закрыто/объявлено) или до закрытия
## (пока открыто). -1 — окон больше не будет.
func seconds_to_next_event() -> float:
	if is_inf(_window_open_at):
		return -1.0
	if window_state == WindowState.OPEN:
		return maxf(0.0, _window_close_at - _elapsed)
	return maxf(0.0, _window_open_at - _elapsed)


## Столб над КАЖДОЙ активной точкой. Объявление точки — событие, ЗАМЕНЯЮЩЕЕ переговоры (концепт §8):
## все увидели маркеры и сами решили, кто едет, кто прикрывает. Поэтому строится из кода и виден
## ВСЕГДА, а не только в debug-режиме: это игровая информация, а не отладочный визуал.
func _update_beacons() -> void:
	_clear_beacons()
	for p in _active_points:
		if not is_instance_valid(p):
			continue
		_beacons.append(_make_beacon(p, int(_active_near_team.get(p.get_instance_id(), -1))))


## Один столб. `near_team` — команда, к чьей базе точка ближе: подмешиваем её цвет в столб, чтобы
## игрок выучил «синий столб у синей базы → красным за вывоз сюда ×1.5». -1 (нейтральная) — без
## подмеса.
func _make_beacon(point: Node3D, near_team: int) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ExtractionBeacon"
	var cyl := CylinderMesh.new()
	var r: float = float(point.get("radius")) * 0.9
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = _BEACON_HEIGHT
	mesh_inst.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Объявлено, но ещё закрыто — тусклый янтарь; открыто — яркий зелёный.
	var col: Color = Color(0.2, 0.95, 0.35, 0.22) if window_state == WindowState.OPEN \
		else Color(0.95, 0.7, 0.15, 0.13)
	if near_team == 0:
		col = col.lerp(Color(GameConfig.team_attack_color, col.a), 0.35)
	elif near_team == 1:
		col = col.lerp(Color(GameConfig.team_defense_color, col.a), 0.35)
	mat.albedo_color = col
	mesh_inst.material_override = mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mesh_inst)
	mesh_inst.global_position = point.global_position + Vector3(0.0, _BEACON_HEIGHT * 0.5, 0.0)
	return mesh_inst


func _clear_beacons() -> void:
	for b in _beacons:
		if b != null and is_instance_valid(b):
			b.queue_free()
	_beacons = []


# --- Смерть носителя ---------------------------------------------------------------------------

func _watch_tank(tank: Node) -> void:
	var health: Node = tank.get_node_or_null("HealthComponent")
	if health == null:
		return
	var handler := _on_tank_destroyed.bind(tank)
	if not health.destroyed.is_connected(handler):
		health.destroyed.connect(handler)


## Смерть дешева, дорого стоит ВЛАДЕНИЕ добычей (концепт §10): убитый роняет весь трюм на землю с
## сохранённой ценностью, поднять может кто угодно. Это и даёт отстающей команде роль хищника
## вместо приговора. Каждый ящик проецируем на достижимый навмеш (широкие границы `_NAV_DEATH_*`):
## танк мог свалиться в яму / за кромку, где навмеша нет, — тогда лут выносится на ближайший край,
## а не остаётся в недосягаемой дыре. На нормальной земле проекция — почти нулевой сдвиг.
func _on_tank_destroyed(_killer: Node, tank: Node) -> void:
	if _halted or not is_instance_valid(tank):
		return
	var hold: Node = tank.get_node_or_null("CargoHold")
	if hold == null or not hold.is_loaded():
		return
	var ground: Vector3 = _ground_under(tank.global_position)
	var lots: Array = hold.take_all()
	for i in lots.size():
		# Разносим россыпь по кругу — иначе ящики лягут друг в друга и подберутся все разом.
		var offset := Vector3.ZERO
		if lots.size() > 1:
			var a: float = TAU * float(i) / float(lots.size())
			offset = Vector3(cos(a) * 1.2, 0.0, sin(a) * 1.2)
		var drop: Vector3 = _reachable_drop_point(
				_ground_under(ground + offset), _NAV_DEATH_MAX_XZ, _NAV_DEATH_MAX_Y)
		_spawn_crate(drop, int(lots[i]["value"]), int(lots[i].get("rarity", 0)), bool(lots[i]["frozen"]))

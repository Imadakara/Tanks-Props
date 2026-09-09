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
##  - принимает выгрузку на склад и банкует в открытом окне эвакуации;
##  - ведёт расписание окон и выбирает точку выхода;
##  - рассыпает трюм погибшего.
## Он НЕ хранит склад списком и НЕ реализует отдельную «механику рейда»: склад — это физически
## лежащие в круге базы `LootCrate`, а рейд — обычный подбор ящика вражеским танком. См.
## `scenes/loot/loot_crate.gd`.

const LootCrateScene := preload("res://scenes/loot/LootCrate.tscn")
const ExtractionPointRole := "ExtractionPoint"

## Куда и как далеко вниз ищем опору под точкой (гибель носителя, разрушенный куб).
const _GROUND_PROBE_UP: float = 2.0
const _GROUND_PROBE_DOWN: float = 60.0
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
var active_point: Node3D = null

var _bases: Array = [null, null]  # SpawnZone каждой команды = её склад
var _points: Array = []  # кандидаты на точку выхода
var _elapsed: float = 0.0
var _next_window_index: int = 0
var _window_open_at: float = 0.0
var _window_close_at: float = 0.0
var _rng := RandomNumberGenerator.new()
var _halted: bool = false
## Танки, которым запрещена автовыгрузка, пока они не покинут круг своей базы. Иначе ящик, взятый
## со склада для вывоза, тем же кадром лёг бы обратно. Ключ — instance id танка.
var _deposit_lock: Dictionary = {}
var _park_cursor: int = 0
var _beacon: MeshInstance3D = null


func setup() -> void:
	add_to_group("extraction_manager")
	var scene := get_tree().current_scene
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
	_clear_beacon()


# --- Добыча: раздача по кубам ------------------------------------------------------------------

## Лут раздаётся среди ОБЫЧНЫХ кубов-укрытий (группа "obstacles"), а не по особым узлам: ресурсный
## узел обязан быть неотличим от укрытия и от замаскированного танка (концепт §6) — иначе игрок
## приучится стрелять по помеченным кубам бесплатно и маскировка умрёт как явление.
## Выбор детерминирован зерном `MatchState.loot_seed`: тот же приём, что у динамической расстановки
## препятствий, и та же цель — один int от хоста даст всем пирам одинаковую карту добычи.
func _allocate_loot_nodes() -> void:
	var cubes: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if is_instance_valid(o) and "loot_value" in o:
			cubes.append(o)
	cubes.sort_custom(func(a, b): return String(a.get_path()) < String(b.get_path()))
	if cubes.is_empty():
		push_warning("ExtractionManager: на карте нет кубов группы obstacles — добывать нечего")
		return
	# Тасуем СВОИМ rng: Array.shuffle() берёт глобальный и сломал бы детерминизм по зерну.
	for i in range(cubes.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp = cubes[i]
		cubes[i] = cubes[j]
		cubes[j] = tmp
	var count: int = mini(GameConfig.loot_node_count, cubes.size())
	for i in range(count):
		# Свой ролл яруса и сырой ценности на каждый узел, из того же зерна и в уже стасованном
		# порядке — раскладка добычи детерминирована и не зависит от того, в каком порядке кубы
		# будут разбиты. Узлы не респавнятся: этот ролл и есть «ценность при спавне ящика».
		var rar: int = _roll_rarity()
		cubes[i].loot_rarity = rar
		cubes[i].loot_value = _rng.randi_range(
			GameConfig.loot_rarity_raw_min[rar], GameConfig.loot_rarity_raw_max[rar])


## Ярус ящика тянется из зерна по весам `GameConfig.loot_rarity_weights` (в сумме 1.0).
func _roll_rarity() -> int:
	var w: PackedFloat32Array = GameConfig.loot_rarity_weights
	var r: float = _rng.randf()
	var acc: float = 0.0
	for i in range(w.size() - 1):
		acc += w[i]
		if r < acc:
			return i
	return w.size() - 1


## Публичный вход для куба, который только что развалился (`obstacle.gd._on_destroyed`).
func spawn_loose_loot(from_pos: Vector3, value: int, rarity: int, ignore_body: Node = null) -> void:
	if _halted:
		return
	# `ignore_body` — сам разваливающийся куб. Его коллайдер в этот момент ЕЩЁ ЖИВ (queue_free()
	# отрабатывает после сигнала destroyed), и без исключения луч находил бы КРЫШУ куба: ящик
	# зависал бы на его высоте над реальной опорой и становился физически неподбираемым.
	_spawn_crate(_ground_under(from_pos, ignore_body), value, rarity, false)


# --- Ящики -------------------------------------------------------------------------------------

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


## Опора под точкой. Ничего не нашли (танк провалился ниже карты / куб висел над пустотой) —
## возвращаем саму точку: ящик хотя бы не исчезнет из игры бесследно.
func _ground_under(p: Vector3, ignore_body: Node = null) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
	var origin: Vector3 = p + Vector3(0.0, _GROUND_PROBE_UP, 0.0)
	var q := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * _GROUND_PROBE_DOWN)
	q.collision_mask = 1
	if ignore_body is CollisionObject3D:
		q.exclude = [(ignore_body as CollisionObject3D).get_rid()]
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
		var base: Node3D = _bases[team]
		var in_base: bool = base != null and _inside(tank, base)
		var key: int = tank.get_instance_id()
		if not in_base:
			_deposit_lock.erase(key)  # покинул базу — автовыгрузка снова разрешена
		# Банк ВЫШЕ выгрузки: если точка выхода окажется рядом с базой, вывоз должен побеждать —
		# он окончателен, а склад лишь промежуточен.
		if window_state == WindowState.OPEN and active_point != null and hold.is_loaded() \
				and _inside(tank, active_point):
			_bank(hold, team)
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


func _bank(hold: Node, team: int) -> void:
	var gained: int = 0
	for lot in hold.take_all():
		gained += int(lot["value"])
	if gained <= 0:
		return
	banked[team] += gained
	loot_banked.emit(team, gained)


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
				_update_beacon()
				window_opened.emit(active_point)
		WindowState.OPEN:
			if _elapsed >= _window_close_at:
				window_state = WindowState.CLOSED
				active_point = null
				_clear_beacon()
				_next_window_index += 1
				_schedule_next_window()
				window_closed.emit()


## Точка объявляется заранее, но заранее НЕ известна: выбирается из кандидатов тем же зерном.
## Предсказуемая география породила бы кемп у одной точки (концепт §8). Точка ОДНА и общая для
## обеих команд — разные выходы превратили бы матч в два параллельных без контакта.
func _announce() -> void:
	if _points.is_empty():
		return
	active_point = _points[_rng.randi_range(0, _points.size() - 1)] as Node3D
	window_state = WindowState.ANNOUNCED
	_update_beacon()
	window_announced.emit(active_point, _window_open_at - _elapsed)


## Сколько секунд до ближайшего события окна: до открытия (пока закрыто/объявлено) или до закрытия
## (пока открыто). -1 — окон больше не будет.
func seconds_to_next_event() -> float:
	if is_inf(_window_open_at):
		return -1.0
	if window_state == WindowState.OPEN:
		return maxf(0.0, _window_close_at - _elapsed)
	return maxf(0.0, _window_open_at - _elapsed)


## Столб над активной точкой. Объявление точки — событие, ЗАМЕНЯЮЩЕЕ переговоры (концепт §8): все
## увидели маркер и сами решили, кто едет, кто прикрывает. Поэтому строится из кода и виден ВСЕГДА,
## а не только в debug-режиме: это игровая информация, а не отладочный визуал.
func _update_beacon() -> void:
	_clear_beacon()
	if active_point == null:
		return
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ExtractionBeacon"
	var cyl := CylinderMesh.new()
	var r: float = float(active_point.get("radius")) * 0.9
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = _BEACON_HEIGHT
	mesh_inst.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Объявлено, но ещё закрыто — тусклый янтарь; открыто — яркий зелёный.
	mat.albedo_color = Color(0.2, 0.95, 0.35, 0.22) if window_state == WindowState.OPEN \
		else Color(0.95, 0.7, 0.15, 0.13)
	mesh_inst.material_override = mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mesh_inst)
	mesh_inst.global_position = active_point.global_position + Vector3(0.0, _BEACON_HEIGHT * 0.5, 0.0)
	_beacon = mesh_inst


func _clear_beacon() -> void:
	if _beacon != null and is_instance_valid(_beacon):
		_beacon.queue_free()
	_beacon = null


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
## вместо приговора.
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
		_spawn_crate(_ground_under(ground + offset), int(lots[i]["value"]), int(lots[i].get("rarity", 0)), bool(lots[i]["frozen"]))

extends Marker3D
## AmmoDropZone / DropOrigin — «пустышка высоко над центром круга сброса». Единый механизм
## сброса ящиков боеприпасов на ЛЮБОЙ карте: префаб `scenes/ammo_crate/AmmoDropZone.tscn`
## ставится в пустые углы карты, роняет ящики патронов в случайную свободную точку своего круга.
##
## КАДЕНС — ОДИН НА КАРТУ, НЕ ПО ЗОНЕ. Если зон сброса на карте несколько, они НЕ роняют ящик
## каждая одновременно раз в интервал (получалось по ящику на каждой зоне разом). Вместо этого
## одна «зона-лидер» (первая по node-path среди группы `ammo_drop_zones`) держит единственный
## таймер и раз в `drop_interval_sec` роняет ящик на ОДНОЙ СЛУЧАЙНОЙ зоне карты. Остальные зоны
## своего таймера не заводят. Интервал берётся у лидера; `ammo_per_crate` / `max_pending_crates`
## / `min_crate_separation` остаются ПО-ЗОННЫМИ (используются в `_try_drop()` конкретной зоны).
## Единственная зона на карте — вырожденный случай: она же лидер, случайный выбор всегда падает
## на неё, поведение как раньше.
##
## Дерево префаба:
##   AmmoDropZone (Node3D)          — origin = центр круга на земле; ставится в угол карты
##   ├── DropArea (Node3D)          — spawn_zone.gd: жёлтый круг на земле + pick_spawn_position()
##   │                                 (равномерная по площади точка + raycast на реальную землю)
##   └── DropOrigin (Marker3D)      — ЭТОТ узел, локальный y ≈ 14 («высоко над центром»)
##
## Смысл механики: заставить расходовать боезапас тактичнее, добавить точку интереса на карте.

## Ссылка на сцену ящика через preload, НЕ class_name — headless `run_project` не подхватывает
## свежедобавленный class_name без пересканирования редактором (грабля проекта, см. CLAUDE.md).
const AmmoCrateScene := preload("res://scenes/ammo_crate/AmmoCrate.tscn")
## Красный ящик модификации (см. Tank_Prop_Hunt_Modifications.md). Тот же префаб-механизм зоны
## роняет и его — отдельным каденсом (см. _mortar_timer / _on_mortar_drop_tick).
const ModCrateScene := preload("res://scenes/mod_crate/ModCrate.tscn")

## Все `DropOrigin` на карте — в этой группе; по ней лидер собирает список зон карты.
const _GROUP := "ammo_drop_zones"

## Содержимое одного ящика (ТЗ — 3). Настраивается на каждой зоне отдельно.
@export var ammo_per_crate: int = 3
## Раз в столько секунд боя — сброс ОДНОГО ящика на случайной зоне карты. Действует значение
## зоны-лидера (см. шапку); на остальных зонах игнорируется.
@export var drop_interval_sec: float = 30.0
## Потолок одновременно НЕ подобранных ящиков ЭТОЙ зоны. 0 → GameConfig.ammo_crate_count.
@export var max_pending_crates: int = 0
## Новый ящик не роняется ближе этого (по XZ) к любому ещё не подобранному ящику ЭТОЙ зоны.
## Бокс ящика 0.6 — при 1.6 наложение исключено «никоим образом», как требует ТЗ.
@export var min_crate_separation: float = 1.6
## Скорость кинематического падения ящика, ед/с.
@export var fall_speed: float = 18.0

## КРАСНЫЙ ЯЩИК МОДИФИКАЦИИ (мортира) — отдельный каденс поверх патронного, тоже на зоне-лидере,
## НО роняет ОДНОВРЕМЕННО в КАЖДОЙ зоне карты (не одну на случайной, как патроны — см.
## _on_mortar_drop_tick). Только на картах режима TARGET_OBJECTIVE. 0 → GameConfig.mortar_drop_interval_sec.
@export var mortar_drop_interval_sec: float = 30.0
## Потолок одновременно НЕ подобранных красных ящиков ЭТОЙ зоны.
@export var max_pending_mortar_crates: int = 1

const _PLACEMENT_ATTEMPTS: int = 20
## environment(1) | tanks(2) | ammo_crates(32) | mod_crates(64) — не ронять в стену/дом/танк/
## чужой ящик (жёлтый или красный). Та же маска и приём (sphere query), что в
## match_manager._find_free_crate_position.
const _PROBE_MASK: int = 99
const _PROBE_RADIUS: float = 0.6

var _area: Node3D
var _timer: Timer  # только у зоны-лидера, у остальных null
var _mortar_timer: Timer  # только у лидера И только в режиме TARGET_OBJECTIVE, иначе null
var _pending: Array = []
var _pending_mortar: Array = []
var _inited: bool = false

## --- Координация атакующих ботов вокруг мортиры (читают tank_ai_controller.gd) ---------------
## true — мортиру в ЭТОЙ зоне уже забрал БОТ (не игрок) с момента последнего сброса; сбрасывается
## в false на каждом _on_mortar_drop_tick(). Пока true — атакующие боты в эту зону не едут
## («боты одной стороны в курсе, что тут уже подобрали»).
var mortar_bot_took: bool = false
## Счётчик состоявшихся сбросов мортиры — только у зоны-лидера, инкремент в _on_mortar_drop_tick().
## Бот через него отличает «сброса ещё не было» (0) от «прошло N секунд с последнего сброса».
var mortar_drops_done: int = 0

func _ready() -> void:
	add_to_group(_GROUP)
	_area = get_parent().get_node("DropArea")
	# Таймер НЕ заводим здесь: решение «я лидер / не лидер» требует, чтобы все зоны карты уже
	# были в группе, а это гарантировано только к первому _process (после всех _ready).

## Однократная инициализация лидера. Лениво (в _process): (1) группа `ammo_drop_zones`
## полностью заполнена только после _ready() всех зон; (2) узел "MatchManager" на аренах
## заводится из кода уже ПОСЛЕ _ready() этого узла (тот же приём, что в hud.gd).
func _process(_delta: float) -> void:
	if _inited:
		return
	_inited = true
	set_process(false)
	if not _is_leader():
		return  # не лидер — таймера нет, ждёт вызовов _try_drop() от лидера
	var mm: Node = get_tree().current_scene.get_node_or_null("MatchManager")
	if mm != null and mm.has_signal("round_ended"):
		mm.round_ended.connect(_on_round_ended)
	_timer = Timer.new()
	_timer.name = "DropTimer"
	_timer.one_shot = false
	_timer.wait_time = drop_interval_sec
	add_child(_timer)
	_timer.timeout.connect(_on_drop_tick)
	_timer.start()

	# Красные ящики модификации — только на картах режима TARGET_OBJECTIVE (ТЗ). MatchState.match_mode
	# уже проставлен корневым _ready() карты (тот идёт до этого ленивого init, как и MatchManager выше).
	if MatchState.match_mode == MatchState.Mode.TARGET_OBJECTIVE:
		var interval: float = mortar_drop_interval_sec if mortar_drop_interval_sec > 0.0 else GameConfig.mortar_drop_interval_sec
		_mortar_timer = Timer.new()
		_mortar_timer.name = "MortarDropTimer"
		_mortar_timer.one_shot = false
		_mortar_timer.wait_time = interval
		add_child(_mortar_timer)
		_mortar_timer.timeout.connect(_on_mortar_drop_tick)
		_mortar_timer.start()

## Лидер — зона с наименьшим node-path среди живых членов группы. Детерминированно, все зоны
## приходят к одному ответу. Зоны на этих картах статичны и не освобождаются, выбор однократный.
func _is_leader() -> bool:
	var zones: Array = _live_zones()
	zones.sort_custom(func(a, b): return String(a.get_path()) < String(b.get_path()))
	return not zones.is_empty() and zones[0] == self

func _live_zones() -> Array:
	var out: Array = []
	for z in get_tree().get_nodes_in_group(_GROUP):
		if is_instance_valid(z):
			out.append(z)
	return out

func _on_round_ended(_winner: String) -> void:
	if _timer != null:
		_timer.stop()  # бой кончился — новых сбросов не нужно
	if _mortar_timer != null:
		_mortar_timer.stop()

## Тик каденса (только у лидера): роняем ОДИН ящик на случайной зоне карты. Перебираем зоны в
## случайном порядке, сбрасываем на первой, где получилось (не на потолке, есть свободная
## точка); если ни на одной — тик впустую, следующая попытка через drop_interval_sec.
func _on_drop_tick() -> void:
	var zones: Array = _live_zones()
	zones.shuffle()
	for z in zones:
		if z._try_drop():
			return

func _cap() -> int:
	return max_pending_crates if max_pending_crates > 0 else GameConfig.ammo_crate_count

## Тик каденса красного ящика (только у лидера, только режим TARGET_OBJECTIVE): роняем ОДНОВРЕМЕННО
## по одному красному ящику в КАЖДОЙ живой зоне карты (ТЗ — «в двух зонах сброса одновременно»),
## не одну на случайной, как патроны. Зона на потолке / без свободной точки — просто пропускается.
## Перед сбросом: инкремент mortar_drops_done (у лидера) и снятие mortar_bot_took со ВСЕХ зон —
## свежий ящик = чистый лист для координации ботов (см. tank_ai_controller.gd).
func _on_mortar_drop_tick() -> void:
	mortar_drops_done += 1
	for z in _live_zones():
		z.mortar_bot_took = false
	for z in _live_zones():
		z._try_drop_mortar()

## Попытка сбросить КРАСНЫЙ ящик на ЭТОЙ зоне. Симметрично _try_drop(), но свой список
## _pending_mortar и свой потолок max_pending_mortar_crates.
func _try_drop_mortar() -> bool:
	_prune_pending()
	if _pending_mortar.size() >= max_pending_mortar_crates:
		return false
	var target: Variant = _pick_drop_point()
	if target == null:
		return false
	var crate: Node3D = ModCrateScene.instantiate()
	get_tree().current_scene.add_child(crate)
	crate.fall_to(target, global_position.y, fall_speed)
	_pending_mortar.append(crate)
	return true

## Попытка сбросить ящик на ЭТОЙ зоне. true — ящик заспавнен; false — зона на потолке или за
## _PLACEMENT_ATTEMPTS не нашлось свободного места.
func _try_drop() -> bool:
	_prune_pending()
	if _pending.size() >= _cap():
		return false
	var target: Variant = _pick_drop_point()
	if target == null:
		return false
	var crate: Node3D = AmmoCrateScene.instantiate()
	crate.ammo_amount = ammo_per_crate
	get_tree().current_scene.add_child(crate)
	crate.fall_to(target, global_position.y, fall_speed)
	_pending.append(crate)
	return true

## Случайная точка круга (DropArea.pick_spawn_position — равномерная по площади + raycast на
## реальную землю + fallback в центр зоны), отклонённая если она:
##   - ближе min_crate_separation (по XZ) к любому ещё не подобранному ящику зоны; ИЛИ
##   - перекрывает стену/дом/танк/чужой ящик (sphere query по _PROBE_MASK).
## Первая годная — возврат Vector3; ни одной за _PLACEMENT_ATTEMPTS — null (тик пропущен).
func _pick_drop_point() -> Variant:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var probe := SphereShape3D.new()
	probe.radius = _PROBE_RADIUS
	query.shape = probe
	query.collision_mask = _PROBE_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true
	for i in range(_PLACEMENT_ATTEMPTS):
		var p: Vector3 = _area.pick_spawn_position()
		if _too_close_to_pending(p):
			continue
		query.transform = Transform3D(Basis(), p + Vector3(0.0, 0.8, 0.0))
		if space.intersect_shape(query, 1).is_empty():
			return p
	return null

## Выкинуть из _pending уже подобранные (queue_free'нутые) ящики. Явный цикл, не Array.filter
## с типизированной лямбдой — та в Godot 4.7 падает с "Cannot convert argument 1 from Object to
## Object" на массиве Node-ов.
func _prune_pending() -> void:
	_pending = _alive_only(_pending)
	_pending_mortar = _alive_only(_pending_mortar)

func _alive_only(arr: Array) -> Array:
	var alive: Array = []
	for c in arr:
		if is_instance_valid(c):
			alive.append(c)
	return alive

## Проверяем ОБА списка (жёлтые + красные ящики этой зоны) — снаряды и мортира не должны падать
## друг на друга (sphere-проба в _pick_drop_point ловит только тела: Ground/танки, но не Area3D-ящики).
func _too_close_to_pending(p: Vector3) -> bool:
	for c in _pending + _pending_mortar:
		if not is_instance_valid(c):
			continue
		if Vector2(c.global_position.x - p.x, c.global_position.z - p.z).length() < min_crate_separation:
			return true
	return false

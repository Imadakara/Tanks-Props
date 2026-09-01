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

const _PLACEMENT_ATTEMPTS: int = 20
## environment(1) | tanks(2) | ammo_crates(32) — не ронять в стену/дом/танк/чужой ящик.
## Та же маска и тот же приём (sphere query), что были в match_manager._find_free_crate_position.
const _PROBE_MASK: int = 35
const _PROBE_RADIUS: float = 0.6

var _area: Node3D
var _timer: Timer  # только у зоны-лидера, у остальных null
var _pending: Array = []
var _inited: bool = false

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
	var alive: Array = []
	for c in _pending:
		if is_instance_valid(c):
			alive.append(c)
	_pending = alive

func _too_close_to_pending(p: Vector3) -> bool:
	for c in _pending:
		if not is_instance_valid(c):
			continue
		if Vector2(c.global_position.x - p.x, c.global_position.z - p.z).length() < min_crate_separation:
			return true
	return false

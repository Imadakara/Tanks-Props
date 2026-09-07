extends Node
## ContainerManager — правила режима CONTAINER_EXTRACTION (см. vault
## Tank_Prop_Hunt_Container_Extraction.md). Заводится ИЗ КОДА корнем карты
## (`map_scene.gd._setup_match_context()`, узел "ContainerManager") — тем же приёмом и в том же
## месте, что `ScoreManager`/`MatchManager`, и обязательно ПОСЛЕ `TeamSpawner.spawn_team()`:
## подписка на гибель танков требует уже полного состава в группе "tanks".
##
## Отвечает за три вещи и только за них:
## 1. Стартовая раскладка — по одному `Container.tscn` в каждую точку роли "ContainerSpawn"
##    (маркеры на `spawn_zone.gd` с `zone_role`, ищутся ГРУППОЙ, не по имени — тот же механизм, что
##    у вейпоинтов/зон сброса). Не больше `GameConfig.container_count`.
## 2. Доставка — танк, несущий контейнер, оказался в круге спавна СВОЕЙ команды: слот
##    освобождается, стороне засчитывается очко. Проверка поллингом в `_physics_process`, а не
##    сигналом: носителем может быть любой из немногих танков, а въезд в зону — это геометрия, а не
##    событие (Area3D на зоне спавна пришлось бы заводить отдельно и держать в синхроне с радиусом).
## 3. Выброс при гибели — носитель уничтожен: контейнер появляется на месте гибели и снова доступен
##    обеим сторонам (механика захвата флага). Слот при этом чистится СРАЗУ, не дожидаясь респавна
##    (`RespawnController.clear_slot()` идёт лишь через `respawn_cooldown_sec`), иначе контейнер
##    существовал бы одновременно на земле и в слоте трупа.
##
## Счёт хранится ПО СТОРОНЕ (attack/defense), как и серия раундов в `MatchState`: в этом режиме
## стороны — постоянные команды-цвета (Красные = 0 = attack, Синие = 1 = defense), смены сторон нет.

const ContainerScene := preload("res://scenes/container/Container.tscn")
## Тот же ресурс, что кладёт в слот `container_pickup.gd` — сравнение `current_mod == ContainerMod`
## отличает носителя контейнера от носителя мортиры без проверок по `id`-строке.
const ContainerMod := preload("res://scenes/modifications/container.tres")

## Роль маркеров-точек стартовой раскладки (`SpawnZone.zone_role` на инстансах в .tscn карты).
const SPAWN_ROLE := "ContainerSpawn"

## Откуда и как далеко вниз ищем реальную поверхность под точкой гибели носителя.
const _GROUND_PROBE_UP: float = 2.0
const _GROUND_PROBE_DOWN: float = 60.0

signal container_delivered(team: int)
signal all_delivered()

var attack_delivered: int = 0
var defense_delivered: int = 0
## Сколько контейнеров вообще введено в игру этим матчем — от него считается «осталось» в HUD и
## условие досрочного конца раунда. Меньше GameConfig.container_count, если точек на карте меньше.
var total_containers: int = 0

var _attack_zone: Node3D
var _defense_zone: Node3D
var _spawn_markers: Array = []
var _halted: bool = false

## Вызывается корнем карты сразу после add_child() — явным вызовом из оркестратора, не из
## _ready() (тот же порядок, что у ScoreManager.begin_match()/MatchManager.setup()).
func setup() -> void:
	var scene := get_tree().current_scene
	_attack_zone = scene.find_child("AttackSpawnZone", true, false) as Node3D
	_defense_zone = scene.find_child("DefenseSpawnZone", true, false) as Node3D
	_spawn_markers = get_tree().get_nodes_in_group(SPAWN_ROLE)
	# Порядок по node-path — детерминированный: при container_count меньше числа маркеров карта
	# всегда получает ОДИН И ТОТ ЖЕ поднабор точек, а не случайный от запуска к запуску.
	_spawn_markers.sort_custom(func(a, b): return String(a.get_path()) < String(b.get_path()))
	_spawn_initial_containers()

## Раунд закончился (`map_scene.gd._on_round_ended_teardown`) — прекращаем всё. Важно ИМЕННО до
## того, как та же функция вызовет force_destroy() на всех танках: иначе «заморозка поля» на экран
## результата высыпала бы контейнеры из слотов погибших носителей.
func halt() -> void:
	_halted = true
	set_physics_process(false)

func remaining() -> int:
	return total_containers - attack_delivered - defense_delivered

func _spawn_initial_containers() -> void:
	for marker in _spawn_markers:
		if total_containers >= GameConfig.container_count:
			return
		if not is_instance_valid(marker):
			continue
		# pick_spawn_position() уже кастует луч вниз и возвращает точку на РЕАЛЬНОЙ поверхности
		# (на многоуровневой карте маркер может стоять над столешницей/полкой, не над полом).
		_spawn_container_at(marker.pick_spawn_position())
		total_containers += 1
	if total_containers == 0:
		push_warning("ContainerManager: на карте нет ни одной точки роли '%s' — режим экстракшена без контейнеров" % SPAWN_ROLE)

## Только материализует контейнер в точке. Счётчик total_containers НЕ трогает намеренно: он
## считает, сколько контейнеров ВВЕДЕНО в игру за матч, а выброшенный погибшим носителем — тот же
## самый контейнер, а не новый (иначе «осталось» в HUD и условие досрочного конца раунда росли бы
## с каждой смертью носителя).
func _spawn_container_at(ground_point: Vector3) -> void:
	var container: Node3D = ContainerScene.instantiate()
	get_tree().current_scene.add_child(container)
	container.place_on_ground(ground_point)

func _physics_process(_delta: float) -> void:
	if _halted:
		return
	for tank in get_tree().get_nodes_in_group("tanks"):
		if not is_instance_valid(tank):
			continue
		# Подписка здесь, а не одним проходом в setup(): дебаг-кнопки HUD добавляют ботов уже по
		# ходу раунда (TeamSpawner.spawn_one_bot), и их гибель тоже должна ронять контейнер.
		# Callable с bind сравнивается по значению — is_connected() не даёт задвоить подписку.
		_watch_tank(tank)
		var health: Node = tank.get_node_or_null("HealthComponent")
		if health == null or not health.is_alive:
			continue
		var slot: Node = tank.get_node_or_null("ModificationController")
		if slot == null or slot.current_mod != ContainerMod:
			continue
		var zone: Node3D = _attack_zone if int(tank.team) == 0 else _defense_zone
		if zone == null or not _inside_base(tank, zone):
			continue
		slot.clear_slot()
		_register_delivery(int(tank.team))

func _watch_tank(tank: Node) -> void:
	var health: Node = tank.get_node_or_null("HealthComponent")
	if health == null:
		return
	var handler := _on_tank_destroyed.bind(tank)
	if not health.destroyed.is_connected(handler):
		health.destroyed.connect(handler)

## Круг зоны спавна проверяется по XZ (радиус — тот же `SpawnZone.radius`, что использует сам спавн)
## ПЛЮС по высоте: на многоуровневой карте прямо под базой на столе есть пол, и без ограничения по Y
## контейнер засчитывался бы этажом ниже базы, не доехав до неё.
func _inside_base(tank: Node3D, zone: Node3D) -> bool:
	var radius: float = float(zone.get("radius"))
	var flat: float = Vector2(tank.global_position.x - zone.global_position.x,
			tank.global_position.z - zone.global_position.z).length()
	if flat > radius:
		return false
	return absf(tank.global_position.y - zone.global_position.y) <= GameConfig.container_delivery_height_tolerance

func _register_delivery(team: int) -> void:
	if team == 0:
		attack_delivered += 1
	else:
		defense_delivered += 1
	container_delivered.emit(team)
	if remaining() <= 0:
		_halted = true
		set_physics_process(false)
		all_delivered.emit()  # раунд решается досрочно, см. match_manager.gd

## killer приходит из сигнала, tank — из bind() при подписке (см. _watch_tank).
func _on_tank_destroyed(_killer: Node, tank: Node) -> void:
	if _halted or not is_instance_valid(tank):
		return
	var slot: Node = tank.get_node_or_null("ModificationController")
	if slot == null or slot.current_mod != ContainerMod:
		return
	slot.clear_slot()
	_place_dropped_container(tank.global_position)

## Контейнер погибшего носителя. Ищем поверхность лучом вниз — танк мог погибнуть в воздухе (падение
## между уровнями) или на столешнице; класть контейнер на «высоту трупа» нельзя, он повис бы в
## воздухе или утонул в геометрии. Поверхности под точкой гибели нет вовсе (танк провалился ниже
## карты — force_destroy из respawn_controller.gd) — возвращаем контейнер на СВОБОДНУЮ стартовую
## точку, иначе он просто выпал бы из игры и раунд стало бы невозможно закрыть досрочно.
func _place_dropped_container(death_pos: Vector3) -> void:
	var space: PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
	var origin: Vector3 = death_pos + Vector3(0.0, _GROUND_PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * _GROUND_PROBE_DOWN)
	query.collision_mask = 1  # environment — та же маска, что у всех геометрических проверок проекта
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		_spawn_container_at(hit["position"])
		return
	if _spawn_markers.is_empty():
		_spawn_container_at(death_pos)  # вырожденный случай: некуда вернуть, кладём как есть
		return
	var marker: Node3D = _spawn_markers[randi() % _spawn_markers.size()]
	_spawn_container_at(marker.pick_spawn_position())

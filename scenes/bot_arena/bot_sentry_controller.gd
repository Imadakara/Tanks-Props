extends Node
## BotSentryController — тестовый ИИ для песочницы "Bot Arena" (scenes/bot_arena/BotArena.tscn).
## Отдельно от продакшен-ИИ scenes/tank/tank_ai_controller.gd (ТЗ §9, патруль/маскировка) —
## тот не трогаем. Здесь обкатывается конечный автомат чисто боевого поведения: бот НЕ
## двигается (задача №1 — только обзор/наводка/стрельба), но крутит башню влево-вправо,
## имитируя вращение камеры-головы.
##
## Сектор обзора fov_min_deg..fov_max_deg (от направления корпуса при спавне) — ОДНО общее
## понятие для двух вещей: границы качания башни при сканировании И зона, в которой цель
## вообще может быть замечена/удержана. Специально широкий (шире, чем было — игрок от 3-го
## лица видит куда больше, чем строго вперёд по корпусу, вот и бот теперь тоже) — раньше
## обзор был двойной: широкие границы качания + узкий 50°-конус вокруг МГНОВЕННОГО направления
## башни поверх них (луч должен был буквально попасть на цель) — вот этот узкий конус убран,
## сектор один на обе задачи.
##
## SEARCH — сканирование сектора туда-сюда, имитируя вращение камеры в поиске цели. Как
## только цель попадает в сектор (по азимуту от корпуса, не от текущего угла башни — сектор
## статичен) и есть прямая видимость (raycast, стенка её перекрывает) — переход в TRACK.
##
## TRACK (слежение) — башня доворачивается точно на цель и дальше каждый кадр пересчитывается
## по её ЖИВОЙ позиции, то есть движется вслед за движением цели, пока та остаётся в секторе
## обзора (дальность/азимут/видимость проверяются каждый think-тик). Стрельба — как только
## наводка и дальность позволяют, огонь по готовности (перезарядка/боекомплект — как обычно).
## Если цель покидает сектор/дальность или пропадает видимость — назад в SEARCH, сканирование
## продолжается с текущего угла (не сбрасывается на исходный).
##
## Реакция на обстрел: HealthComponent.damaged() (см. health_component.gd) теперь несёт killer —
## при попадании бот разворачивает обзор (башню) в сторону, откуда прилетело, независимо от
## того, видна ли цель прямо сейчас; если после разворота она уже в секторе — сразу TRACK.

enum State { SEARCH, TRACK }

@export var vision_range: float = 18.0
@export var fire_range: float = 14.0
@export var fire_aim_tolerance_deg: float = 5.0
@export var scan_speed_deg_per_sec: float = 25.0
@export var fov_min_deg: float = -120.0  # относительно исходного направления корпуса при спавне
@export var fov_max_deg: float = 120.0   # 240° суммарно — шире, чем раньше (было 200 качание / 50 обнаружение)
@export var think_interval_sec: float = 0.1  # реже физ.кадра — проверка "вижу/не вижу", не сама наводка

@onready var _body: CharacterBody3D = get_parent()
@onready var _movement: Node = get_parent().get_node("TankMovement")
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _barrel: Node3D = get_parent().get_node("Turret/Barrel")
@onready var _weapon: Node = get_parent().get_node("WeaponController")
@onready var _disguise: Node = get_parent().get_node("DisguiseController")
@onready var _health: Node = get_parent().get_node("HealthComponent")

var state: State = State.SEARCH
var _look_yaw: float = 0.0  # мировой угол обзора — куда сейчас "смотрит" бот, ведёт башню
var _scan_dir: float = 1.0  # +1 сканирует вправо, -1 влево
var _current_target: Node = null
var _think_timer: float = 0.0

func _ready() -> void:
	# Тот же трюк, что у TankAIController._initialize() — без этого бот читал бы Input
	# игрока напрямую (is_player_controlled по умолчанию true у всех этих компонентов).
	_movement.is_player_controlled = false
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	_weapon.is_player_controlled = false
	_disguise.is_player_controlled = false
	_look_yaw = _body.rotation.y
	_health.damaged.connect(_on_damaged)

	# CameraRig этого танка на статичной сцене нельзя выключить оверрайдом в .tscn (нет
	# редактируемых детей у инстанса) — гасим камеру здесь. BotSentryController стоит
	# ПОСЛЕДНИМ сиблингом среди детей Tank-инстанса, поэтому его _ready() гарантированно
	# отрабатывает уже ПОСЛЕ CameraRig._ready() (которая успела выставить Camera3D.current=true
	# по умолчанию is_active=true) — здесь это откатывается ДО первого кадра рендера, игрок
	# не видит вспышку смены камеры (тот же класс бага, что описан в team_spawner.gd).
	var camera_rig: Node3D = _body.get_node("CameraRig")
	camera_rig.is_active = false
	var camera: Camera3D = camera_rig.get_node("Camera3D")
	camera.current = false

func _physics_process(delta: float) -> void:
	_movement.ai_move_input = 0.0
	_movement.ai_turn_input = 0.0

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = think_interval_sec
		_think()

	if state == State.TRACK and _current_target != null and is_instance_valid(_current_target):
		_aim_and_fire(_current_target)
	else:
		_scan(delta)
		_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)

func _think() -> void:
	if state == State.TRACK:
		if _current_target == null or not is_instance_valid(_current_target) or not _can_see(_current_target):
			_enter_search()
		return
	var target := _scan_for_target()
	if target != null:
		_enter_track(target)

## Сканирование сектора fov_min_deg..fov_max_deg (от направления корпуса на спавне) —
## имитация вращения камеры туда-сюда в поиске цели.
func _scan(delta: float) -> void:
	var base_yaw: float = _body.rotation.y
	var local_deg: float = rad_to_deg(wrapf(_look_yaw - base_yaw, -PI, PI))
	local_deg += _scan_dir * scan_speed_deg_per_sec * delta
	if local_deg >= fov_max_deg:
		local_deg = fov_max_deg
		_scan_dir = -1.0
	elif local_deg <= fov_min_deg:
		local_deg = fov_min_deg
		_scan_dir = 1.0
	_look_yaw = base_yaw + deg_to_rad(local_deg)

func _scan_for_target() -> Node:
	for other in get_tree().get_nodes_in_group("tanks"):
		if other == _body or not is_instance_valid(other):
			continue
		if other.team == _body.team:
			continue
		if _can_see(other):
			return other
	return null

## Сектор проверяется от направления КОРПУСА (fov_min_deg..fov_max_deg), а не от текущего
## угла башни — цель считается видимой, если она вообще в пределах общего сектора обзора,
## независимо от того, куда именно сейчас смотрит башня во время сканирования. Так и
## сканирование, и слежение (TRACK) пользуются одной и той же зоной.
func _can_see(target: Node3D) -> bool:
	var to_target: Vector3 = target.global_position - _turret.global_position
	var dist: float = to_target.length()
	if dist > vision_range or dist < 0.01:
		return false
	var world_yaw: float = _yaw_to_world_point(_turret.global_position, target.global_position)
	var local_bearing_deg: float = rad_to_deg(wrapf(world_yaw - _body.rotation.y, -PI, PI))
	if local_bearing_deg < fov_min_deg or local_bearing_deg > fov_max_deg:
		return false
	var space_state := _body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		_turret.global_position,
		target.global_position + Vector3.UP * 0.3
	)
	query.exclude = [_body]
	query.collision_mask = 1 | 2  # environment (стенка) + tanks
	var result: Dictionary = space_state.intersect_ray(query)
	return result.is_empty() or result.get("collider") == target

func _enter_track(target: Node) -> void:
	state = State.TRACK
	_current_target = target

func _enter_search() -> void:
	state = State.SEARCH
	_current_target = null
	# _look_yaw не сбрасывается — сканирование в _scan() продолжится с того же угла.

## Наводка пересчитывается КАЖДЫЙ кадр по живой позиции цели — башня физически движется вслед
## за её перемещением (не за фиксированной точкой), пока цель остаётся в секторе (проверяет
## _think(), см. выше).
func _aim_and_fire(target: Node3D) -> void:
	_look_yaw = _yaw_to_world_point(_turret.global_position, target.global_position)
	_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)

	var dist: float = _body.global_position.distance_to(target.global_position)
	var aim_diff_deg: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	if dist <= fire_range and aim_diff_deg <= fire_aim_tolerance_deg:
		_weapon.try_fire()

func _yaw_to_world_point(from: Vector3, to_point: Vector3) -> float:
	var d: Vector3 = to_point - from
	return atan2(-d.x, -d.z)

## Реакция на попадание (ТЗ этой сессии) — разворот обзора/башни туда, откуда стреляли,
## даже если цель сейчас не видна. Если после разворота она уже в секторе — сразу в TRACK.
func _on_damaged(_current_hits: int, _max_hits: int, killer: Node) -> void:
	if killer == null or not is_instance_valid(killer) or killer == _body:
		return
	_look_yaw = _yaw_to_world_point(_turret.global_position, killer.global_position)
	if state == State.SEARCH and _can_see(killer):
		_enter_track(killer)

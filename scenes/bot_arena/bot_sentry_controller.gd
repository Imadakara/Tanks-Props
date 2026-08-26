extends Node
## BotSentryController — тестовый ИИ для песочницы "Bot Arena" (scenes/bot_arena/BotArena.tscn).
## Отдельно от продакшен-ИИ scenes/tank/tank_ai_controller.gd (ТЗ §9, патруль/маскировка) —
## тот не трогаем. Здесь обкатывается конечный автомат чисто боевого поведения: бот НЕ
## двигается (задача №1 — только обзор/наводка/стрельба), но крутит башню влево-вправо,
## имитируя вращение камеры-головы.
##
## Сектор обзора fov_min_deg..fov_max_deg (от направления корпуса при спавне) — ОДНО общее
## понятие для двух вещей: границы качания башни при сканировании И зона, в которой цель
## вообще может быть замечена/удержана. Было ±120°=240° (бот "видел" почти периферийным
## зрением в любую секунду, даже глядя совсем в другую сторону) — сузили до ±55°=110°, но
## тогда цель ровно сбоку (~90° от корпуса, "параллельно") выпадала из сектора совсем.
## ±100°=200° — компромисс: с запасом покрывает боковую цель, но не полный периметр.
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
##
## Уровни сложности (difficulty) — все числовые @export ниже это тюнинг MEDIUM (тот самый
## "текущий бот"), EASY/HARD — пресеты в _apply_difficulty_preset(), применяются поверх этих
## значений при _ready(). Чтобы поменять баланс MEDIUM — править сами @export; чтобы
## поменять EASY/HARD — саму таблицу _DIFFICULTY_PRESETS.

enum State { SEARCH, TRACK }
enum Difficulty { EASY, MEDIUM, HARD }

@export var difficulty: Difficulty = Difficulty.MEDIUM

@export var vision_range: float = 18.0
@export var fire_range: float = 14.0
@export var fire_aim_tolerance_deg: float = 5.0
@export var scan_speed_deg_per_sec: float = 25.0
@export var fov_min_deg: float = -100.0  # относительно исходного направления корпуса при спавне
@export var fov_max_deg: float = 100.0   # 200° суммарно
@export var think_interval_sec: float = 0.1  # реже физ.кадра — проверка "вижу/не вижу", не сама наводка
@export var turret_turn_speed: float = 1.0  # рад/сек — применяется на Turret при _ready() (см. turret_controller.gd)

## Дебажная отрисовка сектора обзора (ImmediateMesh, полупрозрачный веер + текущий "взгляд")
## поверх земли под ботом — граница fov_min_deg..fov_max_deg на радиус vision_range, зелёный
## в SEARCH, красный в TRACK, жёлтая линия — куда сейчас реально смотрит башня/_look_yaw.
@export var show_fov_debug: bool = true

## EASY/HARD — множители/значения поверх полей выше (MEDIUM = как объявлены, без изменений).
## Разница по трём осям: осведомлённость (сектор/дальность/скорость сканирования), реакция
## (think_interval — как часто бот вообще проверяет "вижу/не вижу"), меткость (допуск наводки
## + скорость доворота башни).
const _DIFFICULTY_PRESETS := {
	Difficulty.EASY: {
		"vision_range": 12.0,
		"fire_range": 9.0,
		"fire_aim_tolerance_deg": 9.0,
		"scan_speed_deg_per_sec": 15.0,
		"fov_min_deg": -70.0,
		"fov_max_deg": 70.0,
		"think_interval_sec": 0.25,
		"turret_turn_speed": 0.8,
	},
	Difficulty.HARD: {
		"vision_range": 24.0,
		"fire_range": 18.0,
		"fire_aim_tolerance_deg": 3.0,
		"scan_speed_deg_per_sec": 35.0,
		"fov_min_deg": -130.0,
		"fov_max_deg": 130.0,
		"think_interval_sec": 0.05,
		"turret_turn_speed": 2.2,
	},
}

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
var _fov_debug_mesh: MeshInstance3D

func _ready() -> void:
	_apply_difficulty_preset()

	# Тот же трюк, что у TankAIController._initialize() — без этого бот читал бы Input
	# игрока напрямую (is_player_controlled по умолчанию true у всех этих компонентов).
	_movement.is_player_controlled = false
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	_weapon.is_player_controlled = false
	_disguise.is_player_controlled = false
	_turret.turn_speed = turret_turn_speed
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

	if show_fov_debug:
		_setup_fov_debug_draw()

## MEDIUM ничего не меняет (числа выше УЖЕ тюнинг medium). EASY/HARD перезаписывают поля
## значениями из _DIFFICULTY_PRESETS — правки конкретных @export-полей в инспекторе этого
## инстанса для EASY/HARD смысла не имеют, они всё равно будут перетёрты отсюда при старте.
func _apply_difficulty_preset() -> void:
	if not _DIFFICULTY_PRESETS.has(difficulty):
		return
	var preset: Dictionary = _DIFFICULTY_PRESETS[difficulty]
	vision_range = preset["vision_range"]
	fire_range = preset["fire_range"]
	fire_aim_tolerance_deg = preset["fire_aim_tolerance_deg"]
	scan_speed_deg_per_sec = preset["scan_speed_deg_per_sec"]
	fov_min_deg = preset["fov_min_deg"]
	fov_max_deg = preset["fov_max_deg"]
	think_interval_sec = preset["think_interval_sec"]
	turret_turn_speed = preset["turret_turn_speed"]

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

	if show_fov_debug:
		_update_fov_debug_draw()

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

## Создаётся один раз в _ready(): MeshInstance3D с ImmediateMesh — ребилдится каждый физ.кадр
## в _update_fov_debug_draw(). Ребёнок именно _body (CharacterBody3D), не self (self — plain
## Node, у Node3D-детей под ним не было бы осмысленной мировой трансформации) — так веер сам
## наследует позицию/поворот корпуса, координаты внутри считаем в ЛОКАЛЬНОМ пространстве бота.
func _setup_fov_debug_draw() -> void:
	_fov_debug_mesh = MeshInstance3D.new()
	_fov_debug_mesh.name = "FovDebugMesh"
	_fov_debug_mesh.mesh = ImmediateMesh.new()
	_fov_debug_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	_fov_debug_mesh.material_override = mat
	# call_deferred: _ready() всей ветки Tank-инстанса (в т.ч. _body) ещё выполняется в момент,
	# когда доходит очередь до этого (последнего) сиблинга — add_child() в это окно падает
	# с "Parent node is busy setting up children" (тот же класс проблемы, что и в main.gd).
	_body.add_child.call_deferred(_fov_debug_mesh)

## Точка на дуге сектора в ЛОКАЛЬНЫХ координатах бота: local_deg=0 — прямо вперёд по корпусу
## (локальный -Z, та же система отсчёта, что и fov_min_deg/fov_max_deg/_can_see()).
func _local_fov_point(local_deg: float, radius: float, height: float) -> Vector3:
	var rad: float = deg_to_rad(local_deg)
	return Vector3(-sin(rad) * radius, height, -cos(rad) * radius)

func _update_fov_debug_draw() -> void:
	var mesh: ImmediateMesh = _fov_debug_mesh.mesh
	mesh.clear_surfaces()

	const SEGMENTS := 24
	const HEIGHT := 0.55  # чуть выше корпуса — видно поверх HullMesh, не тонет в земле
	var radius: float = vision_range
	var fill_color: Color = Color(1.0, 0.15, 0.1, 0.22) if state == State.TRACK else Color(0.15, 0.9, 0.2, 0.16)
	var center := Vector3(0.0, HEIGHT, 0.0)

	# Заливка веера — треугольниками (у ImmediateMesh нет отдельного TRIANGLE_FAN).
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	mesh.surface_set_color(fill_color)
	var prev_point: Vector3 = _local_fov_point(fov_min_deg, radius, HEIGHT)
	for i in range(1, SEGMENTS + 1):
		var t: float = float(i) / float(SEGMENTS)
		var deg: float = lerp(fov_min_deg, fov_max_deg, t)
		var cur_point: Vector3 = _local_fov_point(deg, radius, HEIGHT)
		mesh.surface_add_vertex(center)
		mesh.surface_add_vertex(prev_point)
		mesh.surface_add_vertex(cur_point)
		prev_point = cur_point
	mesh.surface_end()

	# Контур сектора (боковые радиусы + дуга) — ярче заливки, чтобы границы читались чётко.
	var outline_color := Color(fill_color.r, fill_color.g, fill_color.b, 0.9)
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(outline_color)
	mesh.surface_add_vertex(center)
	for i in range(SEGMENTS + 1):
		var t2: float = float(i) / float(SEGMENTS)
		var deg2: float = lerp(fov_min_deg, fov_max_deg, t2)
		mesh.surface_add_vertex(_local_fov_point(deg2, radius, HEIGHT))
	mesh.surface_add_vertex(center)
	mesh.surface_end()

	# Текущее направление обзора/башни (_look_yaw) — куда бот реально смотрит прямо сейчас.
	var local_look_deg: float = rad_to_deg(wrapf(_look_yaw - _body.rotation.y, -PI, PI))
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 1.0, 0.2, 0.95))
	mesh.surface_add_vertex(center)
	mesh.surface_add_vertex(_local_fov_point(local_look_deg, radius, HEIGHT))
	mesh.surface_end()

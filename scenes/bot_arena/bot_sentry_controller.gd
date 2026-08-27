extends Node
## BotSentryController — тестовый ИИ для песочницы "Bot Arena" (scenes/bot_arena/BotArena.tscn).
## Отдельно от продакшен-ИИ scenes/tank/tank_ai_controller.gd (ТЗ §9, патруль/маскировка) —
## тот не трогаем. Бот НЕ двигается (задача №1 — только обзор/наводка/стрельба).
##
## Модель обзора — по аналогии с игроком: у игрока камера смотрит в конкретную сторону, и то,
## что вне её кадра, он просто не видит, пока не развернёт камеру (см. camera_rig.gd —
## is_player_controlled=true у TurretController берёт target_yaw НАПРЯМУЮ из направления камеры).
## У бота роль "камеры" играет _look_yaw — им управляет ТОЛЬКО этот скрипт (никогда не сам
## игрок). Триггер обнаружения цели — попадание в ТЕКУЩИЙ конус (look_cone_deg, центр —
## _look_yaw, радиус — vision_range), а не в какую-то фиксированную зону вокруг корпуса.
## Башня — не мозг, а просто следует за _look_yaw (target_yaw = f(_look_yaw), физический
## доворот делает TurretController.rotate_toward, см. turret_controller.gd) — ровно так же,
## как у игрока башня трогается вслед за камерой с задержкой, а не сама решает, куда смотреть.
##
## SEARCH — блуждание "камеры" (_wander()), имитация того, как игрок ворочает обзор осматриваясь:
## выбирает случайный угол в пределах wander_min_deg..wander_max_deg (сколько бот вообще может
## увести взгляд от направления корпуса — практический предел разворота, НЕ сам конус обзора),
## доворачивает туда (тем же rotate_toward, что и башня — довод получается "тот же язык
## движения", что и наводка), держит там wander_hold_min_sec..wander_hold_max_sec (по умолчанию
## 1-2 сек — "то вперёд, то назад, то влево, то вправо"), затем — новый случайный угол, по
## кругу в хаотичном порядке. Пока смотрит куда-то — конус обзора (look_cone_deg вокруг
## _look_yaw) следует за этим направлением; попала туда цель, дальность и видимость (raycast,
## стенка перекрывает) сошлись — переход в TRACK.
##
## TRACK (слежение) — _look_yaw и башня каждый кадр пересчитываются на ЖИВУЮ позицию цели
## (движется вслед за её перемещением), огонь по готовности прицела/дальности/боекомплекта.
## Пропала видимость/дальность — назад в SEARCH; блуждание возобновляется с текущего угла
## (не сбрасывается на исходный).
##
## Реакция на обстрел: HealthComponent.damaged() (см. health_component.gd) несёт killer — при
## попадании бот разворачивает "камеру" (значит и башню) в сторону выстрела; видна оттуда —
## сразу TRACK.
##
## Уровни сложности (difficulty) — все числовые @export ниже это тюнинг MEDIUM (тот самый
## "текущий бот"), EASY/HARD — пресеты в _apply_difficulty_preset(), применяются поверх этих
## значений при _ready(). Чтобы поменять баланс MEDIUM — править сами @export; чтобы
## поменять EASY/HARD — саму таблицу _DIFFICULTY_PRESETS.

enum State { SEARCH, TRACK }
enum Difficulty { EASY, MEDIUM, HARD }

const _WANDER_ARRIVE_TOLERANCE_DEG := 3.0  # когда считать, что "камера" дошла до выбранного угла

@export var difficulty: Difficulty = Difficulty.MEDIUM

## Радиус и полуширина ТЕКУЩЕГО (движущегося) конуса обзора — реальный триггер обнаружения.
## Раньше это была большая статичная зона вокруг корпуса — теперь узкий "прожектор", который
## реально нужно навести на цель взглядом, как у игрока с камерой.
@export var vision_range: float = 10.0
@export var look_cone_deg: float = 55.0  # полный угол конуса вокруг _look_yaw
@export var fire_range: float = 8.0
@export var fire_aim_tolerance_deg: float = 5.0

## Практические границы, куда вообще может увести взгляд блуждание (относительно направления
## корпуса при спавне) — НЕ сам конус обзора, а диапазон возможных направлений _look_yaw.
@export var wander_min_deg: float = -75.0
@export var wander_max_deg: float = 75.0
@export var wander_hold_min_sec: float = 1.0  # задержка на выбранном угле после доворота
@export var wander_hold_max_sec: float = 2.0

@export var think_interval_sec: float = 0.1  # реже физ.кадра — проверка "вижу/не вижу", не сама наводка
@export var turret_turn_speed: float = 1.0  # рад/сек — применяется на Turret при _ready() (см. turret_controller.gd), также скорость блуждания обзора

## Дебажная отрисовка (ImmediateMesh) поверх земли под ботом: зелёный/красный веер — ТЕКУЩИЙ
## конус обзора (look_cone_deg вокруг _look_yaw, радиус vision_range) — зелёный в SEARCH,
## красный в TRACK, движется вместе с _look_yaw. Жёлтая линия — куда РЕАЛЬНО сейчас повёрнута
## башня (может немного отставать от конуса — та же инерция, что и у башни игрока за камерой).
@export var show_fov_debug: bool = true

## EASY/HARD — множители/значения поверх полей выше (MEDIUM = как объявлены, без изменений).
## Разница по четырём осям: осведомлённость (радиус/угол конуса, границы блуждания), реакция
## (think_interval), меткость (допуск наводки + скорость доворота — та же скорость и для
## блуждания), "непоседливость" взгляда (wander_hold — у HARD короче, дольше не засиживается).
const _DIFFICULTY_PRESETS := {
	Difficulty.EASY: {
		"vision_range": 6.0,
		"look_cone_deg": 40.0,
		"fire_range": 5.0,
		"fire_aim_tolerance_deg": 9.0,
		"wander_min_deg": -50.0,
		"wander_max_deg": 50.0,
		"wander_hold_min_sec": 2.0,
		"wander_hold_max_sec": 3.5,
		"think_interval_sec": 0.25,
		"turret_turn_speed": 0.8,
	},
	Difficulty.HARD: {
		"vision_range": 14.0,
		"look_cone_deg": 70.0,
		"fire_range": 11.0,
		"fire_aim_tolerance_deg": 3.0,
		"wander_min_deg": -100.0,
		"wander_max_deg": 100.0,
		"wander_hold_min_sec": 0.5,
		"wander_hold_max_sec": 1.2,
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
var _look_yaw: float = 0.0  # мировой угол "камеры" бота — центр конуса обзора, ведёт башню
var _current_target: Node = null
var _think_timer: float = 0.0
var _fov_debug_mesh: MeshInstance3D

## Состояние блуждания взгляда в SEARCH (см. _wander()): пока не "дошли" до выбранного угла —
## просто ждём (сам доворот делает TurretController, target_yaw уже выставлен); дошли — считаем
## задержку _wander_hold_timer, по истечении выбираем новый случайный угол.
var _wander_holding: bool = false
var _wander_hold_timer: float = 0.0

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
	look_cone_deg = preset["look_cone_deg"]
	fire_range = preset["fire_range"]
	fire_aim_tolerance_deg = preset["fire_aim_tolerance_deg"]
	wander_min_deg = preset["wander_min_deg"]
	wander_max_deg = preset["wander_max_deg"]
	wander_hold_min_sec = preset["wander_hold_min_sec"]
	wander_hold_max_sec = preset["wander_hold_max_sec"]
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
		_wander(delta)
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

## Блуждание "камеры" в SEARCH — имитация того, как игрок крутит камеру осматриваясь: то
## вперёд, то в сторону, с паузами, а не мерное качание туда-сюда. Пока не дошли до _look_yaw —
## просто ждём (доворот делает TurretController); дошли — держим wander_hold_min_sec..
## wander_hold_max_sec, затем выбираем новый случайный угол в пределах wander_min_deg..
## wander_max_deg (границы допустимого разворота взгляда, не сам конус обзора — см. _can_see()).
func _wander(delta: float) -> void:
	if _wander_holding:
		_wander_hold_timer -= delta
		if _wander_hold_timer <= 0.0:
			_pick_new_wander_target()
		return
	var aim_diff_deg: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	if aim_diff_deg <= _WANDER_ARRIVE_TOLERANCE_DEG:
		_wander_holding = true
		_wander_hold_timer = randf_range(wander_hold_min_sec, wander_hold_max_sec)

func _pick_new_wander_target() -> void:
	var target_local_deg: float = randf_range(wander_min_deg, wander_max_deg)
	_look_yaw = _body.rotation.y + deg_to_rad(target_local_deg)
	_wander_holding = false

func _scan_for_target() -> Node:
	for other in get_tree().get_nodes_in_group("tanks"):
		if other == _body or not is_instance_valid(other):
			continue
		if other.team == _body.team:
			continue
		if _can_see(other):
			return other
	return null

## Триггер обнаружения — попадание в ТЕКУЩИЙ конус обзора: полуширина look_cone_deg/2 ВОКРУГ
## _look_yaw (куда сейчас направлена "камера" бота), а не вокруг направления корпуса — конус
## движется вместе с блужданием взгляда/слежением за целью, ровно как обзор игрока следует за
## его камерой. Цель вне текущего кадра "камеры" не видна, даже если формально близко и без
## препятствий — в этом и суть модели (см. заголовок файла).
func _can_see(target: Node3D) -> bool:
	var to_target: Vector3 = target.global_position - _turret.global_position
	var dist: float = to_target.length()
	if dist > vision_range or dist < 0.01:
		return false
	var world_yaw: float = _yaw_to_world_point(_turret.global_position, target.global_position)
	var angle_diff_deg: float = rad_to_deg(absf(wrapf(world_yaw - _look_yaw, -PI, PI)))
	if angle_diff_deg > look_cone_deg * 0.5:
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
	# Ни _look_yaw, ни _wander_holding не сбрасываются — блуждание взгляда продолжится с
	# текущего направления (не с исходного).

## Наводка пересчитывается КАЖДЫЙ кадр по живой позиции цели — "камера"/башня физически
## движутся вслед за её перемещением (не за фиксированной точкой), пока цель остаётся видна
## (проверяет _think(), см. выше).
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

## Реакция на попадание (ТЗ этой сессии) — разворот "камеры" (значит и башни) туда, откуда
## стреляли, даже если цель сейчас не видна. Если после разворота она уже в конусе — сразу TRACK.
func _on_damaged(_current_hits: int, _max_hits: int, killer: Node) -> void:
	if killer == null or not is_instance_valid(killer) or killer == _body:
		return
	_look_yaw = _yaw_to_world_point(_turret.global_position, killer.global_position)
	_wander_holding = false
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

## Точка в ЛОКАЛЬНЫХ координатах бота: local_deg=0 — прямо вперёд по корпусу (локальный -Z,
## та же система отсчёта, что и rotation.y у Turret).
func _local_point(local_deg: float, radius: float, height: float) -> Vector3:
	var rad: float = deg_to_rad(local_deg)
	return Vector3(-sin(rad) * radius, height, -cos(rad) * radius)

func _update_fov_debug_draw() -> void:
	var mesh: ImmediateMesh = _fov_debug_mesh.mesh
	mesh.clear_surfaces()

	const SEGMENTS := 16
	const HEIGHT := 0.55  # чуть выше корпуса — видно поверх HullMesh, не тонет в земле
	var radius: float = vision_range
	var fill_color: Color = Color(1.0, 0.15, 0.1, 0.28) if state == State.TRACK else Color(0.15, 0.9, 0.2, 0.22)
	var center := Vector3(0.0, HEIGHT, 0.0)

	# ТЕКУЩИЙ конус обзора — центр на _look_yaw (в локальных координатах бота), не на
	# направлении корпуса: веер движется вместе с блужданием/слежением взгляда.
	var look_local_deg: float = rad_to_deg(wrapf(_look_yaw - _body.rotation.y, -PI, PI))
	var cone_min_deg: float = look_local_deg - look_cone_deg * 0.5
	var cone_max_deg: float = look_local_deg + look_cone_deg * 0.5

	# Заливка веера — треугольниками (у ImmediateMesh нет отдельного TRIANGLE_FAN).
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	mesh.surface_set_color(fill_color)
	var prev_point: Vector3 = _local_point(cone_min_deg, radius, HEIGHT)
	for i in range(1, SEGMENTS + 1):
		var t: float = float(i) / float(SEGMENTS)
		var deg: float = lerp(cone_min_deg, cone_max_deg, t)
		var cur_point: Vector3 = _local_point(deg, radius, HEIGHT)
		mesh.surface_add_vertex(center)
		mesh.surface_add_vertex(prev_point)
		mesh.surface_add_vertex(cur_point)
		prev_point = cur_point
	mesh.surface_end()

	# Контур конуса (боковые радиусы + дуга) — ярче заливки, чтобы границы читались чётко.
	var outline_color := Color(fill_color.r, fill_color.g, fill_color.b, 0.9)
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(outline_color)
	mesh.surface_add_vertex(center)
	for i in range(SEGMENTS + 1):
		var t2: float = float(i) / float(SEGMENTS)
		var deg2: float = lerp(cone_min_deg, cone_max_deg, t2)
		mesh.surface_add_vertex(_local_point(deg2, radius, HEIGHT))
	mesh.surface_add_vertex(center)
	mesh.surface_end()

	# Текущее РЕАЛЬНОЕ направление башни (не конус "камеры", а куда башня уже физически
	# довернула) — turret уже дочерний узел _body, rotation.y у неё локальный без пересчёта.
	var turret_local_deg: float = rad_to_deg(_turret.rotation.y)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 1.0, 0.2, 0.95))
	mesh.surface_add_vertex(center)
	mesh.surface_add_vertex(_local_point(turret_local_deg, radius, HEIGHT))
	mesh.surface_end()

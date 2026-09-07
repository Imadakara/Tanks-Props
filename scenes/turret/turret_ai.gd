extends Node
## TurretAI — мозг стационарной турели. «Неподвижный танк» с бесконечным боезапасом и всего
## тремя стейтами:
## - SEARCH  — башня крутится по кругу (360°) с постоянной угловой скоростью, ищет цель тем же
##             способом, что и танк-бот: конус вокруг ТЕКУЩЕГО угла башни + дальность + LOS-луч
##             + гейт маскировки (замаскированный танк не виден). Плюс шаринг цели по ALERT:
##             союзный защитный танк, вошедший в бой из ALERT, зовёт on_alert_target_shared() —
##             турель доворачивает башню на переданную точку и берёт цель в ATTACK, как только
##             реально её увидит (LOS/дальность).
## - ATTACK  — фокус на цели: башня+дуло наводятся по баллистике каждый кадр, выстрел по
##             сведённому прицелу с каденсом shot_interval_sec. Обойма (mag_size, базово 10)
##             кончилась → RELOAD. Цель пропала дольше grace → назад в SEARCH.
## - RELOAD  — reload_sec (базово 5) башня НЕ стреляет (но продолжает вести цель, если та видна,
##             чтобы быть готовой к концу перезарядки). По истечении — обойма полная, SEARCH.
##
## Сложность (difficulty) — как у танка: базовые числа ниже это MEDIUM (профиль medium-танка),
## EASY/HARD — пресеты в _apply_difficulty_preset(). Урон снаряда обычный (Projectile.damage=1),
## живучесть самой турели — HealthComponent.max_hits на корне (10).
##
## Турель НЕ подбирает ящики/модификации и НЕ маскируется (точек входа нет вовсе).

const ProjectileScene := preload("res://scenes/projectile/Projectile.tscn")
const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

## Должна совпадать с Projectile.fall_acceleration — снаряд не существует до выстрела, дублируем
## константу с явной привязкой (тот же приём, что tank_ai_controller._PROJECTILE_GRAVITY).
const _PROJECTILE_GRAVITY := 9.8

enum State { SEARCH, ATTACK, RELOAD }
enum Difficulty { EASY, MEDIUM, HARD }

@export var enabled: bool = true

@export var difficulty: Difficulty = Difficulty.MEDIUM

## Обзор/стрельба (база = MEDIUM, EASY/HARD перетираются пресетом).
@export var vision_range: float = 18.0
@export var fire_range: float = 15.0
## Ближняя мёртвая зона (горизонтальная XZ-дистанция от основания турели). Цель ближе этого:
## - турель её вообще НЕ ВИДИТ (_can_see() → false, в т.ч. для удержания уже захваченной) —
##   подъехал вплотную = вышел из зоны поражения, турель «теряет» цель и уходит в свип;
## - соответственно и не стреляет.
## Рисуется в debug-секторе внутренней дугой, как fire_range — только «слишком близко».
@export var min_fire_range: float = 3.0
## Полный угол конуса обнаружения — УЗКИЙ прицельный сектор вокруг ТЕКУЩЕГО направления ствола
## (как secondary_cone_deg у башни танка, ~15°, НЕ как широкий хулл-конус). Турель крутится на
## 360°, за оборот всё равно обшаривает весь круг — узкий сектор лишь задаёт мгновенное «поле
## зрения ствола»: видит только то, на что ствол сейчас смотрит.
@export var detect_cone_deg: float = 18.0
## Пока цель уже захвачена (ATTACK), удержание идёт по более широкому конусу — башня быстрая,
## терять цель из-за узкого сектора на довороте не нужно.
@export var track_cone_deg: float = 200.0
@export var fire_aim_tolerance_deg: float = 3.0
@export var fire_pitch_tolerance_deg: float = 3.0

## Угловая скорость поворота башни (рад/с) — применяется на TurretController; ею же крутится
## поисковый свип. База = turret_turn_speed medium-танка (1.0).
@export var turret_turn_speed: float = 1.0

## Начальная скорость снаряда турели (медиум-бот = 30).
@export var launch_speed: float = 30.0

## Пределы наклона дула турели — ПЕРЕОПРЕДЕЛЯЮТ дефолты barrel_controller.gd (-15°..+30°, заточены
## под танк на земле) на СВОЁМ инстансе Barrel, не трогая танки. Турель сидит высоко на объекте —
## ей нужна большая депрессия, чтобы доставать танки, подошедшие к основанию (иначе выжигает всю
## обойму мимо цели прямо под собой). Применяется в _initialize().
@export var barrel_min_pitch_deg: float = -60.0
@export var barrel_max_pitch_deg: float = 30.0

## Обойма и перезарядка. mag_size «как у обычного танка» (GameConfig.ammo_per_tank = 10),
## reload_sec настраиваемое, базово 5. shot_interval_sec — пауза между выстрелами ВНУТРИ обоймы:
## приравнена к темпу выстрела танка (GameConfig.reload_duration_sec = 3с — у танка это и есть
## время между двумя выстрелами через RELOAD). Итог: ровный «танковый» темп по одному снаряду
## раз в 3с, 10 снарядов, затем более долгая пауза reload_sec на смену обоймы.
@export var mag_size: int = 10
@export var reload_sec: float = 5.0
@export var shot_interval_sec: float = 3.0

## Прицеливаться не в origin танка-цели (это низ хитбокса, y≈0.3), а на столько выше — по центру
## корпуса. Турель бьёт СВЕРХ ВНИЗ (сидит на объекте, ~y3.5): целясь в «ноги», дуга вырождается у
## самой земли и снаряды чиркают под целью на средней/дальней дистанции. Центр масс попадает
## стабильно. (Танк-vs-танк такой проблемы нет — там стреляют почти горизонтально с y≈0.6.)
@export var aim_height_offset: float = 0.4

## Сколько секунд держать цель, переданную союзником по ALERT, если турель её так и не увидела сама.
@export var alert_share_ttl_sec: float = 6.0
## Grace: сколько секунд не рвать ATTACK после того, как цель пропала из виду (кратковременное
## перекрытие геометрией / доля кадра рассинхрона на довороте).
@export var target_lost_grace_sec: float = 1.0

## Debug-визуализация сектора обзора/обстрела — аналог TankAIController.show_fov_debug. Рисуется
## ТОЛЬКО в MatchState.debug_enabled (и при этом флаге). Веер на уровне земли вокруг основания
## турели: заливка = конус обнаружения (detect_cone_deg вокруг РЕАЛЬНОГО угла башни, радиус
## vision_range), цвет по стейту (розовый SEARCH / красный ATTACK / оранжевый RELOAD / жёлтый —
## слежение за целью, переданной по ALERT); оранжевая дуга внутри — граница дистанции стрельбы
## (fire_range); ярко-красная дуга у центра — ближняя мёртвая зона (min_fire_range); жёлтая линия —
## точное направление ствола.
@export var show_fov_debug: bool = true

var _DIFFICULTY_PRESETS := {
	Difficulty.EASY: {
		"vision_range": 14.0,
		"fire_range": 11.0,
		"detect_cone_deg": 14.0,
		"fire_aim_tolerance_deg": 5.0,
		"fire_pitch_tolerance_deg": 5.0,
		"turret_turn_speed": 0.8,
		"shot_interval_sec": 4.0,
	},
	Difficulty.HARD: {
		"vision_range": 22.0,
		"fire_range": 18.0,
		"detect_cone_deg": 26.0,
		"fire_aim_tolerance_deg": 1.5,
		"fire_pitch_tolerance_deg": 1.5,
		"turret_turn_speed": 2.2,
		"shot_interval_sec": 2.0,
	},
}

var _state: int = State.SEARCH
var _initialized := false

var _turret: Node3D          # TurretPivot (turret_controller.gd)
var _barrel: Node3D          # TurretPivot/Barrel (barrel_controller.gd)
var _origin: Node3D          # корень турели (StaticBody3D) — для позиции/LOS-exclude/team

var _target: Node3D = null
var _lost_grace_timer: float = 0.0

var _mag: int = 0
var _reload_timer: float = 0.0
var _shot_cooldown: float = 0.0

var _sweep_dir: float = 1.0
var _desired_yaw: float = 0.0  # мировой yaw, к которому доводится башня

var _alert_target: Node3D = null
var _alert_timer: float = 0.0

var _fov_mesh: MeshInstance3D = null

## Централизованный ALERT-таймер/гео карты (map_scene.gd) — та же ссылка и тот же способ чтения,
## что у TankAIController._arena; null на карте без такой обвязки.
var _arena: Node = null

func _ready() -> void:
	# Ничего с побочными эффектами — весь захват в _initialize() первым enabled-тиком (как
	# TankAIController: узел живёт на префабе, а окружение — MatchManager/ALERT-обвязка — строится
	# кодом в корне сцены уже ПОСЛЕ _ready() детей).
	set_physics_process(true)

func _initialize() -> void:
	_initialized = true
	_apply_difficulty_preset()

	_origin = get_parent() as Node3D
	_turret = _origin.get_node_or_null("TurretPivot")
	_barrel = _origin.get_node_or_null("TurretPivot/Barrel")

	if _turret != null:
		_turret.is_player_controlled = false
		_turret.turn_speed = turret_turn_speed
		_desired_yaw = _origin.rotation.y + _turret.rotation.y
	if _barrel != null:
		_barrel.is_player_controlled = false
		_barrel.min_pitch_deg = barrel_min_pitch_deg
		_barrel.max_pitch_deg = barrel_max_pitch_deg

	_mag = mag_size

	var health: Node = _origin.get_node_or_null("HealthComponent")
	if health != null:
		health.destroyed.connect(_on_destroyed)

	# ALERT-обвязка карты — та же, что читает TankAIController (time_since_objective_hit /
	# enemy_in_alert_zone). Её может не быть (карта без objective) — все обращения через has_method.
	_arena = get_tree().current_scene

	if MatchState.debug_enabled and show_fov_debug:
		_setup_fov_debug()

func _apply_difficulty_preset() -> void:
	if not _DIFFICULTY_PRESETS.has(difficulty):
		return
	var preset: Dictionary = _DIFFICULTY_PRESETS[difficulty]
	for key in preset:
		set(key, preset[key])

func _physics_process(delta: float) -> void:
	if not enabled:
		return
	if not _initialized:
		_initialize()
	if _turret == null:
		return

	if _shot_cooldown > 0.0:
		_shot_cooldown -= delta
	if _alert_timer > 0.0:
		_alert_timer -= delta
		if _alert_timer <= 0.0:
			_alert_target = null

	match _state:
		State.SEARCH:
			_tick_search(delta)
		State.ATTACK:
			_tick_attack(delta)
		State.RELOAD:
			_tick_reload(delta)

	if _fov_mesh != null:
		_update_fov_debug()

# --- SEARCH -----------------------------------------------------------------------------------

func _tick_search(delta: float) -> void:
	# 1. Сами кого-то видим → ATTACK.
	var seen: Node3D = _scan_for_target()
	if seen != null:
		_enter_attack(seen)
		return

	# 2. Союзник передал цель по ALERT — доворачиваем башню на неё; увидели по-настоящему → ATTACK.
	if _alert_target != null and is_instance_valid(_alert_target) and _alert_target.visible:
		_aim_turret_at(_alert_target.global_position + Vector3.UP * aim_height_offset)
		if _can_see(_alert_target, false):
			_enter_attack(_alert_target)
		return

	# 3. Обычный свип по кругу с постоянной угловой скоростью (как башня танка в _wander, но без
	# пауз/случайных секторов — ровное вращение на 360°).
	_desired_yaw = wrapf(_desired_yaw + _sweep_dir * turret_turn_speed * delta, -PI, PI)
	_turret.target_yaw = wrapf(_desired_yaw - _origin.rotation.y, -PI, PI)
	if _barrel != null:
		_barrel.target_pitch = 0.0

# --- ATTACK ----------------------------------------------------------------------------------

func _tick_attack(delta: float) -> void:
	if _target == null or not is_instance_valid(_target) or not _target.visible:
		_drop_target()
		return

	# Удержание цели по широкому конусу + LOS. Пропала — grace, потом SEARCH.
	if _can_see(_target, true):
		_lost_grace_timer = target_lost_grace_sec
	else:
		_lost_grace_timer -= delta
		if _lost_grace_timer <= 0.0:
			_drop_target()
			return

	_aim_and_maybe_fire(delta)

func _aim_and_maybe_fire(delta: float) -> void:
	var aim_point: Vector3 = _target.global_position + Vector3.UP * aim_height_offset
	var from: Vector3 = _barrel.global_position if _barrel != null else _turret.global_position

	var yaw_world: float = _yaw_to_world_point(from, aim_point)
	_desired_yaw = yaw_world
	_turret.target_yaw = wrapf(yaw_world - _origin.rotation.y, -PI, PI)

	var to_aim: Vector3 = aim_point - from
	var dist_xz: float = Vector2(to_aim.x, to_aim.z).length()
	var pitch: float = _ballistic_pitch(dist_xz, to_aim.y)
	if _barrel != null:
		_barrel.target_pitch = pitch

	# Не стреляем в RELOAD-каденсе / вне дальности / в ближней мёртвой зоне / с недоведённым прицелом.
	# Дистанция — ГОРИЗОНТАЛЬНАЯ (XZ) от основания турели: ровно то, что рисуют дуги fire_range/
	# min_fire_range в debug-секторе (турель сидит выше земли, 3D-дистанция до наземной цели никогда
	# не бывает < 1м и мёртвая зона была бы фикцией).
	if _shot_cooldown > 0.0:
		return
	var flat: Vector3 = _target.global_position - _origin.global_position
	var dist: float = Vector2(flat.x, flat.z).length()
	if dist > fire_range or dist < min_fire_range:
		return
	var yaw_err: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	var pitch_err: float = 0.0
	if _barrel != null:
		pitch_err = rad_to_deg(absf(_barrel.target_pitch - _barrel.rotation.x))
	if yaw_err > fire_aim_tolerance_deg or pitch_err > fire_pitch_tolerance_deg:
		return

	_fire()

func _fire() -> void:
	var dir: Vector3 = -_barrel.global_transform.basis.z if _barrel != null else -_turret.global_transform.basis.z
	var muzzle: Vector3 = (_barrel.global_position if _barrel != null else _turret.global_position) + dir * 0.8
	var proj := ProjectileScene.instantiate()
	get_tree().current_scene.add_child(proj)
	proj.speed = launch_speed
	proj.launch(muzzle, dir, _origin)

	_shot_cooldown = shot_interval_sec
	_mag -= 1
	if _mag <= 0:
		_state = State.RELOAD
		_reload_timer = reload_sec

# --- RELOAD --------------------------------------------------------------------------------

func _tick_reload(delta: float) -> void:
	_reload_timer -= delta
	# Ведём цель башней, если ещё видим — чтобы к концу перезарядки быть наведённой. Не стреляем.
	if _target != null and is_instance_valid(_target) and _target.visible and _can_see(_target, true):
		var from: Vector3 = _barrel.global_position if _barrel != null else _turret.global_position
		var aim_point: Vector3 = _target.global_position + Vector3.UP * aim_height_offset
		var yaw_world: float = _yaw_to_world_point(from, aim_point)
		_turret.target_yaw = wrapf(yaw_world - _origin.rotation.y, -PI, PI)
		var to_aim: Vector3 = aim_point - from
		if _barrel != null:
			_barrel.target_pitch = _ballistic_pitch(Vector2(to_aim.x, to_aim.z).length(), to_aim.y)
	else:
		_target = null
	if _reload_timer <= 0.0:
		_mag = mag_size
		_state = State.SEARCH if _target == null else State.ATTACK

# --- helpers ------------------------------------------------------------------------------

func _enter_attack(target: Node3D) -> void:
	_target = target
	_alert_target = null
	_alert_timer = 0.0
	_lost_grace_timer = target_lost_grace_sec
	_state = State.ATTACK

func _drop_target() -> void:
	_target = null
	_state = State.SEARCH

func _aim_turret_at(world_point: Vector3) -> void:
	var from: Vector3 = _barrel.global_position if _barrel != null else _turret.global_position
	var yaw_world: float = _yaw_to_world_point(from, world_point)
	_desired_yaw = yaw_world
	_turret.target_yaw = wrapf(yaw_world - _origin.rotation.y, -PI, PI)
	var to_aim: Vector3 = world_point - from
	if _barrel != null:
		_barrel.target_pitch = _ballistic_pitch(Vector2(to_aim.x, to_aim.z).length(), to_aim.y)

## Ближайший видимый вражеский танк. Тот же паттерн, что TankAIController._scan_for_target(), но
## без приоритета по HP — турели хватает «первый видимый».
func _scan_for_target() -> Node3D:
	var best: Node3D = null
	var best_dist: float = INF
	for other in get_tree().get_nodes_in_group("tanks"):
		if not is_instance_valid(other) or other == _origin:
			continue
		if int(other.team) == int(_origin.team):
			continue
		if not _can_see(other, false):
			continue
		var d: float = _origin.global_position.distance_to(other.global_position)
		if d < best_dist:
			best_dist = d
			best = other
	return best

## Видит ли турель эту цель. holding=true — режим удержания уже захваченной цели: широкий конус
## (track_cone_deg) и гейт маскировки СНЯТ (замаскировавшегося «в упор» под прицелом не теряем —
## как ignore_disguise у танка). holding=false — первичное обнаружение: узкий конус + маскировка.
func _can_see(target: Node3D, holding: bool) -> bool:
	if not target.visible:
		return false
	var health: Node = target.get_node_or_null("HealthComponent")
	if health != null and not health.is_alive:
		return false
	if not holding and not GameConfig.ai_can_see_disguised_tanks:
		var sm: Node = target.get_node_or_null("TankStateMachine")
		if sm != null and sm.state == TankStateMachineScript.State.DISGUISED:
			return false

	var eye: Vector3 = _barrel.global_position if _barrel != null else _turret.global_position
	var to_target: Vector3 = target.global_position - eye
	var dist: float = to_target.length()
	if dist > vision_range or dist < 0.01:
		return false
	# Ближняя мёртвая зона: цель, подъехавшая вплотную к основанию турели (XZ), выпадает из обзора
	# целиком — турель её «теряет» (и не может по ней стрелять). Та же XZ-дистанция от _origin, что
	# и в гейте выстрела и в debug-дуге.
	var flat_to_target: Vector3 = target.global_position - _origin.global_position
	if Vector2(flat_to_target.x, flat_to_target.z).length() < min_fire_range:
		return false

	var world_yaw: float = _yaw_to_world_point(eye, target.global_position)
	var turret_world_yaw: float = _origin.rotation.y + _turret.rotation.y
	var cone: float = track_cone_deg if holding else detect_cone_deg
	var diff_deg: float = rad_to_deg(absf(wrapf(world_yaw - turret_world_yaw, -PI, PI)))
	if diff_deg > cone * 0.5:
		return false

	var space := _origin.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(eye, target.global_position + Vector3.UP * 0.3)
	query.exclude = [_origin]
	query.collision_mask = 1 | 2  # environment + tanks
	var result: Dictionary = space.intersect_ray(query)
	return result.is_empty() or result.get("collider") == target

## Настильная (низкая) дуга до точки — тот же вывод, что tank_ai_controller._compute_ballistic_pitch
## (t_low = меньший корень), клампится в предел дула barrel_controller.gd (-15°..+30°).
func _ballistic_pitch(dist_xz: float, height_diff: float) -> float:
	var min_deg: float = _barrel.min_pitch_deg if _barrel != null else -15.0
	var max_deg: float = _barrel.max_pitch_deg if _barrel != null else 30.0
	if dist_xz < 0.01 or launch_speed < 0.01:
		return 0.0
	var a: float = (_PROJECTILE_GRAVITY * dist_xz * dist_xz) / (2.0 * launch_speed * launch_speed)
	var c: float = height_diff + a
	var discriminant: float = dist_xz * dist_xz - 4.0 * a * c
	var pitch: float
	if discriminant < 0.0:
		pitch = deg_to_rad(max_deg)
	else:
		pitch = atan((dist_xz - sqrt(discriminant)) / (2.0 * a))
	return clamp(pitch, deg_to_rad(min_deg), deg_to_rad(max_deg))

func _yaw_to_world_point(from: Vector3, to_point: Vector3) -> float:
	var d: Vector3 = to_point - from
	return atan2(-d.x, -d.z)

# --- debug FOV/fire-sector overlay (аналог TankAIController._setup/_update_fov_debug_draw) -----

## Ребёнок КОРНЯ турели (_origin), не башни: башня физически крутится, а веер мы поворачиваем
## сами на _turret.rotation.y в локальных координатах _origin — так дуга рисуется на уровне земли
## вокруг основания турели (как у танка веер лежит на земле у корпуса), а не парит на высоте башни.
func _setup_fov_debug() -> void:
	_fov_mesh = MeshInstance3D.new()
	_fov_mesh.name = "TurretFovDebugMesh"
	_fov_mesh.mesh = ImmediateMesh.new()
	_fov_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	_fov_mesh.material_override = mat
	_origin.add_child.call_deferred(_fov_mesh)

## Точка в ЛОКАЛЬНЫХ координатах _origin: deg=0 — вдоль локального -Z (та же система отсчёта, что
## rotation.y у TurretPivot). Аналог TankAIController._local_point().
func _fov_local_point(deg: float, radius: float, height: float) -> Vector3:
	var r: float = deg_to_rad(deg)
	return Vector3(-sin(r) * radius, height, -cos(r) * radius)

## Дистанция до первого препятствия по горизонтальному лучу НА УРОВНЕ ЗЕМЛИ (`_GROUND_TARGET_Y`,
## тот же мировой Y, на котором лежит сам debug-веер — см. `h` ниже), не из настоящего "глаза"
## турели. Используется ТОЛЬКО debug-отрисовкой, маска та же (environment+tanks), что у реального
## LOS в _can_see().
##
## [ИСПРАВЛЕНО, по прямому запросу — "для вижена турели на objective не работает"] Первая версия
## пускала луч из настоящего глаза (`_barrel`/`_turret.global_position`) в точку на земле на краю
## радиуса — не сработало: ObjectiveTurret стоит на макушке objective (пьедестал +2, плюс
## TurretPivot/Barrel ещё +1.6 локально), ствол на world Y ~3.6. Луч от такой высоты к дальней
## наземной точке (18м) идёт полого — на 6м пути он ещё на Y≈2.44, выше любого обычного препятствия
## (~1.25-2м, `obstacle.gd`) — технически ВЕРНО (турель правда видит поверх низкой стены цель ЗА
## ней), но для плоского веера "один радиус на угол" такую вилку не нарисовать (пришлось бы рисовать
## два отдельных сегмента радиуса с разрывом), и практически видимого среза не было почти нигде —
## обычные препятствия ближе ~12м от турели вообще не давали обрезки ни при каком направлении.
## Вместо честной (и в общем случае разрывной) геометрии "вижу с высоты" — та же ПЛОСКАЯ проверка на
## уровне земли, что у обычного танка/наземной турели: луч НЕ из настоящего ствола, а от XZ-позиции
## турели на высоте самого веера. Дешевле честной версии (один луч, без трассировки), даёт
## интуитивно ожидаемую картинку "стена режет конус", и НЕДО-показывает реальную дальность турели
## (никогда не завышает) — приемлемый компромисс для debug-оверлея, реальную детекцию (`_can_see()`)
## не трогает.
const _GROUND_TARGET_Y: float = 0.12  # тот же мировой Y, что и плоскость debug-веера (см. `h` ниже)

func _fov_obstacle_dist(local_deg: float, max_range: float) -> float:
	var world_yaw: float = _origin.rotation.y + deg_to_rad(local_deg)
	var dir := Vector3(-sin(world_yaw), 0.0, -cos(world_yaw))
	var origin: Vector3 = _origin.global_position
	origin.y = _GROUND_TARGET_Y
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_range)
	query.exclude = [_origin]
	query.collision_mask = 1 | 2  # environment + tanks — та же маска, что _can_see()
	var result: Dictionary = _origin.get_world_3d().direct_space_state.intersect_ray(query)
	return max_range if result.is_empty() else origin.distance_to(result["position"])

func _update_fov_debug() -> void:
	var mesh: ImmediateMesh = _fov_mesh.mesh
	mesh.clear_surfaces()

	const SEGMENTS := 20
	# Веер на уровне земли: origin турели на макушке objective (~y2), земля ~y0 → локальный низ.
	var h: float = 0.12 - _origin.global_position.y
	var center := Vector3(0.0, h, 0.0)
	var facing_deg: float = rad_to_deg(_turret.rotation.y)
	var half: float = detect_cone_deg * 0.5
	var cone_min: float = facing_deg - half
	var cone_max: float = facing_deg + half

	var fill: Color
	match _state:
		State.ATTACK:
			fill = Color(1.0, 0.15, 0.1, 0.28)
		State.RELOAD:
			fill = Color(1.0, 0.55, 0.1, 0.20)
		_:
			# SEARCH: жёлтый, если ведём цель, переданную по ALERT; иначе розовый (как у танка).
			fill = Color(0.95, 0.85, 0.15, 0.24) if _alert_target != null and is_instance_valid(_alert_target) else Color(0.95, 0.25, 0.55, 0.24)

	# Обрезка по препятствиям (см. doc-comment _fov_obstacle_dist()) — один луч на угол сегмента,
	# переиспользуется для заливки/контура (vision_range) и обеих внутренних дуг на том же угле.
	# [ОПЦИОНАЛЬНО, по прямому запросу — "обрезание вижена опционально в дебаг-режиме, по умолчанию
	# выкл"] Только когда MatchState.fov_debug_clip_obstacles — иначе ни одного raycast'а, веер на
	# полный радиус (см. её doc-comment в match_state.gd).
	var clip: Array[float] = []
	for i in range(SEGMENTS + 1):
		if MatchState.fov_debug_clip_obstacles:
			clip.append(_fov_obstacle_dist(lerp(cone_min, cone_max, float(i) / float(SEGMENTS)), vision_range))
		else:
			clip.append(vision_range)

	# Заливка конуса обнаружения (радиус vision_range) — треугольниками от центра.
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	mesh.surface_set_color(fill)
	var prev: Vector3 = _fov_local_point(cone_min, clip[0], h)
	for i in range(1, SEGMENTS + 1):
		var deg: float = lerp(cone_min, cone_max, float(i) / float(SEGMENTS))
		var cur: Vector3 = _fov_local_point(deg, clip[i], h)
		mesh.surface_add_vertex(center)
		mesh.surface_add_vertex(prev)
		mesh.surface_add_vertex(cur)
		prev = cur
	mesh.surface_end()

	# Контур конуса (радиусы + дуга).
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(Color(fill.r, fill.g, fill.b, 0.9))
	mesh.surface_add_vertex(center)
	for i in range(SEGMENTS + 1):
		mesh.surface_add_vertex(_fov_local_point(lerp(cone_min, cone_max, float(i) / float(SEGMENTS)), clip[i], h))
	mesh.surface_add_vertex(center)
	mesh.surface_end()

	# Граница дистанции стрельбы (fire_range) — дуга внутри конуса, оранжевая, без линий к центру.
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(Color(1.0, 0.35, 0.0, 0.95))
	for i in range(SEGMENTS + 1):
		mesh.surface_add_vertex(_fov_local_point(lerp(cone_min, cone_max, float(i) / float(SEGMENTS)), minf(fire_range, clip[i]), h))
	mesh.surface_end()

	# Ближняя мёртвая зона (min_fire_range) — та же дуга, но у самого центра, ярко-красная:
	# «слишком близко, огонь заперт».
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(Color(1.0, 0.1, 0.1, 0.95))
	for i in range(SEGMENTS + 1):
		mesh.surface_add_vertex(_fov_local_point(lerp(cone_min, cone_max, float(i) / float(SEGMENTS)), minf(min_fire_range, clip[i]), h))
	mesh.surface_end()

	# Точное направление ствола — жёлтая линия от центра до vision_range.
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 1.0, 0.2, 0.95))
	mesh.surface_add_vertex(center)
	mesh.surface_add_vertex(_fov_local_point(facing_deg, vision_range, h))
	mesh.surface_end()

func _on_destroyed(_killer: Node) -> void:
	enabled = false
	_target = null
	if _fov_mesh != null:
		_fov_mesh.queue_free()
		_fov_mesh = null

## Публичный вход шаринга цели по ALERT. Зовётся из TankAIController._notify_team_of_alert_target()
## союзным защитным танком, вошедшим в бой из ALERT: турель разворачивает башню на цель и берёт её
## в ATTACK, как только реально увидит (LOS/дальность/маскировка проверяются в _tick_search).
func on_alert_target_shared(target: Node) -> void:
	if not enabled or target == null or not is_instance_valid(target):
		return
	if _state == State.ATTACK:
		return  # уже дерёмся — своя цель приоритетнее переданной
	_alert_target = target
	_alert_timer = alert_share_ttl_sec

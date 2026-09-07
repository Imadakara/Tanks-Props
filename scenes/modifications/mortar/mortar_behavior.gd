extends "res://scenes/modifications/modification_behavior.gd"
## MortarBehavior — поведение модификации «мортира» (первая реализация контракта
## ModificationBehavior; полное описание — vault `Tank_Prop_Hunt_Modifications.md`). Одноразовая
## насадка на дуло: навесной спец-выстрел НЕ в один клик.
##
## - визуал: красная цилиндрическая насадка на стволе (строится в `on_installed()`, длина =
##   половина ствола; процедурный меш — как `disguise_controller._build_prop_if_needed()`);
## - применение (игрок): 1-й клик `fire` → режим прицеливания; 2-й клик `fire` → навесной выстрел;
##   нажатие клавиши движения → выход из режима без выстрела (это и объясняет невозможность
##   стрельбы мортирой на ходу);
## - в режиме прицеливания: корпус зафиксирован (`TankMovement` гейтит по `blocks_hull_movement()`),
##   обзор игрока переключён на `Turret/MortarCamera` (жёстко следует за yaw башни), вместо
##   штатного прицела — КОЛЬЦО НА ЗЕМЛЕ (`_reticle_ring`, TorusMesh, top_level) в предполагаемой
##   точке падения: скользит по поверхности вслед за мышью; мышь X крутит башню, мышь Y двигает
##   точку ближе/дальше в `[_RETICLE_MIN_DIST .. GameConfig.mortar_range]`; дуло задирается на
##   навесной баллистический угол до точки кольца (ближняя точка → самый крутой подъём);
## - бот режим прицеливания/камеру НЕ использует — целится и стреляет через `ai_*` (см.
##   `TankAIController._process_mortar_attack`).
##
## Баллистика (`_solve_high_pitch`): квадрат относительно t=tanθ, берётся БОЛЬШИЙ корень —
## навесная дуга; в `tank_ai_controller._compute_ballistic_pitch()` та же форма, но меньший корень
## (настильная пушка). Числовой баланс — в `GameConfig` (`mortar_*`), как и остальной баланс проекта.

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

## Должна совпадать с Projectile.fall_acceleration — снаряд ещё не существует до выстрела,
## дублируем константу с явной привязкой (тот же приём, что в tank_ai_controller._PROJECTILE_GRAVITY).
const _PROJECTILE_GRAVITY := 9.8
const _RETICLE_MIN_DIST := 2.0       # самый ближний вынос кольца = самый высокий подъём дула
const _YAW_SENSITIVITY := 0.005      # рад на пиксель мыши по X (как camera_rig.mouse_sensitivity)
const _DIST_SENSITIVITY := 0.02      # ед. выноса кольца на пиксель мыши по Y

var _aiming: bool = false
var _aim_yaw: float = 0.0            # мировой yaw, к которому доводится башня в режиме прицеливания
var _reticle_dist: float = 0.0      # текущий вынос кольца вперёд по направлению башни
var _reticle_world_point: Vector3 = Vector3.ZERO
var _mortar_pitch: float = 0.0      # навесной угол возвышения дула до точки кольца (рад)
var _mortar_mesh: MeshInstance3D = null
## Кольцо-прицел НА ЗЕМЛЕ в предполагаемой точке падения. top_level — трансформ мировой, не
## наследуется от танка/башни.
var _reticle_ring: MeshInstance3D = null

var _tank: CharacterBody3D
var _turret: Node3D
var _barrel: Node3D
## Потолок возвышения дула, поднятый на время прицеливания мортиры (см. _begin_aiming).
const _MORTAR_MAX_PITCH_DEG := 85.0
var _saved_barrel_max_pitch_deg: float = 0.0
var _camera_rig: Node3D
var _mortar_camera: Camera3D
var _state_machine: Node
var _ammo: Node
var _weapon: Node

## _controller — ModificationController (наш родитель): зовём clear_slot() после выстрела.
@onready var _controller: Node = get_parent()

func setup(tank: Node) -> void:
	_tank = tank as CharacterBody3D
	_turret = tank.get_node("Hull/Turret")
	_barrel = tank.get_node("Hull/Turret/Barrel")
	_camera_rig = tank.get_node("CameraRig")
	_mortar_camera = tank.get_node("Hull/Turret/MortarCamera")
	_state_machine = tank.get_node("TankStateMachine")
	_ammo = tank.get_node("AmmoComponent")
	_weapon = tank.get_node("WeaponController")

func on_installed() -> void:
	_build_mesh()

func on_removed() -> void:
	if _aiming:
		_end_aiming()
	if _mortar_mesh != null:
		_mortar_mesh.queue_free()
		_mortar_mesh = null
	if _reticle_ring != null:
		_reticle_ring.queue_free()
		_reticle_ring = null

# --- Игрок ---------------------------------------------------------------------------------------

## Пока мортира в слоте — каждое нажатие `fire` у игрока идёт по мортирному пути (обычный
## выстрел недоступен).
func intercepts_fire() -> bool:
	return true

func on_fire_pressed() -> void:
	if _aiming:
		_launch(_reticle_world_point)
	else:
		_begin_aiming()

func blocks_hull_movement() -> bool:
	return _aiming

func hides_crosshair() -> bool:
	return _aiming

# --- Боты -------------------------------------------------------------------------------------

func ai_usable() -> bool:
	return true  # установлена → всегда готова (одноразовая, без кулдауна)

func ai_engage_range() -> float:
	return GameConfig.mortar_range

func ai_prep_sec() -> float:
	return GameConfig.mortar_prep_sec

func ai_aim_solution(from: Vector3, target: Vector3) -> Dictionary:
	var flat := Vector2(target.x - from.x, target.z - from.z).length()
	return {
		"pitch": _solve_high_pitch(flat, target.y - from.y),
		"yaw": atan2(-(target.x - from.x), -(target.z - from.z)),
	}

func ai_fire_at(target: Vector3) -> bool:
	return _launch(target)

# --- Общее -------------------------------------------------------------------------------------

## Навесной залп в мировую точку `target`. Направление считаем сами (дуга), боеприпас/RELOAD/спавн
## снаряда — общий WeaponController.fire_special(). Успех → расходуем модификацию (clear_slot).
func _launch(target: Vector3) -> bool:
	var dir: Vector3 = _launch_dir(_barrel.global_position, target)
	var ok: bool = _weapon.fire_special(dir, GameConfig.mortar_launch_speed, GameConfig.mortar_objective_damage)
	if ok:
		_controller.clear_slot()  # → on_removed() вернёт камеру/управление, если было прицеливание
	return ok

## Вход в режим прицеливания. Требует is_player_controlled, NORMAL (не посреди перезарядки/
## маскировки) и хотя бы один боеприпас.
func _begin_aiming() -> void:
	if _aiming or not is_player_controlled:
		return
	if _state_machine.state != TankStateMachineScript.State.NORMAL:
		return
	if not _ammo.has_ammo():
		return
	_aiming = true
	_reticle_dist = clampf(GameConfig.mortar_range * 0.6, _RETICLE_MIN_DIST, GameConfig.mortar_range)
	_aim_yaw = _tank.rotation.y + _turret.rotation.y  # стартуем с текущего мирового угла башни
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	# Обычный предел возвышения дула (barrel_controller.max_pitch_deg, +20°) стоит под настильную
	# стрельбу и под кадр камеры от 3-го лица. Навесная дуга мортиры уходит намного круче
	# (_solve_high_pitch даёт вплоть до 85°), и с обычным пределом ствол визуально врал бы: дуло
	# упёрто в 20°, а снаряд уходит по крутой дуге. На время прицеливания поднимаем предел, на
	# выходе возвращаем. Сам выстрел от предела не зависит вообще — он идёт через
	# WeaponController.fire_special() по посчитанному направлению, а не по basis ствола.
	_saved_barrel_max_pitch_deg = _barrel.max_pitch_deg
	_barrel.max_pitch_deg = _MORTAR_MAX_PITCH_DEG
	_camera_rig.is_active = false
	_mortar_camera.current = true
	_ensure_reticle_ring()
	_reticle_ring.visible = true

## Выход из режима БЕЗ выстрела (клавиша движения) либо как часть on_removed() после выстрела.
func _end_aiming() -> void:
	if not _aiming:
		return
	_aiming = false
	_turret.is_player_controlled = true
	_barrel.is_player_controlled = true
	_barrel.max_pitch_deg = _saved_barrel_max_pitch_deg
	_mortar_camera.current = false
	if _reticle_ring != null:
		_reticle_ring.visible = false
	_camera_rig.activate()  # is_active + Camera3D.current + повторный захват мыши

func _unhandled_input(event: InputEvent) -> void:
	if not is_player_controlled or not _aiming:
		return
	if event is InputEventMouseMotion:
		_aim_yaw -= event.relative.x * _YAW_SENSITIVITY
		_reticle_dist = clampf(
			_reticle_dist - event.relative.y * _DIST_SENSITIVITY,
			_RETICLE_MIN_DIST, GameConfig.mortar_range
		)
		return
	if event.is_action_pressed("move_forward") or event.is_action_pressed("move_backward") \
			or event.is_action_pressed("turn_left") or event.is_action_pressed("turn_right"):
		_end_aiming()

func _physics_process(_delta: float) -> void:
	if not _aiming:
		return
	# Башня доводится к _aim_yaw (мышь X); TurretController.rotate_toward делает это плавно.
	_turret.target_yaw = wrapf(_aim_yaw - _tank.rotation.y, -PI, PI)

	# Точка кольца: _reticle_dist вперёд по РЕАЛЬНОМУ текущему углу башни, спроецировано на землю.
	var turret_world_yaw: float = _tank.rotation.y + _turret.rotation.y
	var forward := Vector3(-sin(turret_world_yaw), 0.0, -cos(turret_world_yaw))
	var flat_point: Vector3 = _tank.global_position + forward * _reticle_dist
	_reticle_world_point = _project_to_ground(flat_point)

	# Навесной баллистический угол до точки кольца от дульного среза.
	var muzzle: Vector3 = _barrel.global_position
	var to_point: Vector3 = _reticle_world_point - muzzle
	var dist_xz: float = Vector2(to_point.x, to_point.z).length()
	_mortar_pitch = _solve_high_pitch(dist_xz, to_point.y)
	_barrel.target_pitch = _mortar_pitch

	if _reticle_ring != null:
		_reticle_ring.global_position = _reticle_world_point + Vector3(0.0, 0.05, 0.0)

## Единичный вектор направления запуска навесного снаряда от `from` в `target` (навесная дуга).
func _launch_dir(from: Vector3, target: Vector3) -> Vector3:
	var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
	var x: float = flat.length()
	var pitch: float = _solve_high_pitch(x, target.y - from.y)
	var horiz: Vector3 = flat.normalized() if x > 0.01 else Vector3(0.0, 0.0, -1.0)
	return (horiz * cos(pitch) + Vector3.UP * sin(pitch)).normalized()

## Кольцо на земле (TorusMesh в плоскости XZ). top_level — мировой трансформ. Строится один раз лениво.
func _ensure_reticle_ring() -> void:
	if _reticle_ring != null:
		return
	var torus := TorusMesh.new()
	torus.inner_radius = 0.45
	torus.outer_radius = 0.62
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.25, 0.15)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_reticle_ring = MeshInstance3D.new()
	_reticle_ring.name = "MortarReticleRing"
	_reticle_ring.mesh = torus
	_reticle_ring.material_override = mat
	_reticle_ring.top_level = true
	_reticle_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_reticle_ring.visible = false
	add_child(_reticle_ring)

## Луч вниз (mask=1, "environment") — та же техника, что spawn_zone.pick_spawn_position(). Промах
## (точка за краем поля) — берём исходную высоту.
func _project_to_ground(point: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var from := point + Vector3(0.0, 10.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 30.0)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return point
	return hit["position"]

## Навесная дуга: `a t² − x t + c = 0` относительно t=tanθ, `a = g x²/2v²`, `c = y + a`. БОЛЬШИЙ
## корень (высокая траектория). v = GameConfig.mortar_launch_speed. Дискриминант < 0 (цель дальше
## предела дальности при этой скорости) — крутой fallback вместо NaN.
func _solve_high_pitch(dist_xz: float, height_diff: float) -> float:
	var v: float = GameConfig.mortar_launch_speed
	if dist_xz < 0.01 or v < 0.01:
		return deg_to_rad(85.0)
	var a: float = (_PROJECTILE_GRAVITY * dist_xz * dist_xz) / (2.0 * v * v)
	var c: float = height_diff + a
	var discriminant: float = dist_xz * dist_xz - 4.0 * a * c
	if discriminant < 0.0:
		return deg_to_rad(85.0)
	var t_high: float = (dist_xz + sqrt(discriminant)) / (2.0 * a)
	return clampf(atan(t_high), 0.0, deg_to_rad(88.0))

## Красный цилиндр длиной в половину ствола на дульной половине Barrel. Ось (локальный +Y)
## поворотом −90° вокруг X кладётся вдоль −Z Barrel — то же выравнивание, что у BarrelMesh в Tank.tscn.
func _build_mesh() -> void:
	if _mortar_mesh != null:
		return
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.13
	cyl.bottom_radius = 0.13
	cyl.height = 0.4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.1, 0.1)
	_mortar_mesh = MeshInstance3D.new()
	_mortar_mesh.name = "MortarAttachment"
	_mortar_mesh.mesh = cyl
	_mortar_mesh.material_override = mat
	_mortar_mesh.transform = Transform3D(Basis(Vector3(1, 0, 0), -PI / 2.0), Vector3(0.0, 0.0, -0.6))
	_barrel.add_child(_mortar_mesh)

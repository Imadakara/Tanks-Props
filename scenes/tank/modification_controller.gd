extends Node3D
## ModificationController — единственный слот подбираемой модификации танка + вся логика первой
## модификации, «мортиры» (см. Tank_Prop_Hunt_Modifications.md в vault). Сиблинг-компонент под
## корнем Tank.tscn, тот же паттерн композиции и развязки player/AI через is_player_controlled,
## что у остальных компонентов танка.
##
## Слот:
## - подобрать модификацию можно ТОЛЬКО в пустой слот (can_pick_up()); подбор доступен обеим
##   командам (в т.ч. чтобы denyнуть противнику);
## - сбросить/удалить модификацию нельзя — только использовать (clear_slot() из
##   WeaponController после спец-выстрела) или потерять вместе с танком (RespawnController зовёт
##   clear_slot() на респавне).
##
## Мортира (одноразовая, id == &"mortar"):
## - визуал: красная цилиндрическая насадка на стволе (строится в install(), длина = половина
##   ствола; паттерн процедурного меша — как disguise_controller._build_prop_if_needed());
## - применение НЕ в один клик (см. weapon_controller.gd): первый клик «fire» → begin_aiming();
##   второй клик «fire» → навесной выстрел; нажатие кнопки движения → end_aiming() без выстрела
##   (это и объясняет невозможность стрельбы мортирой на ходу).
## - в режиме прицеливания: корпус зафиксирован (tank_movement.gd гейтит по is_aiming()), обзор
##   игрока переключён на MortarCamera (Camera3D, ребёнок Turret → жёстко следует за yaw башни),
##   вместо штатного прицела — КОЛЬЦО НА ЗЕМЛЕ (_reticle_ring, TorusMesh, top_level) в
##   предполагаемой точке падения снаряда: скользит по поверхности вслед за мышью
##   (get_reticle_world_point()); мышь X крутит башню (_aim_yaw → Turret.target_yaw), мышь Y
##   двигает точку ближе/дальше в пределах [_RETICLE_MIN_DIST .. GameConfig.mortar_range];
##   дуло задирается на навесной баллистический угол до точки кружка (_mortar_pitch) —
##   ближняя точка автоматически даёт самый крутой подъём.
##
## Баллистика навесного выстрела считается ЗДЕСЬ один раз за кадр (get_mortar_pitch()), и
## weapon_controller.gd берёт готовый угол — форма уравнения та же, что в
## tank_ai_controller._compute_ballistic_pitch(), но здесь берётся БОЛЬШИЙ корень (навесная дуга),
## а там меньший (настильная пушка).

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

## Должна совпадать с Projectile.fall_acceleration (scenes/projectile/projectile.gd) — снаряд ещё
## не существует до выстрела, дублируем константу с явной привязкой (тот же приём, что в
## tank_ai_controller.gd/_PROJECTILE_GRAVITY).
const _PROJECTILE_GRAVITY := 9.8
const _RETICLE_MIN_DIST := 2.0       # самый ближний вынос кружка = самый высокий подъём дула
const _YAW_SENSITIVITY := 0.005      # рад на пиксель мыши по X (как camera_rig.mouse_sensitivity)
const _DIST_SENSITIVITY := 0.02      # ед. выноса кружка на пиксель мыши по Y

signal mod_changed(mod: Resource)

@export var is_player_controlled: bool = true

## null == слот пуст. Ссылка на Modification-ресурс (scenes/modifications/*.tres).
var current_mod: Resource = null

var _aiming: bool = false
var _aim_yaw: float = 0.0             # мировой yaw, к которому доводится башня в режиме прицеливания
var _reticle_dist: float = 0.0       # текущий вынос кружка вперёд по направлению башни
var _reticle_world_point: Vector3 = Vector3.ZERO
var _mortar_pitch: float = 0.0       # навесной угол возвышения дула до точки кружка (рад)
var _mortar_mesh: MeshInstance3D = null
## Кольцо-прицел, лежащее НА ЗЕМЛЕ в предполагаемой точке падения снаряда — скользит по
## поверхности вслед за мышью (по прямому запросу вместо экранного кружка). top_level, чтобы
## трансформ был мировым, а не наследовался от танка/башни.
var _reticle_ring: MeshInstance3D = null

@onready var _body: CharacterBody3D = get_parent()
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _barrel: Node3D = get_parent().get_node("Turret/Barrel")
@onready var _camera_rig: Node3D = get_parent().get_node("CameraRig")
@onready var _mortar_camera: Camera3D = get_parent().get_node("Turret/MortarCamera")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _ammo: Node = get_parent().get_node("AmmoComponent")

# --- Слот -------------------------------------------------------------------------------------

func can_pick_up() -> bool:
	return current_mod == null

## Вставить модификацию в слот. false — слот занят (подбор запрещён). Зовётся из ModCrate при
## физическом контакте танка с ящиком (игрок и бот одинаково).
func install(mod: Resource) -> bool:
	if current_mod != null or mod == null:
		return false
	current_mod = mod
	if StringName(mod.id) == &"mortar":
		_build_mortar_mesh()
	mod_changed.emit(current_mod)
	return true

## Освободить слот. Две точки вызова, поведение одинаково: WeaponController после навесного
## выстрела («использована») и RespawnController на респавне («потеряна с танком»). Идемпотентна.
func clear_slot() -> void:
	if _aiming:
		end_aiming()
	if _mortar_mesh != null:
		_mortar_mesh.queue_free()
		_mortar_mesh = null
	if current_mod == null:
		return
	current_mod = null
	mod_changed.emit(null)

# --- Режим прицеливания мортиры (только игрок) -----------------------------------------------

func is_aiming() -> bool:
	return _aiming

## Вход в режим прицеливания. Зовётся WeaponController по первому клику «fire», когда мортира в
## слоте и режим ещё не активен. Требует NORMAL (не посреди перезарядки/маскировки) и хотя бы
## один боеприпас (для выстрела нужен, см. ТЗ).
func begin_aiming() -> bool:
	if _aiming or not is_player_controlled:
		return false
	if current_mod == null or StringName(current_mod.id) != &"mortar":
		return false
	if _state_machine.state != TankStateMachineScript.State.NORMAL:
		return false
	if not _ammo.has_ammo():
		return false
	_aiming = true
	_reticle_dist = clampf(GameConfig.mortar_range * 0.6, _RETICLE_MIN_DIST, GameConfig.mortar_range)
	_aim_yaw = _body.rotation.y + _turret.rotation.y  # стартуем с текущего мирового угла башни
	# Башня/дуло теперь ведём отсюда напрямую, а не через camera_rig-следование.
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	_camera_rig.is_active = false
	_mortar_camera.current = true
	_ensure_reticle_ring()
	_reticle_ring.visible = true
	return true

## Выход из режима БЕЗ выстрела (нажата кнопка движения) либо как часть clear_slot() после
## выстрела. Возвращает управление камерой/башне/дулу.
func end_aiming() -> void:
	if not _aiming:
		return
	_aiming = false
	_turret.is_player_controlled = true
	_barrel.is_player_controlled = true
	_mortar_camera.current = false
	if _reticle_ring != null:
		_reticle_ring.visible = false
	_camera_rig.activate()  # is_active + Camera3D.current + повторный захват мыши

## Мировая точка прицела на земле (там лежит кольцо _reticle_ring; WeaponController берёт как цель).
func get_reticle_world_point() -> Vector3:
	return _reticle_world_point

## Навесной угол возвышения дула до точки кружка (рад). WeaponController реконструирует из него
## вектор запуска снаряда.
func get_mortar_pitch() -> float:
	return _mortar_pitch

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
		end_aiming()

func _physics_process(_delta: float) -> void:
	if not _aiming:
		return
	if current_mod == null:  # defensive — слот очистили извне посреди прицеливания
		end_aiming()
		return
	# Башня доводится к _aim_yaw (мышь X); TurretController.rotate_toward делает это плавно.
	_turret.target_yaw = wrapf(_aim_yaw - _body.rotation.y, -PI, PI)

	# Точка кружка: _reticle_dist вперёд по РЕАЛЬНОМУ текущему углу башни, спроецировано на землю.
	var turret_world_yaw: float = _body.rotation.y + _turret.rotation.y
	var forward := Vector3(-sin(turret_world_yaw), 0.0, -cos(turret_world_yaw))
	var flat_point: Vector3 = _body.global_position + forward * _reticle_dist
	_reticle_world_point = _project_to_ground(flat_point)

	# Навесной баллистический угол до точки кружка от дульного среза.
	var muzzle: Vector3 = _barrel.global_position
	var to_point: Vector3 = _reticle_world_point - muzzle
	var dist_xz: float = Vector2(to_point.x, to_point.z).length()
	_mortar_pitch = _solve_ballistic_high_pitch(dist_xz, to_point.y)
	_barrel.target_pitch = _mortar_pitch

	# Кольцо-прицел скользит по земле в точку падения (небольшой подъём по Y — против z-fighting).
	if _reticle_ring != null:
		_reticle_ring.global_position = _reticle_world_point + Vector3(0.0, 0.05, 0.0)

## Единица направления запуска навесного снаряда от точки `from` в точку `target` (навесная дуга).
## Общий вход для игрока (weapon_controller._fire_mortar → get_reticle_world_point()) и ботов
## (tank_ai_controller MORTAR_ATTACK). Скорость снаряда — GameConfig.mortar_launch_speed.
func mortar_launch_dir(from: Vector3, target: Vector3) -> Vector3:
	var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
	var x: float = flat.length()
	var pitch: float = _solve_ballistic_high_pitch(x, target.y - from.y)
	var horiz: Vector3 = flat.normalized() if x > 0.01 else Vector3(0.0, 0.0, -1.0)
	return (horiz * cos(pitch) + Vector3.UP * sin(pitch)).normalized()

## Кольцо на земле (TorusMesh, лежит в плоскости XZ). top_level — мировой трансформ, не
## наследуется от танка. Строится один раз лениво, дальше только visible/global_position.
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
## (кружок за краем поля) — берём исходную высоту.
func _project_to_ground(point: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var from := point + Vector3(0.0, 10.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 30.0)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return point
	return hit["position"]

## Навесная дуга: квадрат относительно t=tanθ, `a t² − x t + c = 0`, `a = g x²/2v²`, `c = y + a`.
## Берём БОЛЬШИЙ корень (высокая траектория, миномёт) — в tank_ai_controller._compute_ballistic_pitch
## наоборот берётся меньший (настильная пушка). v — GameConfig.mortar_launch_speed. Дискриминант
## < 0 (цель дальше предела дальности при этой скорости) — крутой fallback вместо NaN.
func _solve_ballistic_high_pitch(dist_xz: float, height_diff: float) -> float:
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

# --- Визуал насадки -------------------------------------------------------------------------

## Красный цилиндр длиной в половину ствола на дульной половине Barrel. Ось цилиндра (локальный
## +Y) поворотом −90° вокруг X кладётся вдоль −Z Barrel — то же выравнивание, что у самого
## BarrelMesh в Tank.tscn.
func _build_mortar_mesh() -> void:
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

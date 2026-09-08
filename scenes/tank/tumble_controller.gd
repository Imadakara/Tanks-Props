extends Node
## TumbleController — переворот танка при падении с обрыва и самовосстановление «черепахой».
##
## ЗАЧЕМ. Корень танка — CharacterBody3D, он по проекту ВСЕГДА строго вертикален (его basis читают
## движение, наводка, yaw башни и весь бот-мозг — см. hull_rig.gd). Поэтому сам он не умеет ни
## естественно кувыркаться в воздухе, ни лежать на боку/крыше. Когда tank_movement.gd решает, что
## танк ушёл за кромку безвозвратно (центр масс вышел за опору), он передаёт управление сюда:
##
##  1. TUMBLING — на месте танка появляется НЕВИДИМЫЙ RigidBody3D-двойник с тем же коллайдером,
##     ему передаётся линейная скорость танка и закрутка «через кромку». Пока он кувыркается,
##     каждый физкадр его global_transform копируется на корень танка — весь визуал (код-броня,
##     башня, ходовая) едет за двойником, включая наклон/переворот. Родные компоненты танка на это
##     время заморожены (process_mode), коллайдер корня выключен, камера игрока отцеплена и просто
##     следит за обломком со стороны.
##  2. Двойник улёгся (скорости малы N кадров) → если палубой вверх (± _upright_cos) — сразу
##     восстановление; иначе RIGHTING.
##  3. RIGHTING — ждём self_right_cooldown_sec (параметр из config/*_tank_config.json, на будущее
##     прокачиваемый), затем кинематически доворачиваем двойника в вертикаль (yaw сохраняем,
##     небольшой подскок) и возвращаем управление CharacterBody3D.
##
## Смерть посреди кувырка (добивание уроном от падения, force_destroy на конце раунда) —
## _abort_dead(): двойник удаляется, корень остаётся там, где лёг обломок (вертикаль ему вернёт
## обычный респаун через SpawnZone.face_center). Респаун во время кувырка — _on_respawned_abort().

signal recovered  ## управление вернулось CharacterBody3D (танк снова вертикальный, компоненты живые)

## Кулдаун самопереворота, сек. Пишется из config/*_tank_config.json
## (team_spawner._apply_tank_config); дефолт-фолбэк здесь на случай отсутствия ключа/полигона.
@export var self_right_cooldown_sec: float = 3.0
## Насколько «палубой вверх» должен лежать двойник, чтобы обойтись без переворота (dot(up, +Y)).
@export var upright_cos: float = 0.82  # ~35°
## Кинематический доворот в вертикаль длится столько.
@export var right_flip_sec: float = 0.6
## Двойник считается улёгшимся, когда линейная/угловая скорость ниже порогов столько кадров подряд.
@export var settle_lin_eps: float = 0.6
@export var settle_ang_eps: float = 0.6
@export var settle_frames_needed: int = 10
## Аварийный потолок фазы TUMBLING — если двойник почему-то не унимается.
@export var tumble_max_sec: float = 6.0
## Физика двойника.
@export var proxy_mass: float = 10.0
@export var proxy_friction: float = 0.8
@export var proxy_bounce: float = 0.05
## Гашение вращения двойника. Замерено на 18-метровом падении с кухонного стола: 0.15 — танк
## почти всегда доворачивается до борта и требует переворота; 0.4+ — всегда идеально на гусеницы,
## самопереворот становится мёртвым кодом. 0.35 — середина: с нормальной траектории встаёт на
## гусеницы, а на кривом падении (зацепил кромку, упал на склон) честно ложится набок.
@export var proxy_angular_damp: float = 0.35

enum State { NONE, TUMBLING, RIGHTING }

var _state: int = State.NONE
var _body: CharacterBody3D
var _root_col: CollisionShape3D
var _health: Node
var _hull: Node
var _cam: SpringArm3D
var _proxy: RigidBody3D

var _saved_col_disabled: bool = false
var _peak_y: float = 0.0
var _tumble_time: float = 0.0
var _settle_count: int = 0
var _right_timer: float = 0.0
var _flip_t: float = 0.0
var _flip_from: Transform3D
var _flip_to: Transform3D
var _frozen_siblings: Array[Node] = []

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body == null:
		return
	_root_col = _body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	_health = _body.get_node_or_null("HealthComponent")
	_hull = _body.get_node_or_null("Hull")
	_cam = _body.get_node_or_null("CameraRig") as SpringArm3D
	var respawn: Node = _body.get_node_or_null("RespawnController")
	if respawn != null:
		respawn.respawned.connect(_on_respawned_abort)

func is_active() -> bool:
	return _state != State.NONE

## Вызывает tank_movement.gd, когда танк ушёл за кромку безвозвратно.
func start_tumble(linear_velocity: Vector3, angular_velocity: Vector3) -> void:
	if _state != State.NONE or _body == null or _root_col == null or _root_col.shape == null:
		return
	_state = State.TUMBLING
	_peak_y = _body.global_position.y
	_tumble_time = 0.0
	_settle_count = 0

	# Заморозить родные компоненты танка (тот же приём, что RespawnController._set_frozen).
	_frozen_siblings.clear()
	for sib in _body.get_children():
		if sib == self or sib == _cam:
			continue
		if sib.name == "HealthComponent" or sib.name == "RespawnController":
			continue
		sib.process_mode = Node.PROCESS_MODE_DISABLED
		_frozen_siblings.append(sib)

	# Коллайдер корня выключаем — физику ведёт двойник.
	if _root_col != null:
		_saved_col_disabled = _root_col.disabled
		_root_col.disabled = true

	# Камера игрока: НЕ отцепляем — camera_rig.gd сам плавно доводит вид к «сзади-сверху на танк»
	# и держит его, перекрывая кувыркающийся корень. Резкой смены вида нет.
	if _cam != null and _cam.is_active:
		_cam.set_tumble_follow(true)

	_spawn_proxy(linear_velocity, angular_velocity)

func _spawn_proxy(linvel: Vector3, angvel: Vector3) -> void:
	_proxy = RigidBody3D.new()
	_proxy.name = "TankTumbleProxy"
	_proxy.mass = proxy_mass
	_proxy.collision_layer = 0          # двойника никто не детектит
	_proxy.collision_mask = 1           # ...но он отталкивается от окружения (слой 1)
	_proxy.angular_damp = proxy_angular_damp
	_proxy.linear_damp = 0.0
	_proxy.can_sleep = false
	# НАСТОЯЩИЙ (низкий) центр масс танка, а не геометрический центр коллайдера. Именно он делает
	# падение «как у физического объекта»: маятник тянет корпус гусеницами вниз, и танк с приличной
	# траектории встаёт на гусеницы сам, а не гарантированно шлёпается на крышу. Берём тот же
	# center_of_mass, что и расчёт опоры в tank_movement.gd — один источник правды.
	_proxy.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	_proxy.center_of_mass = _tank_center_of_mass()
	var mat := PhysicsMaterial.new()
	mat.friction = proxy_friction
	mat.bounce = proxy_bounce
	_proxy.physics_material_override = mat
	var col := CollisionShape3D.new()
	col.shape = _root_col.shape          # тот же ConvexPolygonShape3D, что у корня
	col.transform = _root_col.transform  # ...с тем же смещением (+0.3 по Y)
	_proxy.add_child(col)
	get_tree().current_scene.add_child(_proxy)
	_proxy.global_transform = _body.global_transform
	_proxy.linear_velocity = linvel
	_proxy.angular_velocity = angvel

func _physics_process(delta: float) -> void:
	if _state == State.NONE or _proxy == null:
		return

	# Смерть посреди кувырка — оставить обломок как есть, дальше ведёт RespawnController.
	if _health != null and not _health.is_alive:
		_abort_dead()
		return

	if _state == State.RIGHTING and _right_timer <= 0.0:
		# Кинематический доворот в вертикаль.
		_flip_t = minf(_flip_t + delta / maxf(right_flip_sec, 0.01), 1.0)
		var e: float = ease(_flip_t, -2.0)  # ease-out
		_proxy.global_transform = _flip_from.interpolate_with(_flip_to, e)
		_body.global_transform = _proxy.global_transform
		if _flip_t >= 1.0:
			_recover()
		return

	# TUMBLING, либо RIGHTING в фазе ожидания кулдауна — двойник в свободной физике.
	_body.global_transform = _proxy.global_transform
	_peak_y = maxf(_peak_y, _proxy.global_position.y)

	if _state == State.RIGHTING:
		_right_timer -= delta
		if _right_timer <= 0.0:
			_begin_flip()
		return

	# _state == TUMBLING
	_tumble_time += delta
	var at_rest: bool = _proxy.linear_velocity.length() < settle_lin_eps \
		and _proxy.angular_velocity.length() < settle_ang_eps
	_settle_count = _settle_count + 1 if at_rest else 0
	if _settle_count >= settle_frames_needed or _tumble_time > tumble_max_sec:
		_on_settled()

func _on_settled() -> void:
	_apply_fall_damage(_peak_y - _proxy.global_position.y)
	if _health != null and not _health.is_alive:
		_abort_dead()
		return
	var deck_up: Vector3 = _proxy.global_transform.basis.y
	if deck_up.dot(Vector3.UP) >= upright_cos:
		_recover()
	else:
		_state = State.RIGHTING
		_right_timer = self_right_cooldown_sec

func _begin_flip() -> void:
	_proxy.freeze = true
	_proxy.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_flip_from = _proxy.global_transform
	_flip_t = 0.0
	# Цель: та же XZ, вертикальный корпус, yaw из текущего «носа» двойника, приподнять над землёй.
	var fwd: Vector3 = -_proxy.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.05:
		fwd = -_body.global_transform.basis.z  # двойник лёг ровно вверх/вниз носом — берём старый yaw
		fwd.y = 0.0
	var yaw: float = atan2(fwd.x, fwd.z) + PI
	var origin: Vector3 = _proxy.global_position
	origin.y = _ground_y(origin) + 0.35
	_flip_to = Transform3D(Basis(Vector3.UP, yaw), origin)

func _recover() -> void:
	var xf: Transform3D = _body.global_transform
	# Вертикальный корпус, yaw из текущего состояния корня (после flip он уже вертикальный).
	var fwd: Vector3 = -xf.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.05:
		fwd = Vector3.FORWARD
	var yaw: float = atan2(fwd.x, fwd.z) + PI
	var origin: Vector3 = xf.origin
	origin.y = _ground_y(origin) + 0.3
	_body.global_transform = Transform3D(Basis(Vector3.UP, yaw), origin)
	_body.velocity = Vector3.ZERO
	_teardown()
	recovered.emit()

## Смерть во время кувырка — не переворачиваем, обломок остаётся лежать; вертикаль вернёт респаун.
## Заморозку/коллайдер/цепочку компонентов НЕ трогаем — на смерти ими уже владеет RespawnController
## (_set_frozen). Только убираем двойника и свою обвязку.
func _abort_dead() -> void:
	if _proxy != null:
		_body.global_transform = _proxy.global_transform
		_proxy.queue_free()
		_proxy = null
	_frozen_siblings.clear()
	if _cam != null:
		_cam.set_tumble_follow(false)
	if _hull != null and _hull.has_method("reset_pose"):
		_hull.reset_pose()
	_state = State.NONE

## Респаун во время кувырка — корень уже телепортирован RespawnController, просто убрать двойника.
func _on_respawned_abort() -> void:
	if _state == State.NONE:
		return
	_teardown()

func _teardown() -> void:
	if _proxy != null:
		_proxy.queue_free()
		_proxy = null
	for sib in _frozen_siblings:
		if is_instance_valid(sib):
			sib.process_mode = Node.PROCESS_MODE_INHERIT
	_frozen_siblings.clear()
	if _root_col != null:
		_root_col.disabled = _saved_col_disabled
	if _cam != null:
		_cam.set_tumble_follow(false)
	if _hull != null and _hull.has_method("reset_pose"):
		_hull.reset_pose()
	_state = State.NONE

## Центр масс танка (лок.) — из TankMovement, чтобы у расчёта опоры и у физики падения он был один.
func _tank_center_of_mass() -> Vector3:
	var mv: Node = _body.get_node_or_null("TankMovement")
	if mv != null:
		return mv.center_of_mass
	return Vector3(0.0, 0.18, 0.06)

func _ground_y(from: Vector3) -> float:
	var space: PhysicsDirectSpaceState3D = _body.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from + Vector3(0, 1.5, 0), from + Vector3(0, -4.0, 0), 1)
	var hit: Dictionary = space.intersect_ray(q)
	return (hit["position"] as Vector3).y if not hit.is_empty() else from.y

func _apply_fall_damage(drop: float) -> void:
	if _health == null or drop < GameConfig.fall_damage_min_height:
		return
	var dmg: int = 1
	if drop >= GameConfig.fall_damage_3hp_height:
		dmg = 3
	elif drop >= GameConfig.fall_damage_2hp_height:
		dmg = 2
	_health.take_hit(null, dmg)

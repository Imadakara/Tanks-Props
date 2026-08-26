extends Node
## TankAIController — минимальный ИИ бота (ТЗ §9). Присутствует на КАЖДОМ Tank.tscn
## (переиспользуемая сцена), но неактивен по умолчанию (enabled=false) — включается
## только на танках-ботах. При включении берёт на себя ввод сиблингов
## (TankMovement/TurretController/WeaponController/DisguiseController), выключая их
## is_player_controlled и управляя тем же публичным контрактом, что и игрок.
##
## Поведения: Patrol/Hold (обход точек маскировки + objective-зоны), Disguise (по
## достижении слота), Observe (конус+raycast LOS, только в NORMAL — ТЗ §9.3 явно
## ограничивает наблюдение этим состоянием), Attack (доворот башни + выстрел по цели
## в дальности). Objective-aware — objective-зона включена в общий список точек обхода,
## поэтому боты естественно к ней тяготеют/патрулируют рядом.

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")
const DisguiseSlotScript := preload("res://scenes/map/disguise_slot.gd")

@export var enabled: bool = false
@export var patrol_enabled: bool = true  # false — бот стоит на месте после спавна (Observe/Attack по-прежнему активны)
@export var vision_range: float = 15.0
@export var vision_angle_deg: float = 60.0
@export var fire_range: float = 12.0
@export var fire_aim_tolerance_deg: float = 15.0
@export var disguise_chance_per_visit: float = 0.5
@export var think_interval_sec: float = 0.3
@export var waypoint_reach_dist: float = 1.0

@onready var _body: CharacterBody3D = get_parent()
@onready var _movement: Node = get_parent().get_node("TankMovement")
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _barrel: Node3D = get_parent().get_node("Turret/Barrel")
@onready var _weapon: Node = get_parent().get_node("WeaponController")
@onready var _disguise: Node = get_parent().get_node("DisguiseController")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")

var _patrol_points: Array = []
var _patrol_index: int = 0
var _target_position: Vector3 = Vector3.ZERO
var _current_target: Node = null
var _think_timer: float = 0.0
var _initialized: bool = false

## Инициализация — не в _ready(): вызывающий код обычно ставит enabled=true уже ПОСЛЕ
## add_child() (после instantiate()), а _ready() к этому моменту уже отработал бы с
## enabled=false и молча пропустил бы всю настройку. Ленивая инициализация на первом
## включённом _physics_process() не зависит от этого порядка.
func _initialize() -> void:
	_initialized = true
	_movement.is_player_controlled = false
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	_weapon.is_player_controlled = false
	_disguise.is_player_controlled = false
	_collect_patrol_points()
	if not _patrol_points.is_empty():
		_target_position = _patrol_points[0].global_position

func _collect_patrol_points() -> void:
	var map: Node = get_tree().current_scene.get_node_or_null("Map")
	if map == null:
		return
	for child in map.get_children():
		var is_disguise_or_objective: bool = child is Area3D and (child.get_script() == DisguiseSlotScript or child.has_signal("captured"))
		var is_patrol_waypoint: bool = String(child.name).begins_with("PatrolWaypoint")
		if is_disguise_or_objective or is_patrol_waypoint:
			_patrol_points.append(child)
	_patrol_points.shuffle()

func _physics_process(delta: float) -> void:
	if not enabled:
		return
	if not _initialized:
		_initialize()

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = think_interval_sec
		_think()

	if _state_machine.state != TankStateMachineScript.State.NORMAL:
		# Наблюдение/атака/патруль — только в NORMAL (ТЗ §9.3); в остальных состояниях
		# (маскировка/кулдаун/перезарядка) ИИ ничего не решает руками, только не мешает
		# собственным таймерам состояния идти своим чередом.
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return

	if _current_target != null and is_instance_valid(_current_target):
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		_aim_and_fire(_current_target)
	elif patrol_enabled:
		_drive_toward(_target_position)
	else:
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0

func _think() -> void:
	if _state_machine.state != TankStateMachineScript.State.NORMAL:
		return
	_current_target = _scan_for_target()
	if _current_target == null and patrol_enabled:
		_advance_patrol_if_needed()

func _scan_for_target() -> Node:
	for other in get_tree().get_nodes_in_group("tanks"):
		if other == _body or not is_instance_valid(other):
			continue
		if other.team == _body.team:
			continue
		var other_fsm: Node = other.get_node_or_null("TankStateMachine")
		if other_fsm == null:
			continue
		var visible_state: bool = other_fsm.state != TankStateMachineScript.State.DISGUISED or GameConfig.ai_can_see_disguised_tanks
		if not visible_state:
			continue
		if _can_see(other):
			return other
	return null

func _can_see(target: Node3D) -> bool:
	var to_target: Vector3 = target.global_position - _body.global_position
	var dist: float = to_target.length()
	if dist > vision_range or dist < 0.01:
		return false
	var forward: Vector3 = -_body.global_transform.basis.z
	var angle_deg: float = rad_to_deg(forward.angle_to(to_target.normalized()))
	if angle_deg > vision_angle_deg * 0.5:
		return false
	var space_state := _body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		_body.global_position + Vector3.UP * 0.5,
		target.global_position + Vector3.UP * 0.3
	)
	query.exclude = [_body]
	query.collision_mask = 1 | 2  # environment + tanks
	var result: Dictionary = space_state.intersect_ray(query)
	return result.is_empty() or result.get("collider") == target

func _yaw_to_world_point(from: Vector3, to_point: Vector3) -> float:
	var d: Vector3 = to_point - from
	return atan2(-d.x, -d.z)

func _aim_and_fire(target: Node3D) -> void:
	var target_yaw: float = _yaw_to_world_point(_turret.global_position, target.global_position)
	_turret.target_yaw = wrapf(target_yaw - _body.rotation.y, -PI, PI)

	var dist: float = _body.global_position.distance_to(target.global_position)
	var aim_diff_deg: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	if dist <= fire_range and aim_diff_deg <= fire_aim_tolerance_deg:
		_weapon.try_fire()

func _advance_patrol_if_needed() -> void:
	if _patrol_points.is_empty():
		return
	var wp: Node3D = _patrol_points[_patrol_index]
	if _body.global_position.distance_to(wp.global_position) < waypoint_reach_dist:
		if wp.get_script() == DisguiseSlotScript and randf() < disguise_chance_per_visit:
			_disguise.try_enter_disguise()
		_patrol_index = (_patrol_index + 1) % _patrol_points.size()
		wp = _patrol_points[_patrol_index]
	_target_position = wp.global_position

func _drive_toward(target_pos: Vector3) -> void:
	var to_target: Vector3 = target_pos - _body.global_position
	to_target.y = 0.0
	if to_target.length() < waypoint_reach_dist:
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return
	var world_yaw: float = _yaw_to_world_point(_body.global_position, target_pos)
	var yaw_diff: float = wrapf(world_yaw - _body.rotation.y, -PI, PI)
	_movement.ai_turn_input = clamp(yaw_diff / 0.5, -1.0, 1.0)
	_movement.ai_move_input = 1.0 if absf(yaw_diff) < deg_to_rad(60.0) else 0.0
	# ПРИМЕЧАНИЕ (испробовано и откачено): попытка держать move_input>0 даже при плохом
	# развороте (чтобы обойти "гашение" rotate_y() контактом, см. базу знаний Godot №37)
	# вместо избавления от залипания вызвала ХУДШИЙ эффект — при взаимном контакте нескольких
	# танков ненулевая скорость КАЖДЫЙ кадр раскачивала compounding-депенетрацию Jolt до
	# абсурдных скоростей (сотни м/с за секунды). Временное залипание на месте безопаснее
	# "взрыва" — реальный фикс (расстановка карты/избегание столкновений) остаётся в бэклоге
	# Этапа 11, см. дев-план.

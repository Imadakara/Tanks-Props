extends Node
## TankMovement — гусеничное движение танка: вперёд/назад + поворот корпуса.
## Источник ввода зависит от is_player_controlled: игрок — Input Actions, бот —
## ai_move_input/ai_turn_input, которые пишет TankAIController (единственный ИИ проекта, см.
## scenes/tank/tank_ai_controller.gd), не дублируя эту ноду отдельным путём движения.

@export var move_speed: float = 6.0
@export var acceleration: float = 12.0  # м/с² — разгон/торможение линейной скорости (не мгновенное применение)
@export var turn_speed: float = 2.0  # рад/сек
@export var is_player_controlled: bool = true

## Программный ввод для ботов — TankAIController пишет сюда каждый кадр перед тем,
## как эта нода их считает. Не используется, если is_player_controlled=true.
var ai_move_input: float = 0.0
var ai_turn_input: float = 0.0

## Последнее применённое значение move_input — читает CameraRig, чтобы обнаружить задний
## ход и плавно довернуть камеру за корму (GTA-style), не завязываясь на Input напрямую
## (актуально и для ботов, если им когда-нибудь понадобится та же логика).
var last_move_input: float = 0.0

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

var _body: CharacterBody3D
var _state_machine: Node
var _mod: Node
var _health: Node

## Урон от падения (см. _track_fall_damage). Живёт ЗДЕСЬ, а не отдельным компонентом: только этот
## узел уже владеет вертикальной скоростью/гравитацией танка и знает про is_on_floor() — отдельный
## сиблинг дублировал бы то же самое состояние. Актуально на многоуровневых картах (кухня); на
## плоских танк с высоты не падает вовсе, механика просто спит.
var _fall_peak_y: float = 0.0
var _airborne: bool = false

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	assert(_body != null, "TankMovement must be a direct child of a CharacterBody3D")
	_state_machine = get_parent().get_node_or_null("TankStateMachine")
	_mod = get_parent().get_node_or_null("ModificationController")
	_health = get_parent().get_node_or_null("HealthComponent")
	_fall_peak_y = _body.global_position.y
	# Респавн телепортирует танк (возможно, с большой высоты вниз) — без сброса отсчёта приземление
	# на своей базе засчиталось бы как падение с той высоты, где танк погиб.
	var respawn: Node = get_parent().get_node_or_null("RespawnController")
	if respawn != null:
		respawn.respawned.connect(_on_respawned)

func _on_respawned() -> void:
	_airborne = false
	_fall_peak_y = _body.global_position.y

func _physics_process(delta: float) -> void:
	var turn_input: float
	var move_input: float
	if is_player_controlled:
		turn_input = Input.get_axis("turn_left", "turn_right")
		move_input = Input.get_axis("move_backward", "move_forward")
	else:
		turn_input = ai_turn_input
		move_input = ai_move_input
	last_move_input = move_input

	# Модификация может замораживать корпус (мортира — на время прицеливания: косвенное объяснение
	# невозможности стрельбы мортирой на ходу; выход из режима по клавише движения ловит сам
	# mortar_behavior._unhandled_input, здесь только стоп).
	if _mod != null and _mod.blocks_hull_movement():
		last_move_input = 0.0
		return

	# Корпус зафиксирован во время маскировки; попытка движения — триггер
	# досрочного снятия маскировки, сам ход применяется уже следующим кадром,
	# когда состояние сменится на DISGUISE_COOLDOWN.
	if _state_machine != null and _state_machine.state == TankStateMachineScript.State.DISGUISED:
		if turn_input != 0.0 or move_input != 0.0:
			_state_machine.break_disguise("movement")
		return

	_body.rotate_y(-turn_input * turn_speed * delta)

	var forward: Vector3 = -_body.global_transform.basis.z

	if _body.is_on_floor():
		_body.velocity.y = 0.0
	else:
		_body.velocity.y -= _gravity * delta

	var target_horizontal: Vector3 = forward * move_input * move_speed
	var current_horizontal := Vector3(_body.velocity.x, 0.0, _body.velocity.z)
	var new_horizontal: Vector3 = current_horizontal.move_toward(target_horizontal, acceleration * delta)
	_body.velocity.x = new_horizontal.x
	_body.velocity.z = new_horizontal.z

	var right: Vector3 = _body.global_transform.basis.x
	var pos_before: Vector3 = _body.global_position
	_body.move_and_slide()

	# Танк — гусеничный, боком двигаться не может НИКОГДА (см. CLAUDE.md). move_and_slide()
	# при контакте с препятствием под углом штатно "съезжает" вдоль касательной поверхности —
	# нормальное поведение для персонажа, но недопустимо для танка (визуально читается как
	# скольжение бортом). Гасим боковую (вдоль right, перпендикулярно корпусу) составляющую
	# ФАКТИЧЕСКОГО смещения этого кадра — оставляем только вперёд/назад; вертикаль (гравитация/
	# пол) не трогаем, только горизонтальный снос.
	var actual_delta: Vector3 = _body.global_position - pos_before
	var lateral_delta: float = actual_delta.dot(right)
	_body.global_position -= right * lateral_delta
	_body.velocity -= right * right.dot(_body.velocity)

	_track_fall_damage()

## Урон от падения: пока танк в воздухе — копим МАКСИМАЛЬНУЮ достигнутую высоту, на приземлении
## считаем перепад от неё до точки касания. Именно перепад, а не вертикальная скорость: скорость
## после отскока/скольжения по краю площадки занижена и недооценивает реальную высоту падения.
## Порог `fall_damage_min_height` глушит мелкие отрывы на стыках пандусов (танк регулярно на кадр
## теряет опору на переломе уклона — без порога это капало бы уроном на ровном месте).
## Урон идёт через обычный take_hit(killer = null): дебаг-бессмертие его гасит (как и любой другой
## урон), а ScoreManager смерть с killer == null не засчитывает никому — падение не «убийство».
func _track_fall_damage() -> void:
	var y: float = _body.global_position.y
	if _body.is_on_floor():
		if _airborne:
			_airborne = false
			_apply_fall_damage(_fall_peak_y - y)
		_fall_peak_y = y
		return
	_airborne = true
	_fall_peak_y = maxf(_fall_peak_y, y)

func _apply_fall_damage(drop: float) -> void:
	if _health == null or drop < GameConfig.fall_damage_min_height:
		return
	var damage: int = 1
	if drop >= GameConfig.fall_damage_3hp_height:
		damage = 3
	elif drop >= GameConfig.fall_damage_2hp_height:
		damage = 2
	_health.take_hit(null, damage)

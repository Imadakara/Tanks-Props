extends Node
## TankMovement — гусеничное движение танка: вперёд/назад + поворот корпуса (ТЗ §4).
## Источник ввода зависит от is_player_controlled: игрок — Input Actions, бот —
## ai_move_input/ai_turn_input, которые пишет TankAIController (Этап 8), не дублируя
## эту ноду отдельным путём движения.

@export var move_speed: float = 6.0
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

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	assert(_body != null, "TankMovement must be a direct child of a CharacterBody3D")
	_state_machine = get_parent().get_node_or_null("TankStateMachine")

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

	# Корпус зафиксирован во время маскировки (ТЗ §6); попытка движения — триггер
	# досрочного снятия маскировки (ТЗ §5.1), сам ход применяется уже следующим кадром,
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

	_body.velocity.x = forward.x * move_input * move_speed
	_body.velocity.z = forward.z * move_input * move_speed
	_body.move_and_slide()

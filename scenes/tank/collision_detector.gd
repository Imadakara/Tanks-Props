extends Area3D
## CollisionDetector — событие «движущийся танк коснулся меня, пока я замаскирован»
## (ТЗ §5.2). Отдельная Area3D поверх CharacterBody3D-коллизии — так проще получить
## чистое событие входа, не завязываясь на move_and_slide()-механику самого тела.
## Замаскированный (неподвижный) танк не инициирует снятие сам по себе — инициатор
## только контакт с ДВИЖУЩИМСЯ телом (проверка по velocity).

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@export var moving_speed_threshold: float = 0.3

@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if body == get_parent():
		return
	if _state_machine.state != TankStateMachineScript.State.DISGUISED:
		return
	if body is CharacterBody3D and body.velocity.length() > moving_speed_threshold:
		_state_machine.break_disguise("collision")

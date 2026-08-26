extends CharacterBody3D
## Tank — корневой узел танка: хранит только принадлежность к команде (ТЗ §8.1).
## Вся остальная логика — в дочерних компонентах (TankStateMachine, TankMovement,
## WeaponController, DisguiseController, ...), это НЕ god-object.

enum Team { ATTACK, DEFENSE }

@export var team: Team = Team.ATTACK

func _ready() -> void:
	add_to_group("tanks")

func is_attacker() -> bool:
	return team == Team.ATTACK

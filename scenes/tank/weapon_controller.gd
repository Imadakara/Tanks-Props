extends Node
## WeaponController — стрельба по параболе (ТЗ §7). Направление выстрела — вперёд от
## башни (только yaw) плюс фиксированный угол возвышения; сама дуга — от гравитации
## снаряда, не от прицеливания по вертикали. Привязан к TankStateMachine.request_fire()
## (обрабатывает и обычный выстрел, и выстрел из DISGUISED) и AmmoComponent.

const ProjectileScene := preload("res://scenes/projectile/Projectile.tscn")

signal fired()

@export var is_player_controlled: bool = true
@export var launch_speed: float = 20.0
@export var launch_angle_deg: float = 35.0
@export var muzzle_forward_offset: float = 0.6
@export var muzzle_up_offset: float = 0.2

@onready var _body: Node3D = get_parent()
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _ammo: Node = get_parent().get_node("AmmoComponent")

func _unhandled_input(event: InputEvent) -> void:
	if not is_player_controlled:
		return
	if event.is_action_pressed("fire"):
		try_fire()

## Публичный вход для ботов (Этап 8) и для теста — тот же путь, что у игрока.
func try_fire() -> bool:
	if not _ammo.has_ammo():
		return false
	if not _state_machine.request_fire():
		return false
	_ammo.consume()
	_spawn_projectile()
	fired.emit()
	return true

func _spawn_projectile() -> void:
	var forward: Vector3 = -_turret.global_transform.basis.z
	var angle := deg_to_rad(launch_angle_deg)
	var direction: Vector3 = (forward * cos(angle) + Vector3.UP * sin(angle)).normalized()
	var muzzle: Vector3 = _turret.global_position + forward * muzzle_forward_offset + Vector3(0, muzzle_up_offset, 0)

	var proj := ProjectileScene.instantiate()
	get_tree().current_scene.add_child(proj)
	proj.speed = launch_speed
	proj.launch(muzzle, direction, _body)

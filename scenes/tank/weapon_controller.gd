extends Node
## WeaponController — стрельба по параболе (ТЗ §7, правка учёта наклона дула). Направление
## выстрела берётся напрямую из ориентации Barrel (yaw башни + питч дула, см.
## turret_controller.gd/barrel_controller.gd) — сама дуга по-прежнему от гравитации
## снаряда. Привязан к TankStateMachine.request_fire() (обрабатывает и обычный выстрел, и
## выстрел из DISGUISED) и AmmoComponent.

const ProjectileScene := preload("res://scenes/projectile/Projectile.tscn")

signal fired()

@export var is_player_controlled: bool = true
## Дефолт скрипта — тот же приём, что у health_component.gd's max_hits: TeamSpawner всегда
## переопределяет это из config/*_tank_config.json, но дефолт держим на уровне актуального
## баланса (текущий бот-профиль, 30.0) — на случай будущего статичного инстанса Tank.tscn в
## обход спавнера, чтобы он не откатывался молча на устаревшее число.
@export var launch_speed: float = 30.0
@export var muzzle_forward_offset: float = 0.8
@export var muzzle_up_offset: float = 0.0

@onready var _body: Node3D = get_parent()
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _barrel: Node3D = get_parent().get_node("Turret/Barrel")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _ammo: Node = get_parent().get_node("AmmoComponent")
@onready var _mod: Node = get_parent().get_node("ModificationController")

func _unhandled_input(event: InputEvent) -> void:
	if not is_player_controlled:
		return
	if not event.is_action_pressed("fire"):
		return
	# Модификация в слоте перехватывает «fire» (напр. мортира: 1-й клик — прицеливание, 2-й —
	# навесной выстрел). Пустой слот / пассивная модификация → intercepts_fire() == false.
	if _mod.intercepts_fire():
		_mod.on_fire_pressed()
		return
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
	var direction: Vector3 = -_barrel.global_transform.basis.z
	var muzzle: Vector3 = _barrel.global_position + direction * muzzle_forward_offset + Vector3(0, muzzle_up_offset, 0)

	var proj := ProjectileScene.instantiate()
	get_tree().current_scene.add_child(proj)
	proj.speed = launch_speed
	proj.launch(muzzle, direction, _body)

## Спец-выстрел модификации: расходует боеприпас и уходит в RELOAD как обычный выстрел, но летит
## по ПЕРЕДАННОМУ направлению `dir` со своими `speed`/`damage` (модификация считает их сама —
## напр. навесную дугу и урон мортиры). Очистку слота (clear_slot) делает сама модификация после
## успеха. false — нет боеприпаса / RELOAD. Общий вход: игрок и боты (через
## ModificationController → mortar_behavior._launch / ai_fire_at).
func fire_special(dir: Vector3, speed: float, damage: int) -> bool:
	if not _ammo.has_ammo():
		return false
	if not _state_machine.request_fire():
		return false
	_ammo.consume()
	var muzzle: Vector3 = _barrel.global_position
	var proj := ProjectileScene.instantiate()
	get_tree().current_scene.add_child(proj)
	proj.speed = speed
	proj.damage = damage
	proj.launch(muzzle, dir, _body)
	fired.emit()
	return true

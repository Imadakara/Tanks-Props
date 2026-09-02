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
	# Мортира в слоте — спец-выстрел НЕ в один клик (см. modification_controller.gd):
	# первый «fire» → режим прицеливания; второй «fire» (уже в режиме) → навесной выстрел.
	# Выход из режима без выстрела — по кнопке движения (ловит ModificationController).
	if _mod.current_mod != null and StringName(_mod.current_mod.id) == &"mortar":
		if _mod.is_aiming():
			_fire_mortar()
		else:
			_mod.begin_aiming()
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

## Игрок: навесной выстрел в точку кольца-прицела (ModificationController).
func _fire_mortar() -> void:
	fire_mortar_at(_mod.get_reticle_world_point())

## Навесной спец-выстрел мортиры в мировую точку `target`. Общий вход: игрок (_fire_mortar) и
## боты (tank_ai_controller.gd, State.MORTAR_ATTACK). Расходует модификацию (clear_slot) и один
## боеприпас, уходит в RELOAD как обычный выстрел. Направление — навесная дуга от дульного среза
## к target (ModificationController.mortar_launch_dir); proj.damage = mortar_objective_damage (30):
## по objective кусок из 100 HP, по любому танку one-shot. false — нет боеприпаса / RELOAD.
func fire_mortar_at(target: Vector3) -> bool:
	if not _ammo.has_ammo():
		return false
	if not _state_machine.request_fire():
		return false
	_ammo.consume()
	var muzzle: Vector3 = _barrel.global_position
	var direction: Vector3 = _mod.mortar_launch_dir(muzzle, target)
	var proj := ProjectileScene.instantiate()
	get_tree().current_scene.add_child(proj)
	proj.speed = GameConfig.mortar_launch_speed
	proj.damage = GameConfig.mortar_objective_damage
	proj.launch(muzzle, direction, _body)
	fired.emit()
	_mod.clear_slot()
	return true

extends Node
## RespawnController — респаун уничтоженного танка через GameConfig.respawn_cooldown_sec
## (пост-ревью). HealthComponent на танках больше не делает queue_free() при уничтожении
## (free_on_destroy=false, см. health_component.gd/Tank.tscn) — вместо этого танк на время
## кулдауна прячется и замораживается: process_mode=DISABLED ставится на ВСЕХ сиблингах,
## кроме HealthComponent и этого узла (иначе встал бы и сам RespawnTimer — Timer тоже Node,
## process_mode распространяется на детей), коллайдеры (корпус + CollisionDetector)
## отключаются, чтобы труп не блокировал выстрелы/движение остальных. По истечении
## кулдауна — телепорт на случайную точку спавна СВОЕЙ команды, полный сброс здоровья/
## боезапаса/состояния/подсветки подранка, снятие заморозки.
## DestructibleObjective (та же HealthComponent, другие настройки) респаун не задействует —
## free_on_destroy там остался true, сцена по-прежнему теряет объект при разрушении.

@onready var _tank: CharacterBody3D = get_parent()
@onready var _health: Node = get_parent().get_node("HealthComponent")
@onready var _ammo: Node = get_parent().get_node("AmmoComponent")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _hull_collision: CollisionShape3D = get_parent().get_node("CollisionShape3D")
@onready var _detector_collision: CollisionShape3D = get_parent().get_node("CollisionDetector/CollisionShape3D")
@onready var _respawn_timer: Timer = $RespawnTimer

func _ready() -> void:
	_respawn_timer.one_shot = true
	_respawn_timer.wait_time = GameConfig.respawn_cooldown_sec
	_respawn_timer.timeout.connect(_on_respawn_timeout)
	_health.destroyed.connect(_on_destroyed)

func _on_destroyed(_killer: Node) -> void:
	_set_frozen(true)
	_respawn_timer.start()

func _on_respawn_timeout() -> void:
	var point: Node3D = _pick_spawn_point()
	if point != null:
		_tank.global_position = point.global_position + Vector3(0, 0.3, 0)  # тот же зазор, что и у TeamSpawner — иначе провал сквозь пол
	_tank.velocity = Vector3.ZERO
	_health.current_hits = 0
	_health.is_alive = true
	_ammo.current_ammo = _ammo.max_ammo
	_ammo.ammo_changed.emit(_ammo.current_ammo, _ammo.max_ammo)
	_state_machine.force_reset()
	_tank.clear_damage_paint()
	_set_frozen(false)

func _set_frozen(frozen: bool) -> void:
	_tank.visible = not frozen
	_hull_collision.disabled = frozen
	_detector_collision.disabled = frozen
	var mode: int = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT
	for child in _tank.get_children():
		if child == self or child.name == "HealthComponent":
			continue
		child.process_mode = mode

## Случайная точка спавна СВОЕЙ команды (не противника) — та же группа маркеров, что и у
## TeamSpawner при старте матча (AttackSpawnPoint*/DefenseSpawnPoint* на Map.tscn).
func _pick_spawn_point() -> Node3D:
	var prefix: String = "AttackSpawnPoint" if _tank.is_attacker() else "DefenseSpawnPoint"
	var map: Node = get_tree().current_scene.get_node_or_null("Map")
	if map == null:
		return null
	var points: Array = []
	for child in map.get_children():
		if String(child.name).begins_with(prefix):
			points.append(child)
	if points.is_empty():
		return null
	return points[randi() % points.size()]

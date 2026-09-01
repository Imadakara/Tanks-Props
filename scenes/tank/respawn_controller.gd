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

const SpawnZoneScript := preload("res://scenes/main/spawn_zone.gd")

## [ДОБАВЛЕНО, по прямому запросу — "если атакующий objective-цель танк уничтожается, то она
## появляется сразу в стейте боя с целью на objective, такого быть не должно"] RespawnController
## сбрасывает физическое состояние танка (позиция/здоровье/боезапас/TankStateMachine), но НИЧЕГО
## не знает о AI-стейте (BotSentryController.state живёт в СОВЕРШЕННО ДРУГОМ, тестовом-песочницы
## компоненте — RespawnController общий, используется и игроком, и production TankAIController, не
## должен знать про BotSentryController напрямую, это нарушило бы разделение слоёв). Танк,
## погибший будучи в ATTACK_OBJECTIVE/DEFEND, воскресал бы С ТЕМ ЖЕ state — а ATTACK_OBJECTIVE
## вообще не пересчитывается через обычный _ensure_home_state() (в её exception-guard, ждёт, пока
## сам не разрешится) — так что бот, реально телепортированный на СВОЙ спавн (далеко от objective),
## пытался ехать/стрелять по objective НАПРЯМУЮ, минуя весь маршрут AttackWaypointN. Сигнал —
## развязка между слоями: кто угодно (BotSentryController) подписывается сам, RespawnController не
## обязан знать о его существовании.
signal respawned

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
	var zone: Node3D = _pick_spawn_zone()
	if zone != null:
		_tank.global_position = zone.pick_spawn_position() + Vector3(0, 0.3, 0)  # тот же зазор, что и у TeamSpawner — иначе провал сквозь пол
		SpawnZoneScript.face_center(_tank)
	_tank.velocity = Vector3.ZERO
	_health.current_hits = 0
	_health.is_alive = true
	_ammo.current_ammo = _ammo.max_ammo
	_ammo.ammo_changed.emit(_ammo.current_ammo, _ammo.max_ammo)
	_state_machine.force_reset()
	_tank.clear_damage_paint()
	_set_frozen(false)
	respawned.emit()

func _set_frozen(frozen: bool) -> void:
	_tank.visible = not frozen
	_hull_collision.disabled = frozen
	_detector_collision.disabled = frozen
	var mode: int = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT
	for child in _tank.get_children():
		if child == self or child.name == "HealthComponent":
			continue
		child.process_mode = mode

## Зона спавна СВОЕЙ команды (не противника) — та же `SpawnZone` (см. spawn_zone.gd), что и у
## TeamSpawner при старте матча. Рекурсивный find_child по всей сцене (не get_node("Map")) —
## работает и на продакшене (зона под "Map"), и на тестовых аренах (зона в корне, узла "Map" нет).
func _pick_spawn_zone() -> Node3D:
	var zone_name: String = "AttackSpawnZone" if _tank.is_attacker() else "DefenseSpawnZone"
	return get_tree().current_scene.find_child(zone_name, true, false)

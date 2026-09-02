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
## Objective (та же HealthComponent, другие настройки) респаун не задействует —
## free_on_destroy там остался true, сцена по-прежнему теряет объект при разрушении.

const SpawnZoneScript := preload("res://scenes/main/spawn_zone.gd")

## [ДОБАВЛЕНО, по прямому запросу — "если атакующий objective-цель танк уничтожается, то она
## появляется сразу в стейте боя с целью на objective, такого быть не должно"] RespawnController
## сбрасывает физическое состояние танка (позиция/здоровье/боезапас/TankStateMachine), но НИЧЕГО
## не знает о AI-стейте (TankAIController.state — хоть теперь и сиблинг на КАЖДОМ Tank.tscn,
## включая игрока, см. её @export enabled — RespawnController всё равно не должен знать про него
## напрямую, это нарушило бы разделение слоёв: физический респавн и AI-поведение — разная
## ответственность, даже когда оба живут на одном танке). Танк,
## погибший будучи в ATTACK_OBJECTIVE/DEFEND, воскресал бы С ТЕМ ЖЕ state — а ATTACK_OBJECTIVE
## вообще не пересчитывается через обычный _ensure_home_state() (в её exception-guard, ждёт, пока
## сам не разрешится) — так что бот, реально телепортированный на СВОЙ спавн (далеко от objective),
## пытался ехать/стрелять по objective НАПРЯМУЮ, минуя весь маршрут AttackWaypointN. Сигнал —
## развязка между слоями: кто угодно (TankAIController) подписывается сам, RespawnController не
## обязан знать о его существовании.
signal respawned

@onready var _tank: CharacterBody3D = get_parent()
@onready var _health: Node = get_parent().get_node("HealthComponent")
@onready var _ammo: Node = get_parent().get_node("AmmoComponent")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _mod: Node = get_parent().get_node("ModificationController")
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
	# Модификация теряется вместе с танком (сбросить/сохранить её нельзя, см.
	# Tank_Prop_Hunt_Modifications.md) — слот освобождается на респавне.
	_mod.clear_slot()
	_tank.clear_damage_paint()
	_set_frozen(false)
	respawned.emit()

## [ДОБАВЛЕНО, по прямому запросу — "добавь ботам стейт DEAD, отражать в дебаг-логах на экране,
## плюс время до респавна"] "TankAIController" — третье исключение из заморозки, наравне с
## HealthComponent. Без него бот, потеряв танк, тоже получал бы
## process_mode=DISABLED на свой TankAIController — его _physics_process() перестал бы
## вызываться движком вообще, а вместе с ним и обновление дебаг-лейбла: текст застревал бы на
## последнем стейте ДО смерти (например, "state: DEFEND") вместо живого "DEAD" с тикающим
## обратным отсчётом до респавна. Строковое сравнение по имени узла — тот же паттерн, что уже
## применён к "HealthComponent"; ничего не знает о самом TankAIController как о типе/скрипте.
## [АКТУАЛИЗИРОВАНО — TankAIController теперь сиблинг на КАЖДОМ Tank.tscn, включая игрока, не
## только тестовых аренах] Исключение теперь СРАБАТЫВАЕТ везде, но остаётся безопасным: узел
## остаётся дормантным, пока сам не enabled (см. её @export doc-comment) — на игроке/невключённом
## боте его "разморозка" ничего не даёт, `_physics_process()` тут же возвращается по `not enabled`.
## Сама AI-логика (сканирование,
## движение, стрельба) при этом всё равно не оживает — управляющие компоненты (TankMovement,
## WeaponController, ...) остаются в списке замораживаемых, а TankAIController сам проверяет
## `state == State.DEAD` и не совершает никаких действий, кроме обновления собственного лейбла
## (см. tank_ai_controller.gd, _think()/_physics_process()).
func _set_frozen(frozen: bool) -> void:
	_tank.visible = not frozen
	_hull_collision.disabled = frozen
	_detector_collision.disabled = frozen
	var mode: int = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT
	for child in _tank.get_children():
		if child == self or child.name == "HealthComponent" or child.name == "TankAIController":
			continue
		child.process_mode = mode

## [ДОБАВЛЕНО, по тому же запросу] Публичный геттер, не завязанный на TankAIController —
## обычная величина "сколько осталось", в том же духе, что уже сделано для сигнала `respawned`
## (RespawnController не обязан знать, кто и зачем читает эту информацию). 0.0, если таймер не
## идёт (танк жив, или ещё не запускался) — не отрицательное/произвольное число.
func time_until_respawn() -> float:
	if _respawn_timer.is_stopped():
		return 0.0
	return _respawn_timer.time_left

## Зона спавна СВОЕЙ команды (не противника) — та же `SpawnZone` (см. spawn_zone.gd), что и у
## TeamSpawner при старте матча. Рекурсивный find_child по всей сцене, не завязан на конкретную
## структуру дерева конкретной карты.
func _pick_spawn_zone() -> Node3D:
	var zone_name: String = "AttackSpawnZone" if _tank.is_attacker() else "DefenseSpawnZone"
	return get_tree().current_scene.find_child(zone_name, true, false)

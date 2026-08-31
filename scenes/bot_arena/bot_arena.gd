extends Node3D
## BotArena — точечная настройка песочницы поверх статичного дерева сцены. Тот же паттерн,
## что main.gd в основном режиме: маленький явный orchestration-скрипт в корне вместо
## разбрасывания правок по чужим _ready().
##
## - Танк игрока НЕУБИВАЕМ: обкатываем ИИ бота, respawn/смерть игрока только мешали бы.
## - Перезарядка ускорена до 1с для ВСЕХ танков этой сцены (не трогает основной режим —
##   GameConfig.reload_duration_sec переопределяется только здесь, в момент загрузки именно
##   этой сцены; TankStateMachine теперь читает его заново на каждый выстрел, а не кэширует
##   в своём _ready(), так что порядок относительно готовности танков не важен — см.
##   tank_state_machine.gd).
##
## - Переключение камер (1/2/3) — чтобы наблюдать объезд препятствий ботом, не гоняясь за ним
##   на танке от 3-го лица. "1" — обычная камера игрока (CameraRig, свободный обзор мышью,
##   как всегда); "2" — статичная камера над кластером Objective/Obstacle1-3 (сам "бутылочное
##   горлышко", где и разворачивается объезд); "3" — статичная камера сверху надо всем полем
##   (тот же приём, что используется для диагностики через godot-runtime MCP — см. skill
##   godot-mcp-testing, "закреплённая камера сверху"). ObjectiveCamera целится через look_at()
##   в _ready(), а не хардкодом Transform3D в .tscn — ручные Transform3D-литералы в .tscn
##   сериализуются построчно, а не по столбцам, и легко смотрят не туда, если считать поворот
##   как три вектора-столбца (см. кросс-проектную Godot knowledge base, п.1).

const SpawnZoneScript := preload("res://scenes/main/spawn_zone.gd")

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera
@onready var _attack_zone: Node3D = $AttackSpawnZone
@onready var _defense_zone: Node3D = $DefenseSpawnZone

## Тот же зазор, что и team_spawner.gd/respawn_controller.gd — спавн ровно НА поверхности (y
## из raycast SpawnZone.pick_spawn_position()) даёт вырожденный контакт с полом, на котором
## move_and_slide() у Jolt проваливает тело сквозь пол вместо оседания.
const _spawn_clearance := Vector3(0, 0.3, 0)

func _ready() -> void:
	$PlayerTank/HealthComponent.invincible = true
	GameConfig.reload_duration_sec = 1.0
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)
	_spawn_from_zones()

## [ДОБАВЛЕНО, по прямому запросу — "одинаковые механизмы спавна на всех картах... танк игрока
## спавнится по тем же правилам, что и танки ботов"] У этой арены нет TeamSpawner (танки —
## статичные дети .tscn, не динамически заспавненные), поэтому раздача случайных точек по зонам
## (см. spawn_zone.gd) делается здесь явно вместо хардкод-transform в самой сцене. Игрок проходит
## через ТОТ ЖЕ pick_spawn_position(), что и боты — только команда (zone) определяет, чья зона.
## get_node_or_null, не get_node: этот скрипт общий для BotArena.tscn (PlayerTank/BotTank/
## AttackBotTank) и KillerArena.tscn (только PlayerTank/BotTank, без AttackBotTank) — состав
## танков на конкретной арене не фиксирован жёстко.
func _spawn_from_zones() -> void:
	for tank_path in ["PlayerTank", "BotTank", "AttackBotTank"]:
		var tank: Node3D = get_node_or_null(tank_path)
		if tank == null:
			continue
		var zone: Node3D = _attack_zone if tank.team == 0 else _defense_zone
		tank.global_position = zone.pick_spawn_position() + _spawn_clearance
		SpawnZoneScript.face_center(tank)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_player_camera_rig.activate()
		KEY_2:
			_player_camera_rig.deactivate()
			_objective_camera.current = true
		KEY_3:
			_player_camera_rig.deactivate()
			_overview_camera.current = true

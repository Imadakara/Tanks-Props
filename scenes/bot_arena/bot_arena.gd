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

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera

func _ready() -> void:
	$PlayerTank/HealthComponent.invincible = true
	GameConfig.reload_duration_sec = 1.0
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)

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

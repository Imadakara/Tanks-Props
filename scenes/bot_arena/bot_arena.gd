extends Node3D
## BotArena — точечная настройка песочницы поверх статичного дерева сцены. Тот же паттерн,
## что main.gd в основном режиме: маленький явный orchestration-скрипт в корне вместо
## разбрасывания правок по чужим _ready().
##
## - Танк игрока НЕУБИВАЕМ: обкатываем ИИ бота, respawn/смерть игрока только мешали бы.
## - [УБРАНО, по прямому запросу — "убери оверрайд в 1 сек перезарядки для тестовой сцены, должно
##   быть всегда 3 сек"] Раньше здесь стоял `GameConfig.reload_duration_sec = 1.0`, ускоряющий
##   перезарядку только на этой сцене. Теперь арена использует общий дефолт (3.0, см.
##   autoload/game_config.gd) без переопределения — единое правило кулдауна везде, без исключений.
##
## - [ДОБАВЛЕНО, по прямому запросу — "задай тестовой карте с ботами ачиверами явный тип
##   OBJECTIVE: TARGET; сделай тестовую кнопку Objective On/Off, делающую цель бессмертной"]
##   HUD.tscn — общий prefab для всех трёх карт, его hud.gd ищет objective ПО ЖЁСТКОМУ ПУТИ
##   "Map/DestructibleObjective/HealthComponent" (продакшен-специфично — Map.tscn инстанс живёт
##   под "Map", у этой арены такого узла вообще нет, Objective лежит прямо под
##   "NavigationRegion3D"). Из-за этого ObjectiveLabel молча застревал на дефолтном тексте
##   "Objective: --" из .tscn (не баг hud.gd как такового — работает верно на Main.tscn, просто
##   не универсален). Не трогаем hud.gd/HUD.tscn (общий для продакшена, риск лишний) — вместо
##   этого здесь, зная структуру именно этой арены, находим Objective сами (та же
##   find_child("Objective", true, false), что уже использует bot_sentry_controller.gd для
##   ATTACK_OBJECTIVE) и перезаписываем ObjectiveLabel явным текстом "OBJECTIVE: TARGET — X/Y
##   попаданий" — заодно называя ТИП objective-режима (сейчас единственный, но раньше существовал
##   другой — Capture Zone, см. CLAUDE.md/vault — явное имя не будет путать при появлении второго).
##   Кнопка "Objective On/Off" — тот же паттерн, что кнопки-тумблеры bot_sentry_controller.gd
##   (_setup_reaction_toggle_button) — переключает HealthComponent.invincible на цели; текст
##   кнопки отражает текущее состояние. ТОЛЬКО тестовая фича — не появляется на Main.tscn, там
##   этого кода вообще нет.
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
@onready var _objective_label: Label = $HUD/ObjectiveLabel

var _objective_health: Node = null
var _objective_toggle_button: Button

## Тот же зазор, что и team_spawner.gd/respawn_controller.gd — спавн ровно НА поверхности (y
## из raycast SpawnZone.pick_spawn_position()) даёт вырожденный контакт с полом, на котором
## move_and_slide() у Jolt проваливает тело сквозь пол вместо оседания.
const _spawn_clearance := Vector3(0, 0.3, 0)

func _ready() -> void:
	$PlayerTank/HealthComponent.invincible = true
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)
	_spawn_from_zones()
	_setup_objective_ui()

## См. doc-comment в шапке файла. find_child, не get_node("Map/...") — эта арена не имеет узла
## "Map", Objective лежит прямо под NavigationRegion3D.
func _setup_objective_ui() -> void:
	var objective: Node = get_tree().current_scene.find_child("Objective", true, false)
	if objective == null:
		return
	_objective_health = objective.get_node_or_null("HealthComponent")
	if _objective_health == null:
		return
	_objective_health.damaged.connect(_on_objective_damaged)
	_update_objective_label(_objective_health.current_hits, _objective_health.max_hits)
	_setup_objective_toggle_button()

func _on_objective_damaged(current_hits: int, max_hits: int, _killer: Node = null) -> void:
	_update_objective_label(current_hits, max_hits)

func _update_objective_label(current_hits: int, max_hits: int) -> void:
	_objective_label.text = "OBJECTIVE: TARGET — %d/%d попаданий" % [current_hits, max_hits]

## Тот же паттерн, что кнопки-тумблеры bot_sentry_controller.gd (_setup_reaction_toggle_button) —
## отдельный CanvasLayer, не трогаем разметку HUD.tscn. Правый низ — левый низ уже занят
## reaction-toggle кнопками ботов (см. debug_ui_slot), правый верх — brain-debug панелями.
func _setup_objective_toggle_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ObjectiveToggleLayer"
	var button := Button.new()
	button.name = "ObjectiveToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -236.0
	button.offset_top = -56.0
	button.offset_right = -16.0
	button.offset_bottom = -16.0
	button.pressed.connect(_on_objective_toggle_pressed)
	layer.add_child(button)
	_objective_toggle_button = button
	# Без call_deferred, в отличие от bot_sentry_controller.gd — этот скрипт сидит на КОРНЕ сцены,
	# его _ready() уже выполняется последним (после всех детей, см. CLAUDE.md/"Scene bring-up
	# ordering"), дерево к этому моменту полностью построено.
	add_child(layer)
	_update_objective_toggle_button()

func _on_objective_toggle_pressed() -> void:
	_objective_health.invincible = not _objective_health.invincible
	_update_objective_toggle_button()

func _update_objective_toggle_button() -> void:
	_objective_toggle_button.text = "Objective: %s" % ("OFF" if _objective_health.invincible else "ON")

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

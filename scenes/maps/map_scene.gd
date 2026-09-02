extends Node3D
## MapScene — оркестрация одной игровой карты (`TargetObjectiveMap.tscn`/`TeamArenaMap.tscn`, обе —
## шаблоны игровых режимов, см. корневой CLAUDE.md "Game modes"/"Map inventory"). Маленький явный
## orchestration-скрипт в корне сцены вместо разбрасывания правок по чужим `_ready()` — тот же
## паттерн, что и остальные общие оркестраторы проекта (`TeamSpawner`, `MatchManager`).
##
## - Режим карты — `@export match_mode` на корне (задан в `.tscn`: `TargetObjectiveMap.tscn` =
##   TARGET_OBJECTIVE, `TeamArenaMap.tscn` = TEAM_ARENA), НЕ детект по наличию узла `Objective`.
##   Это «настройка карты», не строка в HUD.
## - `_setup_match_context()` заводит из кода `ScoreManager` + узел `"MatchManager"` (см.
##   `scenes/main/match_manager.gd`) — полноценный постраундовый цикл. HUD находит
##   "MatchManager"/`RoundTimer`/`FinalStageTimer` одними и теми же лукапами на любой карте.
## - Финальная стадия (доп. время после основного таймера, если бой в тупике) — ОПЦИЯ КАРТЫ:
##   `@export var final_stage_enabled`, задаётся в `.tscn`. По умолчанию вкл на `TeamArenaMap`,
##   выкл на `TargetObjectiveMap` (там время вышло → сразу победа защиты). Условие/поведение —
##   в `match_manager.gd`.
## - Кнопка "Objective On/OFF" — переключает `HealthComponent.invincible` на цели, текст отражает
##   состояние; появляется только там, где на карте вообще есть `Objective` (нет на
##   `TeamArenaMap.tscn`, режим TEAM_ARENA). Здоровье цели в HUD рисует сам `hud.gd`.
## - Переключение камер (1/2/3) — чтобы наблюдать бота от третьего лица, не гоняясь за ним на
##   собственном танке. "1" — обычная камера игрока; "2" — статичная камера над центральным
##   кластером препятствий; "3" — статичная камера сверху над всем полем (тот же приём, что
##   используется для диагностики через `godot-runtime` MCP — см. skill `godot-mcp-testing`).
##   `ObjectiveCamera` целится через `look_at()` в `_ready()`, а не хардкодом `Transform3D` в
##   `.tscn` — ручные `Transform3D`-литералы сериализуются построчно, а не по столбцам, и легко
##   смотрят не туда, если считать поворот как три вектора-столбца (см. кросс-проектную Godot
##   knowledge base, п.1).

const ScoreManagerScript := preload("res://scenes/main/score_manager.gd")
const MatchManagerScript := preload("res://scenes/main/match_manager.gd")
const ObjectiveAlertStateScript := preload("res://scenes/main/objective_alert_state.gd")

## Игровой режим карты — ЗАДАЁТСЯ В СЦЕНЕ (@export на корне: `TargetObjectiveMap.tscn` = 0,
## `TeamArenaMap.tscn` = 1), не детектится по наличию узла Objective. Значения совпадают с
## `MatchState.Mode` (0 = TARGET_OBJECTIVE, 1 = TEAM_ARENA).
@export_enum("TARGET_OBJECTIVE", "TEAM_ARENA") var match_mode: int = 0

## Опция карты: наступает ли финальная стадия (доп. время + продолжающийся сброс ящиков), когда
## основное время раунда вышло, а у всех живых танков кончился боезапас. Задаётся в .tscn каждой
## карты: TeamArenaMap = true, TargetObjectiveMap = false. Условие/логику см. match_manager.gd.
@export var final_stage_enabled: bool = false

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _player_health: Node = $PlayerTank/HealthComponent
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera
## ObjectiveAlertZone — дочерний узел самого Objective (часть его «префаба») — рекурсивный
## find_child, а не $ObjectiveAlertZone: на TeamArenaMap (TEAM_ARENA, без Objective) его нет
## вовсе → null, enemy_in_alert_zone() это переваривает.
@onready var _alert_zone: Node3D = find_child("ObjectiveAlertZone", true, false)

var _objective_health: Node = null
var _objective_toggle_button: Button
var _invincibility_toggle_button: Button

## ALERT-таймер/гео-проверка живут ЗДЕСЬ (корень сцены) — никогда не замораживаются на респавне
## отдельных ботов (в отличие от них самих, см. respawn_controller.gd), копятся РОВНО ОДИН РАЗ на
## всех, не дублируются по ботам. Каждый TankAIController читает через time_since_objective_hit()
## (см. ниже), а не хранит свою копию — "уже существующий" и "только что заспавнившийся" бот видят
## ОДНО И ТО ЖЕ значение. Логика самого таймера/гео-проверки — переиспользуемый класс
## (scenes/main/objective_alert_state.gd), этот скрипт просто владеет своим экземпляром.
var _alert_state := ObjectiveAlertStateScript.new()

## $TeamSpawner.spawn_team() встаёт ПЕРЕД _setup_match_context() — та сканирует группу "tanks"
## через ScoreManager/MatchManager.begin_match()/setup(), должна видеть уже полный состав (см.
## корневой CLAUDE.md, "Scene bring-up ordering").
func _ready() -> void:
	_setup_invincibility_toggle_button()
	$TeamSpawner.spawn_team()
	_setup_match_context()
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)
	_setup_objective_ui()

## Заводит ScoreManager/MatchManager из кода (не статичными узлами сцены — обе карты используют
## один и тот же общий оркестратор). Режим берётся из @export match_mode (задан в .tscn — «настройка
## карты»). Серию НЕ сбрасываем: она копится через reload_current_scene() между раундами; сброс —
## только из меню (main_menu.gd) и кнопкой «Новый матч» (hud.gd).
func _setup_match_context() -> void:
	MatchState.match_mode = match_mode

	var score_manager := Node.new()
	score_manager.name = "ScoreManager"
	score_manager.set_script(ScoreManagerScript)
	add_child(score_manager)
	score_manager.begin_match()  # $TeamSpawner.spawn_team() уже отработал в _ready() выше — состав в группе "tanks" полный

	var objective := get_tree().current_scene.find_child("Objective", true, false)
	var objective_health: Node = objective.get_node_or_null("HealthComponent") if objective != null else null
	var round_sec: float = GameConfig.team_arena_round_sec if match_mode == MatchState.Mode.TEAM_ARENA else GameConfig.round_timer_sec

	# Полноценный постраундовый цикл (см. match_manager.gd): TARGET_OBJECTIVE — уничтожение цели →
	# победа атаки / таймаут → победа защиты; TEAM_ARENA — таймаут → победитель по убийствам; плюс
	# опциональная финальная стадия (final_stage_enabled) — доп. время, если время вышло и боезапас
	# у всех живых танков кончился.
	var match_manager := Node.new()
	match_manager.name = "MatchManager"
	match_manager.set_script(MatchManagerScript)
	add_child(match_manager)
	match_manager.setup(match_mode, round_sec, score_manager, objective_health, final_stage_enabled)

## Бессмертие игрока — тумблер «Игрок: бессмертие ON/OFF» (низ-справа), ПО УМОЛЧАНИЮ ВКЛ. Тот же
## паттерн, что Objective On/Off и bot reaction (tank_ai_controller.gd). Низ-справа, на слот выше
## кнопки Objective On/Off (та на самом низу).
func _setup_invincibility_toggle_button() -> void:
	_player_health.invincible = true
	var layer := CanvasLayer.new()
	layer.name = "PlayerInvincibilityToggleLayer"
	var button := Button.new()
	button.name = "PlayerInvincibilityToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -236.0
	button.offset_top = -104.0
	button.offset_right = -16.0
	button.offset_bottom = -64.0
	button.pressed.connect(_on_invincibility_toggle_pressed)
	layer.add_child(button)
	_invincibility_toggle_button = button
	# Без call_deferred — этот скрипт на корне сцены, его _ready() идёт последним, дерево готово
	# (та же логика, что у _setup_objective_toggle_button).
	add_child(layer)
	_update_invincibility_toggle_button()

func _on_invincibility_toggle_pressed() -> void:
	_player_health.invincible = not _player_health.invincible
	_update_invincibility_toggle_button()

func _update_invincibility_toggle_button() -> void:
	_invincibility_toggle_button.text = "Игрок: бессмертие %s" % ("ON" if _player_health.invincible else "OFF")

func _physics_process(delta: float) -> void:
	_alert_state.tick(delta)

## Публичный геттер (не .get() на приватной var с другого скрипта) — вызывается КАЖДЫМ
## TankAIController из _ensure_home_state() вместо хранения собственной копии таймера. Тонкая
## обёртка над ObjectiveAlertState (см. её doc-comment).
func time_since_objective_hit() -> float:
	return _alert_state.time_since_hit()

## Тонкая обёртка над ObjectiveAlertState.enemy_in_zone() — is_instance_valid, не == null:
## ObjectiveAlertZone — дочерний узел Objective и освобождается ВМЕСТЕ с ним при уничтожении
## (free_on_destroy=true) — после этого _alert_zone висячая ссылка, != null, но обращаться к ней
## уже нельзя (сама проверка внутри ObjectiveAlertState тоже это учитывает — дублируем guard здесь
## только чтобы не звать метод класса на заведомо мусорной ссылке).
func enemy_in_alert_zone() -> bool:
	if not is_instance_valid(_alert_zone):
		return false
	return _alert_state.enemy_in_zone(_alert_zone, get_tree())

## Здоровье цели в HUD рисует сам hud.gd (строка под счётом раундов, только TARGET_OBJECTIVE) —
## здесь остаётся только тумблер бессмертия цели + подписка на damaged для сброса ALERT-таймера.
## find_child, не get_node("Map/..."): ни у одной карты нет промежуточного узла "Map".
func _setup_objective_ui() -> void:
	var objective: Node = get_tree().current_scene.find_child("Objective", true, false)
	if objective == null:
		return
	_objective_health = objective.get_node_or_null("HealthComponent")
	if _objective_health == null:
		return
	_objective_health.damaged.connect(_on_objective_damaged)
	# Группа "objective_health" — TankAIController ищет objective по ней, не по имени узла
	# (устраняет зависимость от конкретного имени объекта-цели для любой будущей карты).
	_objective_health.add_to_group("objective_health")
	_setup_objective_toggle_button()

func _on_objective_damaged(_current_hits: int, _max_hits: int, _killer: Node = null) -> void:
	_alert_state.reset()  # сбрасывается на КАЖДЫЙ удар, см. ObjectiveAlertState.reset()

## Тот же паттерн, что кнопки-тумблеры tank_ai_controller.gd (_setup_reaction_toggle_button) —
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
	# Без call_deferred — этот скрипт сидит на КОРНЕ сцены, его _ready() уже выполняется последним
	# (после всех детей, см. CLAUDE.md/"Scene bring-up ordering"), дерево к этому моменту полностью
	# построено.
	add_child(layer)
	_update_objective_toggle_button()

func _on_objective_toggle_pressed() -> void:
	_objective_health.invincible = not _objective_health.invincible
	_update_objective_toggle_button()

func _update_objective_toggle_button() -> void:
	_objective_toggle_button.text = "Objective: %s" % ("OFF" if _objective_health.invincible else "ON")

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

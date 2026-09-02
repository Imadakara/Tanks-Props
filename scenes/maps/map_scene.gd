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

## Опция карты: строить ли непроходимую красную границу по периметру пола (см. _build_map_borders).
## ПО УМОЛЧАНИЮ ВКЛ. Выключить имеет смысл только для карты со своими границами/геометрией края.
@export var map_border_enabled: bool = true

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
	_build_map_borders()
	_setup_invincibility_toggle_button()
	$TeamSpawner.spawn_team()
	_setup_match_context()
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)
	_setup_objective_ui()

## Непроходимая красная граница по периметру карты — 4 стены-коробки вокруг узла `Ground`.
## Строится ИЗ КОДА (не в .tscn каждой карты): размеры берутся из коллайдера `Ground`, работает
## для любой карты без ручной правки. Физическая (StaticBody3D, слой environment) — бот не может
## выехать за край, даже если driving-стек толкнёт его туда (навмеш этого не гарантирует). Танк,
## всё же оказавшийся ниже пола — принудительно убивается (respawn_controller.gd). Контейнер
## кладётся ПОД NavigationRegion3D — при ручной перепечке навмеша (см. Obstacles_Navmesh_Guide)
## стены вырежут края навмеша, и боты будут держаться от них дальше; до перепечки физическая
## стена всё равно не даёт выехать.
const _BORDER_HEIGHT := 3.0
const _BORDER_THICKNESS := 1.0

func _build_map_borders() -> void:
	if not map_border_enabled:
		return
	var ground: Node3D = find_child("Ground", true, false)
	if ground == null:
		return
	var shape: BoxShape3D = ground.get_node("CollisionShape3D").shape
	var half_x: float = shape.size.x * 0.5
	var half_z: float = shape.size.z * 0.5
	var top_y: float = ground.global_position.y + shape.size.y * 0.5  # верх пола (обычно y = 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.15, 0.05, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var container := Node3D.new()
	container.name = "MapBorders"
	ground.get_parent().add_child(container)  # под NavigationRegion3D, рядом с Ground

	var t: float = _BORDER_THICKNESS
	var span_x: float = half_x * 2.0 + t * 2.0  # длиннее пола на толщину — углы стыкуются без щели
	var span_z: float = half_z * 2.0 + t * 2.0
	# [центр по XZ, размер коробки] — внутренняя грань каждой стены заподлицо с краем Ground
	var specs := [
		[Vector2(0.0, half_z + t * 0.5), Vector3(span_x, _BORDER_HEIGHT, t)],
		[Vector2(0.0, -half_z - t * 0.5), Vector3(span_x, _BORDER_HEIGHT, t)],
		[Vector2(half_x + t * 0.5, 0.0), Vector3(t, _BORDER_HEIGHT, span_z)],
		[Vector2(-half_x - t * 0.5, 0.0), Vector3(t, _BORDER_HEIGHT, span_z)],
	]
	for i in specs.size():
		var xz: Vector2 = specs[i][0]
		var size: Vector3 = specs[i][1]
		var body := StaticBody3D.new()
		body.name = "Border%d" % (i + 1)
		body.collision_mask = 0  # стена ничего не детектит; слой оставляем дефолтный (1 = environment)
		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		var box := BoxShape3D.new()
		box.size = size
		col.shape = box
		body.add_child(col)
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "Mesh"
		var box_mesh := BoxMesh.new()
		box_mesh.size = size
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = mat
		body.add_child(mesh_inst)
		container.add_child(body)
		body.global_position = Vector3(xz.x, top_y + _BORDER_HEIGHT * 0.5, xz.y)

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

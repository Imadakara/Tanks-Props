extends Node3D
## BotArena — точечная настройка песочницы поверх статичного дерева сцены. Тот же паттерн,
## что main.gd в основном режиме: маленький явный orchestration-скрипт в корне вместо
## разбрасывания правок по чужим _ready().
##
## - Бессмертие игрока — тумблер «Игрок: бессмертие ON/OFF» (низ-справа), ПО УМОЛЧАНИЮ ВКЛ:
##   обкатываем ИИ бота, respawn/смерть игрока обычно мешают, но иногда нужно проверить и их.
##   Тот же паттерн дебаг-кнопки, что Objective On/Off и bot reaction (см. _setup_*_toggle_button).
## - Режим карты — @export match_mode на корне (задан в .tscn: BotArena = TARGET_OBJECTIVE,
##   KillerArena = TEAM_ARENA), НЕ детект по наличию узла Objective. Это «настройка карты».
## - Продакшен-MatchManager/ScoreManager у арены нет (танки — статичные инстансы, не через
##   team_spawner.gd). _setup_match_context() заводит из кода ScoreManager + узел "MatchManager"
##   со скриптом arena_match.gd на ОБЕИХ аренах — полноценный постраундовый цикл: TARGET_OBJECTIVE —
##   цель уничтожена → победа атаки / таймаут → победа защиты; TEAM_ARENA — таймаут → победитель
##   по убийствам. HUD находит "MatchManager"/RoundTimer теми же лукапами, что на продакшене.
## - [УБРАНО, по прямому запросу — "убери оверрайд в 1 сек перезарядки для тестовой сцены, должно
##   быть всегда 3 сек"] Раньше здесь стоял `GameConfig.reload_duration_sec = 1.0`, ускоряющий
##   перезарядку только на этой сцене. Теперь арена использует общий дефолт (3.0, см.
##   autoload/game_config.gd) без переопределения — единое правило кулдауна везде, без исключений.
##
## - Кнопка "Objective On/OFF" (только тестовые арены, не Main.tscn) — тот же паттерн, что
##   кнопки-тумблеры tank_ai_controller.gd (_setup_reaction_toggle_button): переключает
##   HealthComponent.invincible на цели, текст отражает состояние. Здоровье цели В HUD теперь
##   рисует сам hud.gd (строка под счётом раундов, только режим TARGET_OBJECTIVE) — раньше это
##   делалось здесь с текстом "OBJECTIVE: TARGET — X/Y", но имя режима в HUD не место (режим —
##   настройка карты, см. match_mode выше).
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
const ScoreManagerScript := preload("res://scenes/main/score_manager.gd")
const ArenaMatchScript := preload("res://scenes/bot_arena/arena_match.gd")
const ObjectiveAlertStateScript := preload("res://scenes/main/objective_alert_state.gd")

## Игровой режим карты — ЗАДАЁТСЯ В СЦЕНЕ (@export на корне: BotArena.tscn = 0, KillerArena.tscn = 1),
## не детектится по наличию узла Objective. Значения совпадают с MatchState.Mode
## (0 = TARGET_OBJECTIVE, 1 = TEAM_ARENA). Это и есть «настройка карты» — режим часть сцены,
## а не строка в HUD.
@export_enum("TARGET_OBJECTIVE", "TEAM_ARENA") var match_mode: int = 0

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _player_health: Node = $PlayerTank/HealthComponent
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera
@onready var _attack_zone: Node3D = $AttackSpawnZone
@onready var _defense_zone: Node3D = $DefenseSpawnZone
## ObjectiveAlertZone теперь дочерний узел самого Objective (часть его «префаба») — рекурсивный
## find_child, а не $ObjectiveAlertZone: на KillerArena (TEAM_ARENA, Objective удалён) его нет
## вовсе → null, enemy_in_alert_zone() это переваривает.
@onready var _alert_zone: Node3D = find_child("ObjectiveAlertZone", true, false)

var _objective_health: Node = null
var _objective_toggle_button: Button
var _invincibility_toggle_button: Button

## [ДОБАВЛЕНО, по прямому запросу — "ОБЩИЙ ALERT стейт — у уже существующих на карте И у новых
## спавнящихся"] Централизованный таймер живёт ЗДЕСЬ — BotArena (корень сцены) никогда не
## замораживается на респавне отдельных ботов (в отличие от них самих, см.
## respawn_controller.gd), копится РОВНО ОДИН РАЗ на всех, не дублируется по ботам. Каждый
## TankAIController ЧИТАЕТ его через time_since_objective_hit() (см. ниже), а не хранит свою
## копию — "уже существующий" и "только что заспавнившийся" бот видят ОДНО И ТО ЖЕ значение.
## [ПЕРЕНЕСЕНО В ObjectiveAlertState, по прямому запросу — "боты это универсальная система для
## любой карты"] Сама логика таймера/гео-проверки вынесена в переиспользуемый класс
## (scenes/main/objective_alert_state.gd) — main.gd (продакшен-оркестратор) владеет ТАКИМ ЖЕ
## экземпляром для Main.tscn, раньше этих методов там не было вообще (TankAIController жил
## только на sandbox-аренах) — живьём поймано "Nonexistent function 'time_since_objective_hit'"
## при первом прогоне после того, как этот компонент стал общим для всех карт.
var _alert_state := ObjectiveAlertStateScript.new()

## Тот же зазор, что и team_spawner.gd/respawn_controller.gd — спавн ровно НА поверхности (y
## из raycast SpawnZone.pick_spawn_position()) даёт вырожденный контакт с полом, на котором
## move_and_slide() у Jolt проваливает тело сквозь пол вместо оседания.
const _spawn_clearance := Vector3(0, 0.3, 0)

func _ready() -> void:
	_setup_invincibility_toggle_button()
	_setup_match_context()
	_objective_camera.look_at(Vector3(0, 1, -21), Vector3.UP)
	_spawn_from_zones()
	_setup_objective_ui()

## Общий контекст матча для тестовых арен: у них нет Main.tscn-овских MatchManager/ScoreManager,
## но общий HUD ждёт те же узлы — заводим их из кода. Режим берётся из @export match_mode (задан
## в .tscn — «настройка карты»). Серию НЕ сбрасываем (как и main.gd): она копится через
## reload_current_scene() между раундами; сброс — только из меню (main_menu.gd) и кнопкой
## «Новый матч» (hud.gd).
func _setup_match_context() -> void:
	MatchState.match_mode = match_mode

	var score_manager := Node.new()
	score_manager.name = "ScoreManager"
	score_manager.set_script(ScoreManagerScript)
	add_child(score_manager)
	score_manager.begin_match()  # статичные Tank-инстансы уже в группе "tanks" к моменту _ready() корня

	var objective := get_tree().current_scene.find_child("Objective", true, false)
	var objective_health: Node = objective.get_node_or_null("HealthComponent") if objective != null else null
	var round_sec: float = GameConfig.team_arena_round_sec if match_mode == MatchState.Mode.TEAM_ARENA else GameConfig.round_timer_sec

	# Полноценный постраундовый цикл на ОБЕИХ аренах (см. arena_match.gd): TARGET_OBJECTIVE —
	# уничтожение цели → победа атаки / таймаут → победа защиты; TEAM_ARENA — таймаут → победитель
	# по убийствам. Узел зовётся "MatchManager" — HUD находит его и дочерний RoundTimer теми же
	# лукапами, что на продакшене.
	var arena_match := Node.new()
	arena_match.name = "MatchManager"
	arena_match.set_script(ArenaMatchScript)
	add_child(arena_match)
	arena_match.setup(match_mode, round_sec, score_manager, objective_health)

## Бессмертие игрока на тестовой арене (чтобы смерть/respawn игрока не мешали обкатывать ИИ) —
## теперь тумблер, как Objective On/Off и bot reaction (tank_ai_controller.gd), а не хардкод в
## _ready(). ПО УМОЛЧАНИЮ ВКЛ. Низ-справа, на слот выше кнопки Objective On/Off (та на самом низу).
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
## обёртка над ObjectiveAlertState (см. её doc-comment) — имя метода то же, что и раньше, ничего в
## tank_ai_controller.gd менять не пришлось.
func time_since_objective_hit() -> float:
	return _alert_state.time_since_hit()

## Тонкая обёртка над ObjectiveAlertState.enemy_in_zone() — is_instance_valid, не == null:
## ObjectiveAlertZone теперь дочерний узел Objective и освобождается ВМЕСТЕ с ним при уничтожении
## (free_on_destroy=true) — после этого _alert_zone висячая ссылка, != null, но обращаться к ней
## уже нельзя (сама проверка внутри ObjectiveAlertState тоже это учитывает — дублируем guard здесь
## только чтобы не звать метод класса на заведомо мусорной ссылке).
func enemy_in_alert_zone() -> bool:
	if not is_instance_valid(_alert_zone):
		return false
	return _alert_state.enemy_in_zone(_alert_zone, get_tree())

## Здоровье цели в HUD рисует сам hud.gd (строка под счётом раундов, только TARGET_OBJECTIVE) —
## здесь остаётся только тестовый тумблер бессмертия цели + подписка на damaged для сброса
## ALERT-таймера. find_child, не get_node("Map/..."): у арены нет узла "Map".
func _setup_objective_ui() -> void:
	var objective: Node = get_tree().current_scene.find_child("Objective", true, false)
	if objective == null:
		return
	_objective_health = objective.get_node_or_null("HealthComponent")
	if _objective_health == null:
		return
	_objective_health.damaged.connect(_on_objective_damaged)
	# [ДОБАВЛЕНО, по прямому запросу — "боты это универсальная система для любой карты"] Та же
	# группа, что match_manager.gd проставляет на продакшене — TankAIController ищет objective
	# по ней, не по имени узла ("Objective" здесь, "DestructibleObjective" на проде).
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
	# Без call_deferred, в отличие от tank_ai_controller.gd — этот скрипт сидит на КОРНЕ сцены,
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

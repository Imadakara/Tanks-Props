extends Node3D
## BotArena — точечная настройка песочницы поверх статичного дерева сцены. Тот же паттерн,
## что main.gd в основном режиме: маленький явный orchestration-скрипт в корне вместо
## разбрасывания правок по чужим _ready().
##
## - Бессмертие игрока — тумблер «Игрок: бессмертие ON/OFF» (низ-справа), ПО УМОЛЧАНИЮ ВКЛ:
##   обкатываем ИИ бота, respawn/смерть игрока обычно мешают, но иногда нужно проверить и их.
##   Тот же паттерн дебаг-кнопки, что Objective On/Off и bot reaction (см. _setup_*_toggle_button).
## - Продакшен-MatchManager/ScoreManager у арены нет (танки — статичные инстансы, не через
##   team_spawner.gd). _setup_match_context() заводит из кода: ScoreManager всегда; в режиме
##   TEAM_ARENA (KillerArena) — ещё и узел "MatchManager" со скриптом arena_match.gd
##   (постраундовый цикл: таймер → победитель по убийствам → серия). BotArena (TARGET_OBJECTIVE) —
##   только голый RoundTimer в корне для строки HUD, без постраундового цикла.
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
const ScoreManagerScript := preload("res://scenes/main/score_manager.gd")
const ArenaMatchScript := preload("res://scenes/bot_arena/arena_match.gd")

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _player_health: Node = $PlayerTank/HealthComponent
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera
@onready var _attack_zone: Node3D = $AttackSpawnZone
@onready var _defense_zone: Node3D = $DefenseSpawnZone
@onready var _objective_label: Label = $HUD/ObjectiveLabel
## ObjectiveAlertZone теперь дочерний узел самого Objective (часть его «префаба») — рекурсивный
## find_child, а не $ObjectiveAlertZone: на KillerArena (TEAM_ARENA, Objective удалён) его нет
## вовсе → null, enemy_in_alert_zone() это переваривает.
@onready var _alert_zone: Node3D = find_child("ObjectiveAlertZone", true, false)

var _objective_health: Node = null
var _objective_toggle_button: Button
var _invincibility_toggle_button: Button
var _round_timer: Timer

## [ДОБАВЛЕНО, по прямому запросу — "ОБЩИЙ ALERT стейт — у уже существующих на карте И у новых
## спавнящихся"] Раньше каждый BotSentryController хранил СВОЙ personal-таймер тревоги
## (_time_since_objective_hit), копившийся в его СОБСТВЕННОМ _physics_process() — но пока бот
## "заморожен" на респавне (process_mode=DISABLED, см. respawn_controller.gd), его
## _physics_process() вообще не вызывается: таймер застревал на значении из момента смерти, не
## отражая реально прошедшее время. Результат — рассинхронизация: у respawn-нутого бота ALERT мог
## не сработать (или сработать неверно) независимо от того, что реально происходило с objective,
## пока он был мёртв. Централизованный таймер живёт ЗДЕСЬ — BotArena (корень сцены) никогда не
## замораживается, копится РОВНО ОДИН РАЗ на всех, не дублируется по ботам. Каждый
## BotSentryController теперь ЧИТАЕТ его через time_since_objective_hit() (см. ниже), а не хранит
## свою копию — "уже существующий" и "только что заспавнившийся" бот видят ОДНО И ТО ЖЕ значение.
## Стартует с INF ("удара никогда не было") — 0.0 читалось бы как "только что попали".
##
## [ДОБАВЛЕНО, по прямому запросу — "верни условие сброса ALERT — когда в пределах окружности
## objective нет танков противника, иначе глобальный ALERT"] Таймер остаётся ОСНОВНЫМ, надёжно
## подтверждённым живьём условием — это ДОПОЛНИТЕЛЬНЫЙ, независимый путь включения тревоги (см.
## enemy_in_alert_zone() ниже и её использование в bot_sentry_controller.gd/_ensure_home_state(),
## объединены через ИЛИ) — если враг физически внутри ObjectiveAlertZone ПРЯМО СЕЙЧАС, ALERT
## активен, даже если формальный таймер почему-то ещё не сработал/уже истёк. Централизовано здесь
## (не per-bot, как было в самой первой версии геопроверки) по той же причине, что и таймер —
## "ГЛОБАЛЬНЫЙ ALERT" по формулировке запроса, один расчёт, общий для всех защитников.
var _time_since_objective_hit: float = INF

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
## но общий HUD (верх-центр: «Раунд N/M | MM:SS» + строка счёта) ждёт те же источники — заводим
## их из кода. Режим — по наличию узла Objective (BotArena — есть → TARGET_OBJECTIVE; KillerArena —
## нет → TEAM_ARENA). Серию НЕ сбрасываем (как и main.gd): она копится через reload_current_scene()
## между раундами; сброс — только из меню (main_menu.gd) и кнопкой «Новый матч» (hud.gd).
func _setup_match_context() -> void:
	var has_objective := get_tree().current_scene.find_child("Objective", true, false) != null
	MatchState.match_mode = MatchState.Mode.TARGET_OBJECTIVE if has_objective else MatchState.Mode.TEAM_ARENA

	var score_manager := Node.new()
	score_manager.name = "ScoreManager"
	score_manager.set_script(ScoreManagerScript)
	add_child(score_manager)
	score_manager.begin_match()  # статичные Tank-инстансы уже в группе "tanks" к моменту _ready() корня

	if MatchState.match_mode == MatchState.Mode.TEAM_ARENA:
		# Полноценный постраундовый цикл (таймер → победитель по убийствам → серия). Узел зовётся
		# "MatchManager" — HUD находит его и дочерний RoundTimer теми же лукапами, что на продакшене.
		var arena_match := Node.new()
		arena_match.name = "MatchManager"
		arena_match.set_script(ArenaMatchScript)
		add_child(arena_match)
		arena_match.setup(GameConfig.team_arena_round_sec, score_manager)
	else:
		# BotArena (ачивер-песочница, TARGET_OBJECTIVE): постраундового цикла нет, RoundTimer в
		# корне только тикает для строки HUD «Раунд N/M | MM:SS».
		_round_timer = Timer.new()
		_round_timer.name = "RoundTimer"
		_round_timer.one_shot = true
		_round_timer.wait_time = GameConfig.round_timer_sec
		add_child(_round_timer)
		_round_timer.start()

## Бессмертие игрока на тестовой арене (чтобы смерть/respawn игрока не мешали обкатывать ИИ) —
## теперь тумблер, как Objective On/Off и bot reaction (bot_sentry_controller.gd), а не хардкод в
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
	_time_since_objective_hit += delta

## Публичный геттер (не .get() на приватной var с другого скрипта) — вызывается КАЖДЫМ
## BotSentryController из _ensure_home_state() вместо хранения собственной копии таймера (см.
## doc-comment у _time_since_objective_hit выше).
func time_since_objective_hit() -> float:
	return _time_since_objective_hit

## Геометрическая проверка (дистанция до центра зоны, НЕ vision/_can_see()) — тревога должна ИСКАТЬ
## противника рядом с objective сама по себе, не только по факту прошлого попадания. "Противник" —
## любой танк с is_attacker()==true (защитники "чужие" ТОЛЬКО для атакующей команды, симметрично
## тому, что использует _ensure_home_state() для определения, кто вообще подписан на тревогу).
## target.visible-фильтр — тот же паттерн, что и в _can_see() (см. bot_sentry_controller.gd) —
## убитый, ждущий respawn танк (visible=false) не считается "противником в круге".
func enemy_in_alert_zone() -> bool:
	# is_instance_valid, не == null: ObjectiveAlertZone теперь дочерний узел Objective и
	# освобождается ВМЕСТЕ с ним при уничтожении (free_on_destroy=true) — после этого _alert_zone
	# висячая ссылка, != null, но обращаться к ней уже нельзя.
	if not is_instance_valid(_alert_zone):
		return false
	var radius: float = float(_alert_zone.get("radius"))
	var zone_pos: Vector3 = _alert_zone.global_position
	for tank in get_tree().get_nodes_in_group("tanks"):
		if not is_instance_valid(tank) or not tank.is_attacker() or not tank.visible:
			continue
		var dist: float = Vector2(tank.global_position.x - zone_pos.x, tank.global_position.z - zone_pos.z).length()
		if dist <= radius:
			return true
	return false

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
	_time_since_objective_hit = 0.0  # см. doc-comment у переменной — сбрасывается на КАЖДЫЙ удар

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

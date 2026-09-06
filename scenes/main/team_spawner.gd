extends Node
## TeamSpawner — единый динамический спавнер ботов для ЛЮБОЙ карты (`TargetObjectiveMap.tscn`/
## `TeamArenaMap.tscn`, обе — шаблоны игровых режимов, см. корневой CLAUDE.md "Map inventory").
## Каждая карта держит СВОЙ узел `TeamSpawner` с этим же скриптом, отличаясь только
## `@export var roster_config_path` — тот же паттерн, что уже используют `map_scene.gd`'s
## `@export_enum var match_mode`/`spawn_zone.gd`'s переиспользуемый скрипт на разных картах.
## Динамический `instantiate()`, не статичные `.tscn`-инстансы — предпосылка для будущего сетевого
## PvP, где состав матча решается при старте, не заранее в файле сцены.
##
## Должен идти В сцене РАНЬШЕ MatchManager/ScoreManager: те сканируют группу "tanks" в своём
## `begin_match()`/`_ready()` — весь состав уже должен быть заспавнен и зарегистрирован к этому
## моменту (см. корневой CLAUDE.md, "Scene bring-up ordering").

const BotTankScene := preload("res://scenes/tank/Tank.tscn")
const SpawnZoneScript := preload("res://scenes/main/spawn_zone.gd")
const TankAIControllerScript := preload("res://scenes/tank/tank_ai_controller.gd")

## Раздельные JSON-конфиги характеристик танка игрока/ботов (скорость, ускорение, скорость
## поворота башни, начальная скорость снаряда) — вне GameConfig.gd специально: это
## параметры конкретного танка/профиля (игрок vs бот), а не общий баланс матча. Не путать с
## roster_config_path ниже — то "кто есть кто" (команда/роль/вейпоинты), это "какой физически".
const PlayerConfigPath := "res://config/player_tank_config.json"
const BotConfigPath := "res://config/bot_tank_config.json"

## Ростер ботов этой карты — массив "отрядов" (см. `_load_roster()`/`_apply_squad_to_brain()`),
## один и тот же формат/загрузчик для любой карты, разное только САМО содержимое JSON-файла на
## конкретном инстансе узла (`config/roster_target_objective.json`/`config/roster_team_arena.json`).
## Дефолт пуст намеренно — карта без явно заданного пути не должна молча спавнить чужой ростер.
@export var roster_config_path: String = ""

## Раунд закончился (см. map_scene.gd._on_round_ended_teardown) — до рестарта сцены новых ботов не
## спавним (debug-кнопки «+ Бот» становятся no-op). spawn_team() отрабатывает один раз при старте
## сцены, до конца раунда, так что его этот флаг уже не касается.
var _halted: bool = false

func halt() -> void:
	_halted = true

## Точки спавна лежат на y=0 (ровно на поверхности пола) — спавн ТОЧНО в этот y даёт
## вырожденный (нулевая глубина) контакт с полом, на котором move_and_slide() у Jolt
## ведёт себя нестабильно: тело проваливается сквозь пол вместо оседания (проверено
## эмпирически — без зазора танк падал в бесконечность уже с первых кадров, is_on_floor()
## при этом какое-то время ложно показывал true). Небольшой зазор даёт нормальное
## естественное оседание за несколько кадров.
const _spawn_clearance := Vector3(0, 0.3, 0)

## Вызывается из корневого _ready() сцены (map_scene.gd) — не из собственного _ready():
## add_child() на current_scene изнутри _ready() сиблинга падает, пока дерево ещё строится.
func spawn_team() -> void:
	# Читается из MatchState (autoload), не из @export: этот бывший @export сбрасывался бы
	# на дефолт при каждом reload_current_scene() (рестарт раунда) — а команды должны
	# меняться сторонами именно между рестартами (см. hud.gd RestartButton/_has_side_swap()).
	var player_team: int = MatchState.player_team
	var player: Node = get_tree().current_scene.get_node("PlayerTank")

	var attack_zone: Node3D = _find_spawn_zone("AttackSpawnZone")
	var defense_zone: Node3D = _find_spawn_zone("DefenseSpawnZone")
	var player_zone: Node3D = attack_zone if player_team == 0 else defense_zone

	var player_config := _load_json_config(PlayerConfigPath)
	var bot_config := _load_json_config(BotConfigPath)

	player.team = player_team
	player.apply_team_visuals()  # _ready() покрасил по дефолтной команде — перекрасить под выданную сторону
	if player_zone != null:
		player.global_position = player_zone.pick_spawn_position() + _spawn_clearance
		SpawnZoneScript.face_center(player)
	_apply_tank_config(player, player_config)

	# Состав читается из ростер-JSON (см. _load_roster()) — один и тот же путь для любой карты,
	# только счёт отряда разный: TargetObjectiveMap.tscn генерирует полные команды по
	# GameConfig.team_size, TeamArenaMap.tscn явно перечисляет 1-2 конкретных бота. "Минус один
	# слот на стороне игрока" — JSON-поле squad'а (reserve_for_player), не ветка кода.
	# Счётчик по команде (не по отряду) — сквозной, чтобы имена не повторялись, даже если у одной
	# команды несколько отрядов с разными ролями (сейчас так не бывает, но не завязываемся на это).
	# [ДОБАВЛЕНО, по прямому запросу — "галочка в меню: спавнить ботов сразу или только по
	# команде"] Читается ТОЛЬКО в debug-режиме (см. MatchState.debug_spawn_bots_on_start doc-
	# comment) — вне него всегда спавним ростер как раньше. Пропускаем ИМЕННО спавн ботов, а не
	# всю функцию: позиция/визуал/конфиг игрока выше уже настроены и должны остаться настроенными
	# независимо от этой галочки — она про ботов, не про игрока.
	if MatchState.debug_enabled and not MatchState.debug_spawn_bots_on_start:
		return

	var team_bot_counts := {}
	for squad in _load_roster(roster_config_path):
		var team: int = int(squad.get("team", 0))
		var zone: Node3D = attack_zone if team == 0 else defense_zone
		var count: int = int(squad.get("count", 0))
		if count <= 0:
			count = GameConfig.team_size  # 0/отсутствует — брать из общего баланса, не дублировать число в каждом JSON
		if bool(squad.get("reserve_for_player", false)) and team == player_team:
			count -= 1  # игрок сам занимает один слот этого отряда в этом раунде
		for i in range(count):
			team_bot_counts[team] = team_bot_counts.get(team, 0) + 1
			_spawn_bot(team, zone, bot_config, squad, team_bot_counts[team])

## [ДОБАВЛЕНО, по прямому запросу — "2 кнопки в HUD для дебаг-режима для спавна ботов (на каждую
## сторону) — клик спавнит бота"] Публичный вход для HUD: один бот заданной команды, поверх того,
## что уже есть на карте (не связано с тем, спавнился ли ростер целиком при старте — работает
## одинаково в обоих случаях, что при "спавнить сразу", что при "только по команде"). Настройки
## роли/сложности/вейпоинтов — из ПЕРВОГО отряда ростера этой команды (тот же JSON, что и обычный
## спавн, не отдельный "дебажный" набор параметров) — пустой словарь, если в ростере вообще нет
## отряда этой команды (бот тогда просто использует собственные дефолты скрипта TankAIController).
## Индекс имени — по количеству ЖИВЫХ И МЁРТВЫХ танков этой команды прямо сейчас (труп остаётся в
## группе "tanks", free_on_destroy=false, см. корневой CLAUDE.md) — уникален всегда, даже если
## кто-то уже погибал.
func spawn_one_bot(team: int) -> void:
	if _halted:
		return  # раунд закончился — новых ботов не спавним
	var zone: Node3D = _find_spawn_zone("AttackSpawnZone" if team == 0 else "DefenseSpawnZone")
	var bot_config := _load_json_config(BotConfigPath)
	var squad: Dictionary = {}
	for s in _load_roster(roster_config_path):
		if int(s.get("team", 0)) == team:
			squad = s
			break
	var index: int = 1
	for t in get_tree().get_nodes_in_group("tanks"):
		if is_instance_valid(t) and int(t.team) == team:
			index += 1
	_spawn_bot(team, zone, bot_config, squad, index)

## Ищется РЕКУРСИВНО по всей текущей сцене (find_child), не только среди прямых детей корня —
## тот же обобщённый приём, что respawn_controller.gd/tank_ai_controller.gd используют для
## поиска Ground/Objective: ни одна карта не заворачивает геометрию в промежуточный узел, но
## рекурсивный поиск не завязывается на это и остаётся корректным для любой будущей карты.
func _find_spawn_zone(node_name: String) -> Node3D:
	return get_tree().current_scene.find_child(node_name, true, false)

func _spawn_bot(team: int, zone: Node3D, config: Dictionary, squad: Dictionary, index: int) -> void:
	var bot: CharacterBody3D = BotTankScene.instantiate()
	# Дефолтное имя инстанса Tank.tscn при instantiate() — движковое "@CharacterBody3D@N" (root
	# без явно заданного unique-имени в самой сцене) — нечитаемо в дебаг-виджете бота
	# ("BOT BRAIN"-панель использует _body.name, см. tank_ai_controller.gd).
	# Явное имя по команде+порядку — до add_child(), чтобы дебаг-узлы бота уже создавались под ним.
	bot.name = "%sBot%d" % ["Attack" if team == 0 else "Defense", index]
	# CameraRig.is_active гасит Camera3D.current уже В СВОЁМ _ready() — тот срабатывает
	# синхронно ВНУТРИ add_child() (нода уже в активном дереве), раньше следующей строки.
	# Выставляем is_active=false ДО add_child(), пока бот ещё orphan (это safe — свойства
	# без обращения к глобальному transform можно ставить и вне дерева) — иначе камера
	# бота на один кадр становится current=true и перехватывает активность у игрока
	# (тот же класс бага, что был с TankAIController.enabled, см. базу знаний Godot №36).
	bot.team = team
	bot.get_node("CameraRig").is_active = false
	# [ДОБАВЛЕНО, по прямому запросу — микробаг "спавн бота дебаг-кнопкой в HUD сбрасывает активную
	# камеру на игрока, даже если была включена обзорная/objective debug-камера (клавиши 2/3)"]
	# Живьём подтверждено: сам факт add_child() новой Camera3D (внутри CameraRig нового бота) —
	# ДАЖЕ С current=false у неё самой — сбивает Viewport.get_camera_3d() движком: та камера,
	# что была активна ДО, теряет .current=true как побочный эффект входа ЛЮБОЙ новой Camera3D в
	# дерево (is_active=false строкой выше это не спасает — дело не в новой камере бота, а в самом
	# факте её появления в дереве). Фикс — запомнить активную камеру ДО add_child() и явно вернуть
	# ей current=true сразу после.
	var active_camera: Camera3D = get_viewport().get_camera_3d()
	get_tree().current_scene.add_child(bot)
	if active_camera != null:
		active_camera.current = true
	if zone != null:
		bot.global_position = zone.pick_spawn_position() + _spawn_clearance
		SpawnZoneScript.face_center(bot)
	var brain := bot.get_node("TankAIController")
	_apply_squad_to_brain(brain, squad)
	brain.enabled = true
	_apply_tank_config(bot, config)
	_notify_existing_bots_of_new_enemy(bot)

## [ДОБАВЛЕНО, по прямому запросу — регрессия "защитник перестал прятаться после килла и спада
## тревоги"] TankAIController подписывается на destroyed каждого ВРАГА, но ТОЛЬКО в момент своей
## ленивой _initialize() (первый enabled физ.тик) — снимок состава на тот момент, не подписка "на
## будущее" (см. её doc-comment). Раньше это было безопасно: весь ростер спавнился ЗА ОДИН вызов
## spawn_team(), ДО первого физ.тика любого бота — к моменту любой _initialize() состав уже полный.
## spawn_one_bot() (дебаг-кнопки HUD) это ломает — новый бот появляется ПОСЛЕ того, как остальные
## уже давно тикают. Без этого вызова боты противоположной команды, уже прошедшие _initialize(),
## никогда не подключаются к destroyed этого конкретного нового танка — убив его, они не взводят
## _kill_latch_timer, сценарий 2 маскировки на него не срабатывает. watch_enemy_destroyed()
## идемпотентна — не задваивает подписку, если бот НЕ инициализирован (сам подпишется на новичка
## при своей ленивой _initialize(), раз он уже есть в группе "tanks" к тому моменту).
func _notify_existing_bots_of_new_enemy(new_bot: Node) -> void:
	for t in get_tree().get_nodes_in_group("tanks"):
		if t == new_bot or not is_instance_valid(t) or t.team == new_bot.team:
			continue
		var brain: Node = t.get_node_or_null("TankAIController")
		if brain != null:
			brain.watch_enemy_destroyed(new_bot)

## Ростер ("кто есть кто" — команда/роль/сложность/вейпоинты/дебаг-виджеты), в отличие от
## PlayerConfigPath/BotConfigPath (физические статы, не про поведение) — тот же общий загрузчик
## для всех трёх карт. Отсутствующий файл/битый JSON/не-массив — пустой ростер: spawn_team() тогда
## просто не заспавнит ни одного бота, явно видно на скриншоте/дебаге, не тихий полу-баг с
## частичным составом.
func _load_roster(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_warning("TeamSpawner: ростер не найден: %s" % path)
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Array:
		return parsed
	push_warning("TeamSpawner: некорректный JSON-ростер в %s" % path)
	return []

## Прямой passthrough ростер-полей на TankAIController — применяется ТОЛЬКО то, что реально задано
## в конкретном squad-словаре (иначе бот использует дефолт самого скрипта, как и раньше). Явный
## список разрешённых ключей + маленькие конвертеры типов (Vector2/Vector3/enum-строка), не
## generic-присвоение через set() по произвольному ключу — опечатка в JSON тогда осталась бы
## тихо проигнорированной; так её как минимум видно по факту "поле не применилось".
func _apply_squad_to_brain(brain: Node, squad: Dictionary) -> void:
	if squad.has("role"):
		brain.role = _role_from_string(String(squad["role"]))
	if squad.has("difficulty"):
		brain.difficulty = _difficulty_from_string(String(squad["difficulty"]))
	if squad.has("waypoint_name_prefix"):
		brain.waypoint_name_prefix = String(squad["waypoint_name_prefix"])
	# [ДОБАВЛЕНО, по прямому запросу — несколько маршрутов подряд одним ботом, см.
	# TankAIController.waypoint_routes doc-comment] Массив строк-ролей в JSON — просто список,
	# конвертер типов тот же, что у остальных Array-полей ниже (hunt_area_*).
	if squad.has("waypoint_routes"):
		var routes: Array[String] = []
		for r in squad["waypoint_routes"]:
			routes.append(String(r))
		brain.waypoint_routes = routes
	if squad.has("waypoints_one_way"):
		brain.waypoints_one_way = bool(squad["waypoints_one_way"])
	if squad.has("forward_look_bias"):
		brain.forward_look_bias = float(squad["forward_look_bias"])
	if squad.has("debug_ui_slot"):
		brain.debug_ui_slot = int(squad["debug_ui_slot"])
	if squad.has("hunt_area_center"):
		var c: Array = squad["hunt_area_center"]
		brain.hunt_area_center = Vector3(float(c[0]), float(c[1]), float(c[2]))
	if squad.has("hunt_area_half_extents"):
		var e: Array = squad["hunt_area_half_extents"]
		brain.hunt_area_half_extents = Vector2(float(e[0]), float(e[1]))
	if squad.has("show_fov_debug"):
		brain.show_fov_debug = bool(squad["show_fov_debug"])
	if squad.has("show_path_debug"):
		brain.show_path_debug = bool(squad["show_path_debug"])
	if squad.has("show_brain_debug"):
		brain.show_brain_debug = bool(squad["show_brain_debug"])
	# Маскировка бота (см. vault Tank_Prop_Hunt_Disguise.md) — мастер-тумблер + по-сценарные
	# флаги/пороги. Всё дефолтно выкл, включается только тут.
	if squad.has("disguise_bot_enabled"):
		brain.disguise_bot_enabled = bool(squad["disguise_bot_enabled"])
	if squad.has("disguise_prep_timeout_sec"):
		brain.disguise_prep_timeout_sec = float(squad["disguise_prep_timeout_sec"])
	if squad.has("disguise_s1_enabled"):
		brain.disguise_s1_enabled = bool(squad["disguise_s1_enabled"])
	if squad.has("disguise_s1_predrop_window_sec"):
		brain.disguise_s1_predrop_window_sec = float(squad["disguise_s1_predrop_window_sec"])
	# [ДОБАВЛЕНО, по прямому запросу — "не всегда фиксированное окно, а от MIN до MAX случайно"]
	if squad.has("disguise_s1_predrop_window_min_sec"):
		brain.disguise_s1_predrop_window_min_sec = float(squad["disguise_s1_predrop_window_min_sec"])
	if squad.has("disguise_s1_min_round_time_left_sec"):
		brain.disguise_s1_min_round_time_left_sec = float(squad["disguise_s1_min_round_time_left_sec"])
	if squad.has("disguise_s2_enabled"):
		brain.disguise_s2_enabled = bool(squad["disguise_s2_enabled"])
	if squad.has("disguise_s2_kill_latch_ttl_sec"):
		brain.disguise_s2_kill_latch_ttl_sec = float(squad["disguise_s2_kill_latch_ttl_sec"])
	# [ДОБАВЛЕНО, по прямому запросу — "в противовес атакующим — засада защитника у зоны мортиры"]
	if squad.has("disguise_s3_enabled"):
		brain.disguise_s3_enabled = bool(squad["disguise_s3_enabled"])
	if squad.has("disguise_s3_predrop_window_min_sec"):
		brain.disguise_s3_predrop_window_min_sec = float(squad["disguise_s3_predrop_window_min_sec"])
	if squad.has("disguise_s3_predrop_window_max_sec"):
		brain.disguise_s3_predrop_window_max_sec = float(squad["disguise_s3_predrop_window_max_sec"])
	if squad.has("disguise_s3_timeout_after_drop_sec"):
		brain.disguise_s3_timeout_after_drop_sec = float(squad["disguise_s3_timeout_after_drop_sec"])

func _role_from_string(s: String) -> int:
	match s:
		"KILLER":
			return TankAIControllerScript.Role.KILLER
		"ACHIEVER":
			return TankAIControllerScript.Role.ACHIEVER
		_:
			push_warning("TeamSpawner: неизвестная role в ростере: %s" % s)
			return TankAIControllerScript.Role.ACHIEVER

func _difficulty_from_string(s: String) -> int:
	match s:
		"EASY":
			return TankAIControllerScript.Difficulty.EASY
		"MEDIUM":
			return TankAIControllerScript.Difficulty.MEDIUM
		"HARD":
			return TankAIControllerScript.Difficulty.HARD
		_:
			push_warning("TeamSpawner: неизвестная difficulty в ростере: %s" % s)
			return TankAIControllerScript.Difficulty.MEDIUM

## Читает JSON-конфиг физических характеристик танка. Отсутствующий файл/битый JSON — не критическая
## ошибка: возвращает пустой словарь, _apply_tank_config() в этом случае просто оставит
## дефолтные значения компонентов (@export в самих скриптах).
func _load_json_config(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("TeamSpawner: конфиг не найден: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	push_warning("TeamSpawner: некорректный JSON в %s" % path)
	return {}

func _apply_tank_config(tank: Node, config: Dictionary) -> void:
	if config.is_empty():
		return
	var movement: Node = tank.get_node("TankMovement")
	if config.has("move_speed"):
		movement.move_speed = float(config["move_speed"])
	if config.has("acceleration"):
		movement.acceleration = float(config["acceleration"])
	var turret: Node = tank.get_node("Turret")
	if config.has("turret_turn_speed"):
		turret.turn_speed = float(config["turret_turn_speed"])
	var weapon: Node = tank.get_node("WeaponController")
	if config.has("projectile_launch_speed"):
		weapon.launch_speed = float(config["projectile_launch_speed"])
	var health: Node = tank.get_node("HealthComponent")
	if config.has("max_hits"):
		health.max_hits = int(config["max_hits"])

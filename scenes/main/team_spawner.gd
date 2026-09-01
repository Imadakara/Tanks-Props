extends Node
## TeamSpawner — спавн полного состава 5×5: 1 игрок + 9 ботов, распределение по ролям
## атака/оборона (ТЗ §8.1, DoD #4). Роль игрока в рамках ОДНОГО раунда фиксирована — смена
## ролей между раундами реализована кнопкой рестарта в HUD: она инвертирует
## MatchState.player_team (autoload, переживает reload_current_scene()) и перезапускает
## сцену (ТЗ §8.1).
## Должен идти В Main.tscn РАНЬШЕ MatchManager/ScoreManager: те сканируют группу "tanks"
## в своём _ready(), а порядок _ready() среди siblings соответствует порядку в файле —
## к моменту их запуска весь состав уже должен быть заспавнен и зарегистрирован.
##
## [ИЗМЕНЕНО, по прямому запросу — "одинаковые механизмы спавна на всех картах... спавнер это
## зона... в радиусе спавна случайно появляются танки"] Раньше — по ОДНОЙ ФИКСИРОВАННОЙ точке
## (AttackSpawnPoint1-5/DefenseSpawnPoint1-5) на каждого танка, без вариативности и без проверки
## поверхности. Теперь — ОДНА `SpawnZone` (see spawn_zone.gd) на команду, КАЖДЫЙ танк (включая
## игрока — "по тем же правилам, что и танки ботов") получает СВОЮ случайную точку внутри неё
## через `zone.pick_spawn_position()`, который сам проверяет, что под точкой реальная земля.

const BotTankScene := preload("res://scenes/tank/Tank.tscn")
const SpawnZoneScript := preload("res://scenes/main/spawn_zone.gd")

## Раздельные JSON-конфиги характеристик танка игрока/ботов (скорость, ускорение, скорость
## поворота башни, начальная скорость снаряда) — вне GameConfig.gd специально: это
## параметры конкретного танка/профиля (игрок vs бот), а не общий баланс матча.
const PlayerConfigPath := "res://config/player_tank_config.json"
const BotConfigPath := "res://config/bot_tank_config.json"

## Точки спавна лежат на y=0 (ровно на поверхности пола) — спавн ТОЧНО в этот y даёт
## вырожденный (нулевая глубина) контакт с полом, на котором move_and_slide() у Jolt
## ведёт себя нестабильно: тело проваливается сквозь пол вместо оседания (проверено
## эмпирически — без зазора танк падал в бесконечность уже с первых кадров, is_on_floor()
## при этом какое-то время ложно показывал true). Небольшой зазор даёт нормальное
## естественное оседание за несколько кадров, как всегда было у игрока (transform.y=0.5
## в исходном Main.tscn).
const _spawn_clearance := Vector3(0, 0.3, 0)

## Вызывается из Main._ready() (см. main.gd) — не из собственного _ready(): add_child()
## на current_scene изнутри _ready() сиблинга падает, пока дерево ещё строится.
func spawn_team() -> void:
	# Читается из MatchState (autoload), не из @export: этот бывший @export сбрасывался бы
	# на дефолт при каждом reload_current_scene() (рестарт раунда) — а команды должны
	# меняться сторонами именно между рестартами (см. hud.gd RestartButton).
	var player_team: int = MatchState.player_team
	var player: Node = get_tree().current_scene.get_node("PlayerTank")

	var attack_zone: Node3D = _find_spawn_zone("AttackSpawnZone")
	var defense_zone: Node3D = _find_spawn_zone("DefenseSpawnZone")
	var player_zone: Node3D = attack_zone if player_team == 0 else defense_zone
	var opposite_zone: Node3D = defense_zone if player_team == 0 else attack_zone
	var opposite_team: int = 1 - player_team

	var player_config := _load_json_config(PlayerConfigPath)
	var bot_config := _load_json_config(BotConfigPath)

	player.team = player_team
	if player_zone != null:
		player.global_position = player_zone.pick_spawn_position() + _spawn_clearance
		SpawnZoneScript.face_center(player)
	_apply_tank_config(player, player_config)

	for i in range(1, GameConfig.team_size):
		_spawn_bot(player_team, player_zone, bot_config)

	for i in range(GameConfig.team_size):
		_spawn_bot(opposite_team, opposite_zone, bot_config)

## Ищется РЕКУРСИВНО по всей текущей сцене (find_child), не только среди прямых детей "Map" —
## тот же обобщённый приём, что respawn_controller.gd/tank_ai_controller.gd используют для
## поиска Ground/Objective, работает одинаково на продакшен-карте (зона под "Map") и на тестовых
## аренах, у которых отдельного узла "Map" вообще нет.
func _find_spawn_zone(node_name: String) -> Node3D:
	return get_tree().current_scene.find_child(node_name, true, false)

func _spawn_bot(team: int, zone: Node3D, config: Dictionary) -> void:
	var bot: CharacterBody3D = BotTankScene.instantiate()
	# CameraRig.is_active гасит Camera3D.current уже В СВОЁМ _ready() — тот срабатывает
	# синхронно ВНУТРИ add_child() (нода уже в активном дереве), раньше следующей строки.
	# Выставляем is_active=false ДО add_child(), пока бот ещё orphan (это safe — свойства
	# без обращения к глобальному transform можно ставить и вне дерева) — иначе камера
	# бота на один кадр становится current=true и перехватывает активность у игрока
	# (тот же класс бага, что был с TankAIController.enabled, см. базу знаний Godot №36).
	bot.team = team
	bot.get_node("CameraRig").is_active = false
	get_tree().current_scene.add_child(bot)
	if zone != null:
		bot.global_position = zone.pick_spawn_position() + _spawn_clearance
		SpawnZoneScript.face_center(bot)
	# [ИЗМЕНЕНО, по прямому запросу — "два набора ботов, тестовый и продакшен — путаница, должна
	# быть одна универсальная система"] Раньше здесь включался TankAIController (production-
	# эксклюзивный, минимальный ИИ без объезда препятствий) — теперь тот же TankAIController,
	# что и на тестовых аренах Bot AI (тот же узел теперь на каждом Tank.tscn, см. её @export
	# enabled doc-comment). waypoint_name_prefix/waypoints_one_way — та же связка, что уже
	# используют AttackWaypointN/DefenseWaypointN на Map.tscn (готовые маркеры от более ранней
	# работы над SpawnZone, просто раньше ни к какому AI не подключённые): атака идёт К objective
	# один раз, оборона патрулирует бесконечным кругом рядом со своим спавном.
	var brain := bot.get_node("TankAIController")
	brain.waypoint_name_prefix = "AttackWaypoint" if team == 0 else "DefenseWaypoint"
	brain.waypoints_one_way = team == 0
	# 9+ ботов с полным дебаг-виджетом (по умолчанию скрипта — true, нужно тестовым аренам как
	# есть) на продакшен-карте — нечитаемая каша поверх HUD; гасим точечно, не трогая дефолт
	# скрипта.
	brain.show_fov_debug = false
	brain.show_path_debug = false
	brain.show_brain_debug = false
	brain.show_reaction_toggle_button = false
	brain.enabled = true
	_apply_tank_config(bot, config)

## Читает JSON-конфиг характеристик танка. Отсутствующий файл/битый JSON — не критическая
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

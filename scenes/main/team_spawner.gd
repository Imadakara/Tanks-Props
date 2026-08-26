extends Node
## TeamSpawner — спавн полного состава 5×5: 1 игрок + 9 ботов, распределение по ролям
## атака/оборона (ТЗ §8.1, DoD #4). Роль игрока в рамках ОДНОГО раунда фиксирована — смена
## ролей между раундами реализована кнопкой рестарта в HUD: она инвертирует
## MatchState.player_team (autoload, переживает reload_current_scene()) и перезапускает
## сцену (ТЗ §8.1).
## Должен идти В Main.tscn РАНЬШЕ MatchManager/ScoreManager: те сканируют группу "tanks"
## в своём _ready(), а порядок _ready() среди siblings соответствует порядку в файле —
## к моменту их запуска весь состав уже должен быть заспавнен и зарегистрирован.

const BotTankScene := preload("res://scenes/tank/Tank.tscn")

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
	var map: Node = get_tree().current_scene.get_node("Map")
	var player: Node = get_tree().current_scene.get_node("PlayerTank")

	var attack_points := _collect_points(map, "AttackSpawnPoint")
	var defense_points := _collect_points(map, "DefenseSpawnPoint")

	var player_points: Array = attack_points if player_team == 0 else defense_points
	var opposite_points: Array = defense_points if player_team == 0 else attack_points
	var opposite_team: int = 1 - player_team

	var player_config := _load_json_config(PlayerConfigPath)
	var bot_config := _load_json_config(BotConfigPath)

	player.team = player_team
	if not player_points.is_empty():
		player.global_position = player_points[0].global_position + _spawn_clearance
	_apply_tank_config(player, player_config)

	for i in range(1, GameConfig.team_size):
		if i < player_points.size():
			_spawn_bot(player_team, player_points[i].global_position, bot_config)

	for i in range(GameConfig.team_size):
		if i < opposite_points.size():
			_spawn_bot(opposite_team, opposite_points[i].global_position, bot_config)

func _collect_points(map: Node, prefix: String) -> Array:
	var points: Array = []
	for child in map.get_children():
		if String(child.name).begins_with(prefix):
			points.append(child)
	return points

func _spawn_bot(team: int, pos: Vector3, config: Dictionary) -> void:
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
	bot.global_position = pos + _spawn_clearance
	var ai := bot.get_node("TankAIController")
	ai.enabled = true
	ai.patrol_enabled = false  # временно: боты стоят на месте, не бегают по вейпоинтам (см. дев-план)
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

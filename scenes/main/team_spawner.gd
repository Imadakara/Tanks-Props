extends Node
## TeamSpawner — спавн полного состава 5×5: 1 игрок + 9 ботов, распределение по ролям
## атака/оборона (ТЗ §8.1, DoD #4). Роль игрока фиксируется на весь запуск сцены — смена
## ролей между раундами реализуется рестартом сцены с другим player_team (ТЗ §8.1).
## Должен идти В Main.tscn РАНЬШЕ MatchManager/ScoreManager: те сканируют группу "tanks"
## в своём _ready(), а порядок _ready() среди siblings соответствует порядку в файле —
## к моменту их запуска весь состав уже должен быть заспавнен и зарегистрирован.

const BotTankScene := preload("res://scenes/tank/Tank.tscn")

@export var player_team: int = 0  # 0 = Tank.Team.ATTACK, 1 = Tank.Team.DEFENSE

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
	var map: Node = get_tree().current_scene.get_node("Map")
	var player: Node = get_tree().current_scene.get_node("PlayerTank")

	var attack_points := _collect_points(map, "AttackSpawnPoint")
	var defense_points := _collect_points(map, "DefenseSpawnPoint")

	var player_points: Array = attack_points if player_team == 0 else defense_points
	var opposite_points: Array = defense_points if player_team == 0 else attack_points
	var opposite_team: int = 1 - player_team

	player.team = player_team
	if not player_points.is_empty():
		player.global_position = player_points[0].global_position + _spawn_clearance

	for i in range(1, GameConfig.team_size):
		if i < player_points.size():
			_spawn_bot(player_team, player_points[i].global_position)

	for i in range(GameConfig.team_size):
		if i < opposite_points.size():
			_spawn_bot(opposite_team, opposite_points[i].global_position)

func _collect_points(map: Node, prefix: String) -> Array:
	var points: Array = []
	for child in map.get_children():
		if String(child.name).begins_with(prefix):
			points.append(child)
	return points

func _spawn_bot(team: int, pos: Vector3) -> void:
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

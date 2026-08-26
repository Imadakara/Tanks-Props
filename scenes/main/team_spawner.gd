extends Node
## TeamSpawner — спавн полного состава 5×5: 1 игрок + 9 ботов, распределение по ролям
## атака/оборона (ТЗ §8.1, DoD #4). Роль игрока фиксируется на весь запуск сцены — смена
## ролей между раундами реализуется рестартом сцены с другим player_team (ТЗ §8.1).
## Должен идти В Main.tscn РАНЬШЕ MatchManager/ScoreManager: те сканируют группу "tanks"
## в своём _ready(), а порядок _ready() среди siblings соответствует порядку в файле —
## к моменту их запуска весь состав уже должен быть заспавнен и зарегистрирован.

const BotTankScene := preload("res://scenes/tank/Tank.tscn")

@export var player_team: int = 0  # 0 = Tank.Team.ATTACK, 1 = Tank.Team.DEFENSE

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
		player.global_position = player_points[0].global_position

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
	get_tree().current_scene.add_child(bot)
	bot.team = team
	bot.global_position = pos
	bot.get_node("TankAIController").enabled = true
	bot.get_node("CameraRig").is_active = false

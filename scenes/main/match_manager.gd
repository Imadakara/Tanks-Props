extends Node
## MatchManager — таймер раунда, objective и финальная стадия (ТЗ §8.1-§8.4).

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

@onready var _round_timer: Timer = $RoundTimer
@onready var _final_stage_timer: Timer = $FinalStageTimer
@onready var _objective: Node = get_tree().current_scene.get_node_or_null("Map/ObjectiveZone")

var _round_over: bool = false
var _final_stage_active: bool = false
var _depleted_tanks: Array = []
var _total_tanks: int = 0

## Вызывается из Main._ready() (см. main.gd), ПОСЛЕ TeamSpawner.spawn_team() — сканирует
## группу "tanks", которая должна быть уже полностью заспавнена к этому моменту.
func begin_match() -> void:
	_round_timer.one_shot = true
	_round_timer.wait_time = GameConfig.round_timer_sec
	_round_timer.timeout.connect(_on_round_timeout)
	_round_timer.start()

	_final_stage_timer.one_shot = true
	_final_stage_timer.wait_time = GameConfig.final_stage_duration_sec
	_final_stage_timer.timeout.connect(_on_final_stage_timeout)

	if _objective != null:
		_objective.captured.connect(_on_objective_captured)

	var tanks := get_tree().get_nodes_in_group("tanks")
	_total_tanks = tanks.size()
	for tank in tanks:
		var ammo: Node = tank.get_node_or_null("AmmoComponent")
		if ammo != null:
			ammo.ammo_depleted.connect(_on_tank_ammo_depleted.bind(tank))

func _on_tank_ammo_depleted(tank: Node) -> void:
	if _final_stage_active or _round_over:
		return
	if not _depleted_tanks.has(tank):
		_depleted_tanks.append(tank)
	if _total_tanks > 0 and _depleted_tanks.size() >= _total_tanks:
		_start_final_stage()

func _start_final_stage() -> void:
	_final_stage_active = true
	_round_timer.stop()  # финальная стадия наступает независимо от таймера раунда (ТЗ §8.4)
	final_stage_started.emit()
	_final_stage_timer.start()
	_spawn_ammo_crates()

func _spawn_ammo_crates() -> void:
	var map: Node = get_tree().current_scene.get_node_or_null("Map")
	if map == null:
		return
	var spawn_points: Array = []
	for child in map.get_children():
		if String(child.name).begins_with("AmmoCrateSpawnPoint"):
			spawn_points.append(child)
	spawn_points.shuffle()
	var count: int = min(GameConfig.ammo_crate_count, spawn_points.size())
	var crate_scene: PackedScene = load("res://scenes/ammo_crate/AmmoCrate.tscn")
	for i in range(count):
		var crate: Node3D = crate_scene.instantiate()
		map.add_child(crate)
		crate.global_position = spawn_points[i].global_position

func _on_objective_captured() -> void:
	_end_round("attack")

func _on_round_timeout() -> void:
	if _final_stage_active:
		return
	_end_round("defense")

func _on_final_stage_timeout() -> void:
	if _round_over:
		return
	var sm: Node = get_tree().current_scene.get_node_or_null("ScoreManager")
	if sm == null:
		_end_round("defense")
		return
	if sm.attack_kills > sm.defense_kills:
		_end_round("attack")
	elif sm.defense_kills > sm.attack_kills:
		_end_round("defense")
	else:
		_end_round("defense" if GameConfig.defense_wins_ties else "attack")

func _end_round(winner: String) -> void:
	if _round_over:
		return
	_round_over = true
	_round_timer.stop()
	_final_stage_timer.stop()
	round_ended.emit(winner)

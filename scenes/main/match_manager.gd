extends Node
## MatchManager — таймер раунда, objective и финальная стадия (ТЗ §8.1-§8.4).
## Режим objective — "Destroy Target" (см. документацию «Игровые режимы» в vault):
## атака уничтожает DestructibleObjective в центре карты за GameConfig.objective_hits_required
## попаданий (только атака — HealthComponent.attackers_only=true, см. health_component.gd);
## оборона побеждает по истечении таймера раунда, если объект уцелел.
## Ammo crate (пост-ревью) — CrateSpawnTimer каждые ammo_crate_spawn_interval_sec спавнит
## ящик в случайной свободной точке поля (не в фикс. точках, как раньше), пока на поле не
## накопится ammo_crate_count непобранных штук; работает весь раунд, включая финальную стадию.

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

@onready var _round_timer: Timer = $RoundTimer
@onready var _final_stage_timer: Timer = $FinalStageTimer
@onready var _crate_spawn_timer: Timer = $CrateSpawnTimer
@onready var _objective_health: Node = get_tree().current_scene.get_node_or_null("Map/DestructibleObjective/HealthComponent")

const AmmoCrateScene := preload("res://scenes/ammo_crate/AmmoCrate.tscn")

## Ящик спавнится в случайной точке поля (не в фикс. точках — пост-ревью, было 4 фикс.
## точки на финальной стадии). Половина стороны игрового поля (Ground 60×60 с центром в
## начале координат, см. Map.tscn) минус запас от края/стен по периметру у спавнов команд.
const _field_half_extent: float = 25.0
# radius > полудиагонали ящика (0.6³ → ~0.52), но y-radius < _crate_spawn_y, иначе сфера-проба
# ниже y=0 задевает Ground (потолок его коллайдера ровно в y=0) и ложно блокирует ВСЮ карту —
# ровно так и вскрылось на первом прогоне (0 успешных размещений из 20 попыток подряд).
const _crate_clearance_radius: float = 0.6
const _crate_spawn_y: float = 0.8
const _max_placement_attempts: int = 20
const _crate_probe_mask: int = 35  # environment(1) | tanks(2) | ammo_crates(32) — не мимо стен/танков/других ящиков

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

	if _objective_health != null:
		_objective_health.max_hits = GameConfig.objective_hits_required
		_objective_health.attackers_only = true  # оборона не должна вредить цели
		_objective_health.destroyed.connect(_on_objective_destroyed)

	_crate_spawn_timer.one_shot = false
	_crate_spawn_timer.wait_time = GameConfig.ammo_crate_spawn_interval_sec
	_crate_spawn_timer.timeout.connect(_on_crate_spawn_timeout)
	_crate_spawn_timer.start()

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
	# CrateSpawnTimer НЕ трогаем — ящики продолжают появляться каждые ammo_crate_spawn_interval_sec
	# и во время финальной стадии, тем же периодическим механизмом (см. begin_match()).

func _on_crate_spawn_timeout() -> void:
	if _round_over:
		return
	if get_tree().get_nodes_in_group("ammo_crates").size() >= GameConfig.ammo_crate_count:
		return  # на поле уже максимум одновременно не подобранных ящиков — пропускаем тик
	var map: Node = get_tree().current_scene.get_node_or_null("Map")
	if map == null:
		return
	var pos = _find_free_crate_position(map)
	if pos == null:
		return  # за _max_placement_attempts не нашли свободное место — попробуем на следующем тике
	var crate: Node3D = AmmoCrateScene.instantiate()
	map.add_child(crate)
	crate.global_position = pos

## Случайная точка в пределах поля, где ящик не окажется внутри стены/дома/танка/другого
## ящика (иначе танк физически не сможет его подобрать) — проверяется сферическим
## physics-запросом radius=_crate_clearance_radius по слоям environment/tanks/ammo_crates.
func _find_free_crate_position(map: Node3D) -> Variant:
	var space := map.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var probe := SphereShape3D.new()
	probe.radius = _crate_clearance_radius
	query.shape = probe
	query.collision_mask = _crate_probe_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	for i in range(_max_placement_attempts):
		var candidate := Vector3(
			randf_range(-_field_half_extent, _field_half_extent),
			_crate_spawn_y,
			randf_range(-_field_half_extent, _field_half_extent)
		)
		query.transform = Transform3D(Basis(), candidate)
		var overlaps: Array = space.intersect_shape(query, 1)
		if overlaps.is_empty():
			return candidate
	return null

func _on_objective_destroyed(_killer: Node) -> void:
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
	_crate_spawn_timer.stop()
	MatchState.record_round_result(winner)  # засчитываем раунд в серию ДО того, как HUD её прочитает
	round_ended.emit(winner)

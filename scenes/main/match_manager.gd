extends Node
## MatchManager — постраундовый цикл, единый для любой карты (обе игровые карты — шаблоны режимов
## TARGET_OBJECTIVE/TEAM_ARENA, см. корневой CLAUDE.md "Game modes"). `map_scene.gd._setup_match_context()`
## заводит этот узел из кода под именем "MatchManager" на КАЖДОЙ карте — HUD находит его и его
## дочерние `RoundTimer`/`FinalStageTimer` одними и теми же `get_node_or_null(...)`-лукапами
## независимо от карты.
##
## Условие конца раунда — по режиму карты (`MatchState.match_mode`, задаётся в настройках сцены):
## - TARGET_OBJECTIVE: `HealthComponent.destroyed` цели → победа АТАКИ; `RoundTimer` истёк, цель
##   цела → победа ЗАЩИТЫ.
## - TEAM_ARENA: `RoundTimer` истёк → победитель по числу убийств (`ScoreManager`), ничья по
##   `GameConfig.defense_wins_ties` (`_winner_by_kills()`).
## Результат раунда пишется в серию `MatchState.record_round_result()` ДО эмита `round_ended`,
## чтобы HUD прочитал уже актуальный счёт. Следующий раунд/новый матч — кнопкой в HUD (reload
## сцены), серия копится через autoload.
##
## Финальная стадия — досрочное завершение раунда, если у ВСЕХ танков сразу кончился боезапас
## (дальше в этом раунде обеим командам физически нечем продолжать бой). `GameConfig.
## final_stage_duration_sec` (30с) — грейс-период, в течение которого HUD показывает обратный
## отсчёт (`FinalStageLabel`, `hud.gd._update_final_stage_label()`); по истечении раунд решается
## `_winner_by_kills()` — той же формулой, что и обычный таймаут TEAM_ARENA (для TEAM_ARENA
## финальная стадия — не отдельная механика, а тот же исход раунда, наступивший раньше срока; для
## TARGET_OBJECTIVE — единственный способ разрешить стадию, когда добить/удержать objective больше
## нечем).

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

var _final_stage_active: bool = false
var _round_over: bool = false
var _mode: int = 0  # MatchState.Mode; всегда перезаписывается в setup() до первого использования
var _round_timer: Timer
var _final_stage_timer: Timer
var _score_manager: Node
var _depleted_tanks: Array = []
var _total_tanks: int = 0

## Вызывается из map_scene.gd._setup_match_context() сразу после add_child() — не _ready(): явным
## вызовом из оркестратора в корне сцены, тот же порядок, что и у ScoreManager.begin_match().
## objective_health = null для режима TEAM_ARENA (цели на карте нет).
func setup(mode: int, round_sec: float, score_manager: Node, objective_health: Node) -> void:
	_mode = mode
	_score_manager = score_manager

	_round_timer = Timer.new()
	_round_timer.name = "RoundTimer"
	_round_timer.one_shot = true
	_round_timer.wait_time = round_sec
	add_child(_round_timer)
	_round_timer.timeout.connect(_on_round_timeout)
	_round_timer.start()

	if objective_health != null:
		objective_health.max_hits = GameConfig.objective_hits_required
	if _mode == MatchState.Mode.TARGET_OBJECTIVE and objective_health != null:
		objective_health.destroyed.connect(_on_objective_destroyed)

	var tanks := get_tree().get_nodes_in_group("tanks")
	_total_tanks = tanks.size()
	for tank in tanks:
		var ammo: Node = tank.get_node_or_null("AmmoComponent")
		if ammo != null:
			ammo.ammo_depleted.connect(_on_tank_ammo_depleted.bind(tank))

func _on_objective_destroyed(_killer: Node) -> void:
	_end_round("attack")  # цель уничтожена — победа атакующих

func _on_round_timeout() -> void:
	if _final_stage_active:
		return  # финальная стадия уже идёт своим отдельным таймером — обычный таймаут не решает
	if _mode == MatchState.Mode.TEAM_ARENA:
		_end_round(_winner_by_kills())
	else:
		_end_round("defense")  # цель уцелела к концу таймера — победа защиты

func _on_tank_ammo_depleted(tank: Node) -> void:
	if _final_stage_active or _round_over:
		return
	if not _depleted_tanks.has(tank):
		_depleted_tanks.append(tank)
	if _total_tanks > 0 and _depleted_tanks.size() >= _total_tanks:
		_start_final_stage()

func _start_final_stage() -> void:
	_final_stage_active = true
	_round_timer.stop()  # финальная стадия наступает независимо от таймера раунда
	_final_stage_timer = Timer.new()
	_final_stage_timer.name = "FinalStageTimer"
	_final_stage_timer.one_shot = true
	_final_stage_timer.wait_time = GameConfig.final_stage_duration_sec
	add_child(_final_stage_timer)
	_final_stage_timer.timeout.connect(_on_final_stage_timeout)
	final_stage_started.emit()
	_final_stage_timer.start()

func _on_final_stage_timeout() -> void:
	_end_round(_winner_by_kills())

## Общая формула для обоих режимов: обычный таймаут TEAM_ARENA и финальная стадия любого режима
## решают раунд одинаково — по числу убийств, ничья по GameConfig.defense_wins_ties.
func _winner_by_kills() -> String:
	var atk: int = _score_manager.attack_kills
	var def: int = _score_manager.defense_kills
	if atk > def:
		return "attack"
	if def > atk:
		return "defense"
	return "defense" if GameConfig.defense_wins_ties else "attack"

func _end_round(winner: String) -> void:
	if _round_over:
		return
	_round_over = true
	_round_timer.stop()
	if _final_stage_timer != null:
		_final_stage_timer.stop()
	MatchState.record_round_result(winner)  # засчитываем раунд в серию ДО того, как HUD её прочитает
	round_ended.emit(winner)

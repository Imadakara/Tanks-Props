extends Node
## ArenaMatch — постраундовый цикл для тестовых арен (BotArena / KillerArena). У арен нет
## продакшен-MatchManager (тот завязан на Map/ammo-crate/финальную стадию), поэтому
## bot_arena.gd._setup_match_context() заводит ЭТОТ узел из кода под именем "MatchManager".
## HUD находит его и его дочерний RoundTimer теми же get_node_or_null("MatchManager") /
## ("MatchManager/RoundTimer"), что и на продакшене — hud.gd под арену не меняется.
##
## Условие конца раунда — по режиму карты (MatchState.match_mode, задаётся в настройках сцены):
## - TARGET_OBJECTIVE: HealthComponent.destroyed цели → победа АТАКИ; RoundTimer истёк, цель цела →
##   победа ЗАЩИТЫ (та же пара условий, что у продакшен-match_manager.gd).
## - TEAM_ARENA: RoundTimer истёк → победитель по числу убийств (ScoreManager); ничья по
##   GameConfig.defense_wins_ties, как в продакшен-финалке.
## Результат раунда пишется в серию MatchState.record_round_result() ДО эмита round_ended,
## чтобы HUD прочитал уже актуальный счёт (тот же порядок, что в match_manager.gd). Следующий
## раунд / новый матч — кнопкой в HUD (reload сцены), серия копится через autoload.
##
## final_stage_started/_final_stage_active существуют только для совместимости с hud.gd
## (он их читает безусловно) — на арене финальная стадия не наступает никогда.

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

var _final_stage_active: bool = false  # всегда false на арене; hud.gd читает это поле
var _round_over: bool = false
var _mode: int = 0  # MatchState.Mode; всегда перезаписывается в setup() до первого использования
var _round_timer: Timer
var _score_manager: Node

## Вызывается из bot_arena.gd._setup_match_context() сразу после add_child() — не _ready():
## так же, как ScoreManager.begin_match() и продакшен-MatchManager.begin_match(), явным вызовом
## из оркестратора в корне сцены, а не из собственного _ready(). objective_health = null для
## режима TEAM_ARENA (цели на карте нет).
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

	if _mode == MatchState.Mode.TARGET_OBJECTIVE and objective_health != null:
		objective_health.destroyed.connect(_on_objective_destroyed)

func _on_objective_destroyed(_killer: Node) -> void:
	_end_round("attack")  # цель уничтожена — победа атакующих

func _on_round_timeout() -> void:
	if _mode == MatchState.Mode.TEAM_ARENA:
		_end_round(_winner_by_kills())
	else:
		_end_round("defense")  # цель уцелела к концу таймера — победа защиты

## Та же логика ничьей, что у продакшен-MatchManager._on_final_stage_timeout().
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
	MatchState.record_round_result(winner)  # засчитываем раунд в серию ДО того, как HUD её прочитает
	round_ended.emit(winner)

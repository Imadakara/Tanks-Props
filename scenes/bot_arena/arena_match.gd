extends Node
## ArenaMatch — постраундовый цикл для тестовых арен в режиме TEAM_ARENA (KillerArena.tscn).
## У арен нет продакшен-MatchManager (тот завязан на Map/objective/ammo-crate/финальную стадию),
## поэтому bot_arena.gd._setup_match_context() заводит ЭТОТ узел из кода под именем "MatchManager".
## HUD находит его и его дочерний RoundTimer теми же get_node_or_null("MatchManager") /
## ("MatchManager/RoundTimer"), что и на продакшене — hud.gd под арену не меняется.
##
## Режим командного боя (см. vault «Игровые режимы» / TEAM ARENA):
## - раунд длится GameConfig.team_arena_round_sec (3 мин), заканчивается ТОЛЬКО по таймеру
##   (objective-объекта на карте нет, финальной стадии нет);
## - победитель раунда — команда с бОльшим числом убийств (ScoreManager); ничья разрешается
##   GameConfig.defense_wins_ties, как в продакшен-финалке (_on_final_stage_timeout);
## - результат раунда пишется в серию MatchState.record_round_result() ДО эмита round_ended,
##   чтобы HUD прочитал уже актуальный счёт серии (тот же порядок, что в match_manager.gd);
## - следующий раунд / новый матч — кнопкой в HUD (reload сцены), серия копится через autoload.
##
## final_stage_started/_final_stage_active существуют только для совместимости с hud.gd
## (он их читает безусловно) — на арене стадия не наступает никогда.

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

var _final_stage_active: bool = false  # всегда false на арене; hud.gd читает это поле
var _round_over: bool = false
var _round_timer: Timer
var _score_manager: Node

## Вызывается из bot_arena.gd._setup_match_context() сразу после add_child() — не _ready():
## так же, как ScoreManager.begin_match() и продакшен-MatchManager.begin_match(), явным вызовом
## из оркестратора в корне сцены, а не из собственного _ready().
func setup(round_sec: float, score_manager: Node) -> void:
	_score_manager = score_manager
	_round_timer = Timer.new()
	_round_timer.name = "RoundTimer"
	_round_timer.one_shot = true
	_round_timer.wait_time = round_sec
	add_child(_round_timer)
	_round_timer.timeout.connect(_on_round_timeout)
	_round_timer.start()

func _on_round_timeout() -> void:
	_end_round(_winner_by_kills())

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

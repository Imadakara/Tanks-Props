extends Node
## MatchState — переживает reload_current_scene() (autoload не пересоздаётся при рестарте
## сцены, в отличие от @export-полей на нодах внутри самой сцены). Хранит то, что должно
## жить МЕЖДУ раундами: какая команда сейчас у игрока, тип режима карты и счёт серии раундов.
##
## - player_team меняется на противоположную при нажатии кнопки рестарта в HUD (см. hud.gd) —
##   команды меняются сторонами каждый новый раунд.
## - match_mode выставляется корневым скриптом каждой карты в её _ready() (main.gd —
##   TARGET_OBJECTIVE; bot_arena.gd — по наличию узла Objective). HUD читает его ЛЕНИВО (в
##   _process), т.к. дочерние _ready() (в т.ч. HUD) отрабатывают раньше корневого.
## - Счёт серии (series_wins_*) НАКАПЛИВАЕТСЯ через reload_current_scene() — сбрасывается только
##   из главного меню (main_menu.gd) и по кнопке «Новый матч» после конца серии (hud.gd).
##   "Твоя команда" — устойчивая сущность: игрок меняет сторону каждый раунд, но series_wins_you
##   всегда про команду человека.

enum Mode { TARGET_OBJECTIVE, TEAM_ARENA }

var player_team: int = 0  # 0 = сторона атаки в этом раунде, 1 = сторона обороны
var match_mode: int = Mode.TARGET_OBJECTIVE

var total_rounds: int = 3
var series_wins_you: int = 0
var series_wins_enemy: int = 0

func reset_series() -> void:
	series_wins_you = 0
	series_wins_enemy = 0

## Сколько раундов серии уже отыграно (сумма побед обеих сторон) — счётчик текущего раунда
## выводится из него, отдельного поля нет: единственный источник истины — series_wins_*.
func rounds_played() -> int:
	return series_wins_you + series_wins_enemy

func current_round() -> int:
	return min(rounds_played() + 1, total_rounds)

func series_complete() -> bool:
	return rounds_played() >= total_rounds

## winner_side — "attack" | "defense", как эмитит MatchManager.round_ended. player_team = сторона
## игрока в ЭТОМ раунде (инвертируется рестартом уже ПОСЛЕ вызова), поэтому здесь она ещё
## актуальна для только что закончившегося раунда.
func record_round_result(winner_side: String) -> void:
	var player_is_attack: bool = player_team == 0
	if (winner_side == "attack") == player_is_attack:
		series_wins_you += 1
	else:
		series_wins_enemy += 1

func series_winner() -> String:
	if series_wins_you > series_wins_enemy:
		return "you"
	if series_wins_enemy > series_wins_you:
		return "enemy"
	return "tie"

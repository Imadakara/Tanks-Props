extends Node
## MatchState — переживает reload_current_scene() (autoload не пересоздаётся при рестарте
## сцены, в отличие от @export-полей на нодах внутри самой сцены). Хранит то, что должно
## жить МЕЖДУ раундами: какая команда сейчас у игрока, тип режима карты и счёт серии раундов.
##
## - player_team — сторона игрока в этом раунде. Инвертируется кнопкой рестарта в HUD ТОЛЬКО в
##   режимах со сменой сторон (TARGET_OBJECTIVE); в TEAM_ARENA команды-цвета постоянны, не меняются.
## - match_mode — НАСТРОЙКА СЦЕНЫ: map_scene.gd читает @export_enum var match_mode со своего
##   корня (значение в .tscn: TargetObjectiveMap=0, TeamArenaMap=1) и копирует сюда. HUD читает
##   его ЛЕНИВО (в _process), т.к. дочерние _ready() (в т.ч. HUD) раньше корневого.
##   Полное описание режимов — vault/Tank_Prop_Hunt_Game_Modes.md.
## - current_round_num — номер ИДУЩЕГО раунда (1..total_rounds). Инкрементируется РОВНО при старте
##   следующего раунда (hud._on_restart_pressed → advance_round), НЕ при завершении текущего —
##   иначе экран результата уже показывал бы номер следующего.
## - Счёт серии (series_wins_*) НАКАПЛИВАЕТСЯ через reload_current_scene() — сбрасывается только
##   из главного меню (main_menu.gd) и по кнопке «Новый матч» после конца серии (hud.gd).
##   "Твоя команда" — устойчивая сущность: series_wins_you всегда про команду человека.
## - Матч — best-of-3: заканчивается, как только одна команда взяла БОЛЬШИНСТВО (2 раунда), см.
##   series_complete()/rounds_to_win(). Победа 2:0 после второго раунда — матч сразу окончен,
##   третий (решающий) играется только при 1:1. Обе игровые режима идут через один series_complete().

enum Mode { TARGET_OBJECTIVE, TEAM_ARENA }

var player_team: int = 0  # 0 = сторона атаки в этом раунде, 1 = сторона обороны
var match_mode: int = Mode.TARGET_OBJECTIVE

var total_rounds: int = 3
var current_round_num: int = 1
var series_wins_you: int = 0
var series_wins_enemy: int = 0

func reset_series() -> void:
	current_round_num = 1
	player_team = 0
	series_wins_you = 0
	series_wins_enemy = 0

## Переход к следующему раунду — вызывается ИМЕННО при старте нового раунда (не при конце текущего).
func advance_round() -> void:
	current_round_num = min(current_round_num + 1, total_rounds)

## Сколько раундов серии уже отыграно = сумма побед обеих сторон (каждый раунд даёт ровно одну).
func rounds_played() -> int:
	return series_wins_you + series_wins_enemy

func current_round() -> int:
	return current_round_num

## Сколько раундов нужно для победы в матче (best-of-N, большинство): для total_rounds = 3 → 2.
func rounds_to_win() -> int:
	return total_rounds / 2 + 1

## Матч окончен, как только ОДНА команда набрала большинство раундов. Для best-of-3: победа
## 2:0 (после второго раунда) заканчивает матч сразу — третий, решающий, играется ТОЛЬКО при
## счёте 1:1. (rounds_played() >= total_rounds отдельно не нужен: после трёх раундов у кого-то
## уже минимум 2 победы.)
func series_complete() -> bool:
	return series_wins_you >= rounds_to_win() or series_wins_enemy >= rounds_to_win()

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

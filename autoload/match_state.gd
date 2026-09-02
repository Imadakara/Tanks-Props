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
## - Счёт серии — ПО СТОРОНЕ (series_wins_attack / series_wins_defense), не по «команде игрока».
##   В TARGET_OBJECTIVE игрок между раундами меняет сторону (hud._has_side_swap), поэтому
##   «команда игрока» — НЕ устойчивая величина; устойчивы именно стороны: атакующий и
##   защищающийся отряды ботов фиксированы (ростер), плавает только игрок. В TEAM_ARENA смены
##   сторон нет — "attack" там всегда команда 0 (Красные), "defense" — команда 1 (Синие).
##   НАКАПЛИВАЕТСЯ через reload_current_scene(), сбрасывается из меню (main_menu.gd) и по кнопке
##   «Новый матч» (hud.gd).
## - Матч — best-of-3: заканчивается, как только ОДНА сторона взяла БОЛЬШИНСТВО (2 раунда), см.
##   series_complete()/rounds_to_win(). Раунд 1 за атакой + раунд 2 за защитой → 1:1, играется
##   решающий третий. 2:0 после второго — матч сразу окончен. Оба режима — через один
##   series_complete().

enum Mode { TARGET_OBJECTIVE, TEAM_ARENA }

var player_team: int = 0  # 0 = сторона атаки в этом раунде, 1 = сторона обороны
var match_mode: int = Mode.TARGET_OBJECTIVE

## Единый выключатель всей отладочной обвязки (оверлеи ИИ: конус обзора / путь / brain-панель /
## reaction-кнопка; тумблеры «Игрок: бессмертие» и «Objective ON/OFF»; камеры-клавиши 1/2/3;
## debug-круги зон спавна/сброса). Ставится галочкой в меню выбора карт (main_menu.gd) ПЕРЕД
## сменой сцены; ДЕФОЛТ true — прямой запуск карты из редактора/`run_project` (в обход меню)
## остаётся отладочным. Живёт в autoload (нужен уже в _ready() карты/зон/ИИ, до этого autoload
## уже поднят) и переживает reload_current_scene(); reset_series() его НЕ трогает — задаётся
## только из меню, держится всю сессию.
## RELEASE TODO: на стадии подготовки к Steam/релизу заменить механизм входа (галочка в меню
## на виду у игрока — временное решение для разработки): убрать из обычного меню, оставить за
## флагом командной строки / dev-билдом / debug-сборкой. См. корневой CLAUDE.md.
var debug_enabled: bool = true

var total_rounds: int = 3
var current_round_num: int = 1
var series_wins_attack: int = 0
var series_wins_defense: int = 0

func reset_series() -> void:
	current_round_num = 1
	player_team = 0
	series_wins_attack = 0
	series_wins_defense = 0

## Переход к следующему раунду — вызывается ИМЕННО при старте нового раунда (не при конце текущего).
func advance_round() -> void:
	current_round_num = min(current_round_num + 1, total_rounds)

## Сколько раундов серии уже отыграно = сумма побед обеих сторон (каждый раунд даёт ровно одну).
func rounds_played() -> int:
	return series_wins_attack + series_wins_defense

func current_round() -> int:
	return current_round_num

## Сколько раундов нужно для победы в матче (best-of-N, большинство): для total_rounds = 3 → 2.
func rounds_to_win() -> int:
	return total_rounds / 2 + 1

## Матч окончен, как только ОДНА сторона набрала большинство раундов. Для best-of-3: 2:0 после
## второго раунда — матч сразу окончен; третий (решающий) — только при 1:1.
func series_complete() -> bool:
	return series_wins_attack >= rounds_to_win() or series_wins_defense >= rounds_to_win()

## winner_side — "attack" | "defense", как эмитит MatchManager.round_ended. Кредитуем СТОРОНУ
## напрямую — какая сторона взяла раунд, той и очко серии. НЕ через player_team: он между
## раундами инвертируется (смена сторон), и «сторона игрока выиграла» ≠ «команда игрока выиграла».
func record_round_result(winner_side: String) -> void:
	if winner_side == "attack":
		series_wins_attack += 1
	else:
		series_wins_defense += 1

## "attack" | "defense" | "tie" — какая сторона выиграла матч (больше выигранных раундов).
func series_winner() -> String:
	if series_wins_attack > series_wins_defense:
		return "attack"
	if series_wins_defense > series_wins_attack:
		return "defense"
	return "tie"

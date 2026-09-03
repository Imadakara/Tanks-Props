extends Control
## MainMenu — стартовый экран (run/main_scene указывает сюда, см. CLAUDE.md "Map inventory" за
## полным списком карт). Кнопки — переход на соответствующую карту через
## get_tree().change_scene_to_file(); сама эта сцена никакой игровой логики не несёт, только выбор,
## куда идти дальше.

const _TARGET_OBJECTIVE_SCENE := "res://scenes/maps/TargetObjectiveMap.tscn"
const _TEAM_ARENA_SCENE := "res://scenes/maps/TeamArenaMap.tscn"

@onready var _target_objective_button: Button = $VBoxContainer/AchieverButton
@onready var _team_arena_button: Button = $VBoxContainer/KillerButton
@onready var _debug_mode_check: CheckBox = $VBoxContainer/DebugModeCheck
## [ДОБАВЛЕНО, по прямому запросу — "галочка напротив кнопки запуска карты, если стоит галочка
## дебаг-режима — спавнить сразу ботов или только по команде"] Смысл имеет только вместе с
## debug-режимом (см. _on_debug_toggled() — скрыта/недоступна, пока тот выключен): в обычной игре
## ростер всегда спавнится сразу, без раздумий. См. MatchState.debug_spawn_bots_on_start.
@onready var _spawn_bots_immediately_check: CheckBox = $VBoxContainer/SpawnBotsImmediatelyCheck

func _ready() -> void:
	_target_objective_button.pressed.connect(_go.bind(_TARGET_OBJECTIVE_SCENE))
	_team_arena_button.pressed.connect(_go.bind(_TEAM_ARENA_SCENE))
	_debug_mode_check.toggled.connect(_on_debug_toggled)
	_on_debug_toggled(_debug_mode_check.button_pressed)

## Видимость новой галочки следует за debug-режимом — вне debug-режима она не читается вообще
## (см. _go()), показывать её как будто что-то решает было бы вводящим в заблуждение.
func _on_debug_toggled(debug_on: bool) -> void:
	_spawn_bots_immediately_check.visible = debug_on

## Заход в любую карту из меню — начало новой серии: сбрасываем счёт раундов (autoload
## MatchState переживает смену сцены, иначе серия дотянулась бы из прошлого запуска). Галочка
## debug-режима фиксируется здесь же, ДО смены сцены (reset_series() её не трогает — держится
## всю сессию; см. MatchState.debug_enabled). Галочка "спавнить сразу" читается ТОЛЬКО если
## debug-режим включён — вне его всегда true (обычная игра, ростер спавнится сразу безусловно).
func _go(scene_path: String) -> void:
	MatchState.debug_enabled = _debug_mode_check.button_pressed
	MatchState.debug_spawn_bots_on_start = _spawn_bots_immediately_check.button_pressed if MatchState.debug_enabled else true
	MatchState.reset_series()
	get_tree().change_scene_to_file(scene_path)

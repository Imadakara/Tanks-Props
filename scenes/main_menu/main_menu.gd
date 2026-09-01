extends Control
## MainMenu — стартовый экран (run/main_scene указывает сюда, см. CLAUDE.md "Map inventory" за
## полным списком карт). Кнопки — переход на соответствующую карту через
## get_tree().change_scene_to_file(); сама эта сцена никакой игровой логики не несёт, только выбор,
## куда идти дальше.

const _TARGET_OBJECTIVE_SCENE := "res://scenes/maps/TargetObjectiveMap.tscn"
const _TEAM_ARENA_SCENE := "res://scenes/maps/TeamArenaMap.tscn"

@onready var _target_objective_button: Button = $VBoxContainer/AchieverButton
@onready var _team_arena_button: Button = $VBoxContainer/KillerButton

func _ready() -> void:
	_target_objective_button.pressed.connect(_go.bind(_TARGET_OBJECTIVE_SCENE))
	_team_arena_button.pressed.connect(_go.bind(_TEAM_ARENA_SCENE))

## Заход в любую карту из меню — начало новой серии: сбрасываем счёт раундов (autoload
## MatchState переживает смену сцены, иначе серия дотянулась бы из прошлого запуска).
func _go(scene_path: String) -> void:
	MatchState.reset_series()
	get_tree().change_scene_to_file(scene_path)

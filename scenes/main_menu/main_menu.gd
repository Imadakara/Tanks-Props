extends Control
## MainMenu — стартовый экран (по прямому запросу, run/main_scene теперь указывает сюда, см.
## CLAUDE.md "Map inventory" за полным списком карт). Три плашки — переход на соответствующую
## сцену через get_tree().change_scene_to_file(); сама эта сцена никакой игровой логики не несёт,
## только выбор, куда идти дальше.

const _ACHIEVER_SCENE := "res://scenes/bot_arena/BotArena.tscn"
const _KILLER_SCENE := "res://scenes/bot_arena/KillerArena.tscn"
const _MAIN_SCENE := "res://scenes/main/Main.tscn"

@onready var _achiever_button: Button = $VBoxContainer/AchieverButton
@onready var _killer_button: Button = $VBoxContainer/KillerButton
@onready var _main_button: Button = $VBoxContainer/MainButton

func _ready() -> void:
	_achiever_button.pressed.connect(_go.bind(_ACHIEVER_SCENE))
	_killer_button.pressed.connect(_go.bind(_KILLER_SCENE))
	_main_button.pressed.connect(_go.bind(_MAIN_SCENE))

## Заход в любую карту из меню — начало новой серии: сбрасываем счёт раундов (autoload
## MatchState переживает смену сцены, иначе серия дотянулась бы из прошлого запуска).
func _go(scene_path: String) -> void:
	MatchState.reset_series()
	get_tree().change_scene_to_file(scene_path)

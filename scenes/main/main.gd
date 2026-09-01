extends Node3D
## Main — оркестрация старта матча (ТЗ §11.2). Спавн состава обязан завершиться ДО того,
## как MatchManager/ScoreManager просканируют группу "tanks". Раньше это делалось прямым
## `_ready()` у сиблингов, но `add_child()` на `current_scene` изнутри ЧУЖОГО `_ready()`
## падает с "Parent node is busy setting up children" — дерево ещё строится. `_ready()`
## самого корня вызывается ПОСЛЕДНИМ (после всех объявленных детей), когда это уже
## безопасно — поэтому оркестрация явными вызовами отсюда, а не из `_ready()` каждого
## менеджера по отдельности.

func _ready() -> void:
	# Режим карты — явно на каждом входе в сцену: autoload MatchState.match_mode мог остаться
	# в TEAM_ARENA от прошлой сессии бот-арены (см. bot_arena.gd). Серию НЕ трогаем — она
	# накапливается через reload_current_scene() между раундами; сброс — только из меню.
	MatchState.match_mode = MatchState.Mode.TARGET_OBJECTIVE
	$TeamSpawner.spawn_team()
	$MatchManager.begin_match()
	$ScoreManager.begin_match()

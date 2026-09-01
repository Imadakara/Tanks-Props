extends Node3D
## Main — оркестрация старта матча (ТЗ §11.2). Спавн состава обязан завершиться ДО того,
## как MatchManager/ScoreManager просканируют группу "tanks". Раньше это делалось прямым
## `_ready()` у сиблингов, но `add_child()` на `current_scene` изнутри ЧУЖОГО `_ready()`
## падает с "Parent node is busy setting up children" — дерево ещё строится. `_ready()`
## самого корня вызывается ПОСЛЕДНИМ (после всех объявленных детей), когда это уже
## безопасно — поэтому оркестрация явными вызовами отсюда, а не из `_ready()` каждого
## менеджера по отдельности.
##
## [ДОБАВЛЕНО, по прямому запросу — "боты это универсальная система для любой карты, если есть
## недоработка в этом ключе — пофиксить"] TankAIController (единственный ИИ проекта, см.
## team_spawner.gd) читает время_since_objective_hit()/enemy_in_alert_zone() у корня текущей сцены
## для State.ALERT — раньше эти методы существовали ТОЛЬКО у bot_arena.gd (sandbox-оркестратор),
## живьём поймано "Nonexistent function 'time_since_objective_hit' in base main.gd" на первом же
## прогоне после того, как боты стали общими для всех карт. Логика вынесена в переиспользуемый
## класс (scenes/main/objective_alert_state.gd, см. её doc-comment) — тот же экземпляр-паттерн,
## что и у bot_arena.gd, тикает здесь, сбрасывается на каждый Objective/HealthComponent.damaged.

const ObjectiveAlertStateScript := preload("res://scenes/main/objective_alert_state.gd")

var _alert_state := ObjectiveAlertStateScript.new()
var _alert_zone: Node3D = null

func _ready() -> void:
	# Режим карты — явно на каждом входе в сцену: autoload MatchState.match_mode мог остаться
	# в TEAM_ARENA от прошлой сессии бот-арены (см. bot_arena.gd). Серию НЕ трогаем — она
	# накапливается через reload_current_scene() между раундами; сброс — только из меню.
	MatchState.match_mode = MatchState.Mode.TARGET_OBJECTIVE
	$TeamSpawner.spawn_team()
	$MatchManager.begin_match()
	$ScoreManager.begin_match()
	_setup_objective_alert()

func _physics_process(delta: float) -> void:
	_alert_state.tick(delta)

## group "objective_health" — та же, что $MatchManager.begin_match() уже проставляет на найденный
## objective (см. match_manager.gd) — вызывается СТРОГО ПОСЛЕ него (см. порядок выше в _ready()),
## группа гарантированно уже заполнена. find_child по имени здесь не годится: продакшен-узел
## называется "DestructibleObjective", sandbox-арены — "Objective" (см. её doc-comment) — группа
## работает одинаково независимо от имени.
func _setup_objective_alert() -> void:
	var health: Node = get_tree().get_first_node_in_group("objective_health")
	if health == null:
		return
	health.damaged.connect(_on_objective_damaged)
	var objective: Node = health.get_parent()
	_alert_zone = objective.find_child("ObjectiveAlertZone", true, false) if objective != null else null

func _on_objective_damaged(_current_hits: int, _max_hits: int, _killer: Node = null) -> void:
	_alert_state.reset()

func time_since_objective_hit() -> float:
	return _alert_state.time_since_hit()

func enemy_in_alert_zone() -> bool:
	if not is_instance_valid(_alert_zone):
		return false
	return _alert_state.enemy_in_zone(_alert_zone, get_tree())

extends CanvasLayer
## HUD — минимальный HUD игрока (ТЗ §10): за какую команду игрок в этом раунде (пост-ревью),
## боезапас, статус танка с таймерами, финальная стадия, экран результата.
## Плюс общий блок матча (верх-центр, одинаков на всех картах):
##   строка 1 — «Раунд N/M | MM:SS»;
##   строка 2 — общий счёт по MatchState.match_mode (TARGET_OBJECTIVE — серия раундов;
##             TEAM_ARENA — убийства команд в раунде + серия);
##   строка 3 — «Цель: N/M попаданий», здоровье objective-цели (только TARGET_OBJECTIVE);
##   строка 4 — «Респаун через N с», обратный отсчёт до респауна игрока (видна только пока идёт).
## Подписка на сигналы вместо поллинга — кроме отображения "сколько осталось" у Timer-нод и
## блока матча (читается из MatchState/узлов каждый кадр: источники резолвятся лениво, см. _resolve_*).
## RestartButton (пост-ревью) — появляется вместе с ResultLabel по round_ended, снимает
## захват мыши (иначе по кнопке нечем кликнуть), рестартует сцену. Смену сторон (инверсию
## MatchState.player_team) делает только в режимах с team_spawner (TARGET_OBJECTIVE) — на арене
## TEAM_ARENA танки статичны, роль игрока фиксирована. После конца серии кнопка = «Новый матч»
## (сброс серии).

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@onready var _team_label: Label = $TeamLabel
@onready var _ammo_label: Label = $AmmoLabel
@onready var _state_label: Label = $StateLabel
@onready var _round_timer_label: Label = $RoundTimerLabel
@onready var _objective_label: Label = $ObjectiveLabel
@onready var _score_label: Label = $ScoreLabel
@onready var _respawn_label: Label = $RespawnLabel
@onready var _final_stage_label: Label = $FinalStageLabel
@onready var _result_label: Label = $ResultLabel
@onready var _restart_button: Button = $RestartButton
@onready var _crosshair: Control = $Crosshair

var _fsm: Node
var _ammo: Node
var _respawn: Node  # RespawnController танка игрока — для строки обратного отсчёта до респауна
var _match_manager: Node
var _score_manager: Node
var _objective_health: Node  # HealthComponent objective-цели (режим TARGET_OBJECTIVE), резолвится лениво
var _round_timer: Timer
var _barrel: Node3D
var _camera: Camera3D

func _ready() -> void:
	# MatchState.player_team, не tank.is_attacker(): дочерние _ready() (в т.ч. этот) отрабатывают
	# РАНЬШЕ корневого Main._ready(), а TeamSpawner.spawn_team() (ставит tank.team) вызывается
	# именно из Main._ready() — на момент этой строки tank.team ещё дефолтный, а не тот, что
	# реально будет у игрока в этом раунде (грабля, поймана на смене сторон после рестарта).
	_team_label.text = "Команда: Атака" if MatchState.player_team == 0 else "Команда: Оборона"

	var tank: Node = get_tree().current_scene.get_node_or_null("PlayerTank")
	if tank != null:
		_ammo = tank.get_node("AmmoComponent")
		_fsm = tank.get_node("TankStateMachine")
		_ammo.ammo_changed.connect(_on_ammo_changed)
		_fsm.state_changed.connect(_on_state_changed)
		_on_ammo_changed(_ammo.current_ammo, _ammo.max_ammo)
		_update_state_label()
		_respawn = tank.get_node_or_null("RespawnController")
		_barrel = tank.get_node("Turret/Barrel")
		_camera = tank.get_node("CameraRig/Camera3D")

	# MatchManager/ScoreManager/RoundTimer/objective резолвятся лениво (см. _resolve_*) и
	# поллятся: бот-арены заводят эти узлы из кода уже ПОСЛЕ этого _ready(), а objective
	# может освободиться при уничтожении. Продакшен подключится к MatchManager тут же (узел статический).
	_resolve_match_manager()
	_score_manager = get_tree().current_scene.get_node_or_null("ScoreManager")

	_final_stage_label.visible = false
	_restart_button.visible = false
	_restart_button.pressed.connect(_on_restart_pressed)

func _process(_delta: float) -> void:
	if _fsm != null:
		_update_state_label()
	_update_round_line()
	_update_match_score_line()
	_update_objective_line()
	_update_respawn_line()
	var mm := _resolve_match_manager()
	if mm != null and mm._final_stage_active:
		_update_final_stage_label()
	_update_crosshair()

func _update_crosshair() -> void:
	if _barrel == null or _camera == null:
		return
	var aim_point: Vector3 = _barrel.global_position + (-_barrel.global_transform.basis.z) * 20.0
	if _camera.is_position_behind(aim_point):
		_crosshair.visible = false
		return
	_crosshair.visible = true
	var screen_pos: Vector2 = _camera.unproject_position(aim_point)
	_crosshair.position = screen_pos - _crosshair.size * 0.5

func _on_final_stage_started() -> void:
	_final_stage_label.visible = true

func _update_final_stage_label() -> void:
	var t: float = _match_manager.get_node("FinalStageTimer").time_left
	_final_stage_label.text = "ФИНАЛЬНАЯ СТАДИЯ: %.0f с" % t

## MatchManager резолвится лениво: продакшен — статический узел (есть к _ready() HUD); арена
## TEAM_ARENA заводит его из кода ПОЗЖЕ (bot_arena.gd, узел зовётся "MatchManager"). Сигналы
## подключаются один раз, при первом появлении узла. На BotArena (нет постраундового цикла)
## узла нет вообще — вернёт null, HUD просто не покажет экран результата.
func _resolve_match_manager() -> Node:
	if _match_manager != null and is_instance_valid(_match_manager):
		return _match_manager
	var scene := get_tree().current_scene
	if scene == null:
		return null
	_match_manager = scene.get_node_or_null("MatchManager")
	if _match_manager != null:
		_match_manager.round_ended.connect(_on_round_ended)
		_match_manager.final_stage_started.connect(_on_final_stage_started)
	return _match_manager

## Источник таймера раунда ищется лениво: продакшен и арена TEAM_ARENA — MatchManager/RoundTimer;
## BotArena заводит RoundTimer прямо в корне сцены из кода (bot_arena.gd), уже ПОСЛЕ _ready() HUD.
## `as Timer` — null, если узла нет или это не Timer (тогда строка показывает --:--).
func _resolve_round_timer() -> Timer:
	if _round_timer != null and is_instance_valid(_round_timer):
		return _round_timer
	var scene := get_tree().current_scene
	if scene == null:
		return null
	_round_timer = scene.get_node_or_null("MatchManager/RoundTimer") as Timer
	if _round_timer == null:
		_round_timer = scene.get_node_or_null("RoundTimer") as Timer
	return _round_timer

func _resolve_score_manager() -> Node:
	if _score_manager != null and is_instance_valid(_score_manager):
		return _score_manager
	var scene := get_tree().current_scene
	if scene != null:
		_score_manager = scene.get_node_or_null("ScoreManager")
	return _score_manager

## Строка 1 (верх-центр): «Раунд N/M | MM:SS», разделитель — вертикальная черта.
func _update_round_line() -> void:
	var round_txt := "Раунд %d/%d" % [MatchState.current_round(), MatchState.total_rounds]
	var timer := _resolve_round_timer()
	if timer == null:
		_round_timer_label.text = "%s | --:--" % round_txt
		return
	var t: int = int(max(0.0, timer.time_left))
	_round_timer_label.text = "%s | %02d:%02d" % [round_txt, t / 60, t % 60]

## Строка 2 (верх-центр): общий счёт. TARGET_OBJECTIVE — только серия раундов; TEAM_ARENA —
## убийства команд в текущем раунде И через разделитель серия раундов.
func _update_match_score_line() -> void:
	if MatchState.match_mode == MatchState.Mode.TEAM_ARENA:
		var sm := _resolve_score_manager()
		var atk: int = sm.attack_kills if sm != null else 0
		var def: int = sm.defense_kills if sm != null else 0
		var you: int = atk if MatchState.player_team == 0 else def
		var foe: int = def if MatchState.player_team == 0 else atk
		_score_label.text = "Убийства — Ты %d : %d Противник   |   По раундам %d : %d" % \
			[you, foe, MatchState.series_wins_you, MatchState.series_wins_enemy]
	else:
		_score_label.text = "По раундам — Ты %d : %d Противник" % \
			[MatchState.series_wins_you, MatchState.series_wins_enemy]

## HealthComponent objective-цели: продакшен — Map/DestructibleObjective, арена —
## NavigationRegion3D/Objective; ищем оба по имени. is_instance_valid: цель освобождается при
## уничтожении (free_on_destroy=true), после чего ссылка висячая.
func _resolve_objective_health() -> Node:
	if _objective_health != null and is_instance_valid(_objective_health):
		return _objective_health
	_objective_health = null
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var obj := scene.find_child("DestructibleObjective", true, false)
	if obj == null:
		obj = scene.find_child("Objective", true, false)
	if obj != null:
		_objective_health = obj.get_node_or_null("HealthComponent")
	return _objective_health

## Строка 3 (верх-центр, под счётом раундов): здоровье objective-цели. ТОЛЬКО режим
## TARGET_OBJECTIVE. Имя режима в тексте НЕ пишем — режим задан в настройках карты
## (bot_arena.gd @export match_mode / продакшен match_manager.gd), в HUD ему не место.
func _update_objective_line() -> void:
	var hc := _resolve_objective_health()
	if MatchState.match_mode != MatchState.Mode.TARGET_OBJECTIVE or hc == null:
		_objective_label.visible = false
		return
	_objective_label.visible = true
	_objective_label.text = "Цель: %d/%d попаданий" % [hc.current_hits, hc.max_hits]

## Строка 4 (верх-центр, под здоровьем цели): обратный отсчёт до респауна игрока. Видна ТОЛЬКО
## пока RespawnController.time_until_respawn() > 0 (танк мёртв, таймер идёт) — иначе скрыта.
func _update_respawn_line() -> void:
	var t: float = _respawn.time_until_respawn() if _respawn != null else 0.0
	if t <= 0.0:
		_respawn_label.visible = false
		return
	_respawn_label.visible = true
	_respawn_label.text = "Респаун через %d с" % int(ceil(t))

func _on_round_ended(winner: String) -> void:
	# record_round_result() (в MatchManager/arena_match) уже отработал до этого сигнала — серия актуальна.
	var head := _round_result_head(winner)
	if MatchState.series_complete():
		var verdict: String = {
			"you": "Матч выигран!", "enemy": "Матч проигран", "tie": "Матч: ничья",
		}[MatchState.series_winner()]
		_result_label.text = "%s\n%s   (серия %d : %d)" % \
			[head, verdict, MatchState.series_wins_you, MatchState.series_wins_enemy]
		_restart_button.text = "Новый матч"
	else:
		_result_label.text = "Раунд %d/%d — %s" % \
			[MatchState.rounds_played(), MatchState.total_rounds, head]
		_restart_button.text = "Следующий раунд" + (" (смена сторон)" if _has_side_swap() else "")
	_result_label.visible = true
	_restart_button.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # иначе кнопку нечем кликнуть — мышь захвачена CameraRig

## TARGET_OBJECTIVE — «Победа атакующих/обороняющихся» (сторона и есть команда).
## TEAM_ARENA — с точки зрения игрока: «Ты победил / Противник победил» + счёт убийств раунда
## (у режима нет постоянной атаки/обороны в голове игрока, но роль игрока в раунде фиксирована).
func _round_result_head(winner: String) -> String:
	if MatchState.match_mode != MatchState.Mode.TEAM_ARENA:
		return "Победа атакующих" if winner == "attack" else "Победа обороняющихся"
	var player_won: bool = (winner == "attack") == (MatchState.player_team == 0)
	var sm := _resolve_score_manager()
	var you: int = 0
	var foe: int = 0
	if sm != null:
		you = sm.attack_kills if MatchState.player_team == 0 else sm.defense_kills
		foe = sm.defense_kills if MatchState.player_team == 0 else sm.attack_kills
	return "%s (убийства %d : %d)" % ["Ты победил" if player_won else "Противник победил", you, foe]

## Смена сторон между раундами делается ТОЛЬКО там, где спавном рулит TeamSpawner (продакшен
## Main.tscn — танки инстанцируются под роль каждый раунд). На бот-аренах (обоих режимов) танки
## статические, инверсия player_team рассинхронила бы HUD (TeamLabel/«Ты») с реальным полем.
func _has_side_swap() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.get_node_or_null("TeamSpawner") != null

func _on_restart_pressed() -> void:
	if MatchState.series_complete():
		MatchState.reset_series()  # серия доиграна — кнопка запускает новый матч с нуля
	if _has_side_swap():
		MatchState.player_team = 1 - MatchState.player_team
	get_tree().reload_current_scene()

func _on_ammo_changed(current: int, max_ammo: int) -> void:
	_ammo_label.text = "Боезапас: %d/%d" % [current, max_ammo]

func _on_state_changed(_old_state, _new_state) -> void:
	_update_state_label()

func _update_state_label() -> void:
	match _fsm.state:
		TankStateMachineScript.State.NORMAL:
			_state_label.text = "Статус: обычное"
		TankStateMachineScript.State.DISGUISED:
			_state_label.text = "Статус: маскировка (%.1f с)" % _fsm.get_node("DisguiseTimer").time_left
		TankStateMachineScript.State.DISGUISE_COOLDOWN:
			_state_label.text = "Статус: кулдаун маскировки (%.1f с)" % _fsm.get_node("CooldownTimer").time_left
		TankStateMachineScript.State.RELOAD:
			_state_label.text = "Статус: перезарядка (%.1f с)" % _fsm.get_node("ReloadTimer").time_left

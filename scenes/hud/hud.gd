extends CanvasLayer
## HUD — минимальный HUD игрока: за какую команду игрок в этом раунде (пост-ревью),
## боезапас, статус танка с таймерами, финальная стадия, экран результата.
## Плюс общий блок матча (верх-центр, одинаков на всех картах):
##   строка 1 — «Раунд N/M | MM:SS» (N = MatchState.current_round(), инкремент при СТАРТЕ раунда);
##   строка 2 — общий счёт по MatchState.match_mode: TARGET_OBJECTIVE — серия раундов «Ты/Противник»;
##             TEAM_ARENA — убийства команд-цветов в раунде + серия, всё по «Красные/Синие»;
##             CONTAINER_EXTRACTION — доставленные контейнеры по цветам + сколько их осталось на карте;
##   строка 3 — «Цель: N/M попаданий», здоровье objective-цели (только TARGET_OBJECTIVE);
##   строка 4 — «Респаун через N с», обратный отсчёт до респауна игрока (видна только пока идёт).
## В TEAM_ARENA стороны — постоянные команды-цвета (Красные = команда 0, Синие = команда 1),
## никаких «атака/оборона»; TeamLabel и экран результата это учитывают.
## Подписка на сигналы вместо поллинга — кроме отображения "сколько осталось" у Timer-нод и
## блока матча (читается из MatchState/узлов каждый кадр: источники резолвятся лениво, см. _resolve_*).
## RestartButton — появляется вместе с ResultLabel по round_ended, снимает захват мыши, рестартует
## сцену; при этом либо advance_round() (следующий раунд), либо reset_series() («Новый матч» после
## конца серии). Смену сторон (инверсию MatchState.player_team) делает только TARGET_OBJECTIVE.

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
@onready var _mortar_reticle: Control = $MortarReticle
@onready var _mod_slot_label: Label = $ModSlotLabel

var _fsm: Node
var _ammo: Node
var _respawn: Node  # RespawnController танка игрока — для строки обратного отсчёта до респауна
var _match_manager: Node
var _score_manager: Node
var _objective_health: Node  # HealthComponent objective-цели (режим TARGET_OBJECTIVE), резолвится лениво
var _container_manager: Node  # ContainerManager (режим CONTAINER_EXTRACTION), резолвится лениво
var _round_timer: Timer
var _barrel: Node3D
var _camera: Camera3D
var _mod: Node  # ModificationController танка игрока — слот модификации + режим прицеливания мортиры

func _ready() -> void:
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
		_mod = tank.get_node_or_null("ModificationController")
		if _mod != null:
			_mod.mod_changed.connect(_on_mod_changed)
			_on_mod_changed(_mod.current_mod)

	# MatchManager/ScoreManager/RoundTimer/objective резолвятся лениво (см. _resolve_*) и
	# поллятся: карта заводит эти узлы из кода уже ПОСЛЕ этого _ready(), а objective может
	# освободиться при уничтожении.
	_resolve_match_manager()
	_score_manager = get_tree().current_scene.get_node_or_null("ScoreManager")

	_final_stage_label.visible = false
	_restart_button.visible = false
	_restart_button.pressed.connect(_on_restart_pressed)

func _process(_delta: float) -> void:
	if _fsm != null:
		_update_state_label()
	_update_team_label()
	_update_round_line()
	_update_match_score_line()
	_update_objective_line()
	_update_respawn_line()
	var mm := _resolve_match_manager()
	if mm != null and mm._final_stage_active:
		_update_final_stage_label()
	_update_crosshair()

func _on_mod_changed(mod: Resource) -> void:
	_mod_slot_label.text = "Модификация: —" if mod == null else "Модификация: %s" % mod.hud_short

func _update_crosshair() -> void:
	if _barrel == null:
		return
	# Активная камера, не CameraRig/Camera3D напрямую — в режиме прицеливания мортиры это MortarCamera.
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# Модификация может прятать экранный прицел (мортира в режиме прицеливания: её роль играет
	# кольцо НА ЗЕМЛЕ, mortar_behavior._reticle_ring) — тогда не показываем никаких экранных прицелов.
	if _mod != null and _mod.hides_crosshair():
		_crosshair.visible = false
		_mortar_reticle.visible = false
		return
	_mortar_reticle.visible = false
	var aim_point: Vector3 = _barrel.global_position + (-_barrel.global_transform.basis.z) * 20.0
	if cam.is_position_behind(aim_point):
		_crosshair.visible = false
		return
	_crosshair.visible = true
	_crosshair.position = cam.unproject_position(aim_point) - _crosshair.size * 0.5

func _on_final_stage_started() -> void:
	_final_stage_label.visible = true

func _update_final_stage_label() -> void:
	var t: float = _match_manager.get_node("FinalStageTimer").time_left
	_final_stage_label.text = "ФИНАЛЬНАЯ СТАДИЯ: %.0f с" % t

## MatchManager резолвится лениво — map_scene.gd заводит его из кода в _ready() корня сцены,
## которая идёт ПОСЛЕ _ready() HUD (см. корневой CLAUDE.md, "Scene bring-up ordering"). Сигналы
## подключаются один раз, при первом появлении узла.
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

## Источник таймера раунда ищется лениво — MatchManager/RoundTimer заводится map_scene.gd из кода,
## уже ПОСЛЕ _ready() HUD. `as Timer` — null, если узла нет или это не Timer (тогда строка
## показывает --:--).
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

## Режимы с ПОСТОЯННЫМИ командами-цветами (Красные = команда 0 = «attack», Синие = команда 1 =
## «defense»): TEAM_ARENA и CONTAINER_EXTRACTION. В них нет смены сторон между раундами, поэтому
## HUD везде говорит «Красные/Синие», а не «Атака/Оборона» (те осмысленны только в TARGET_OBJECTIVE,
## где роли реально чередуются). Одна проверка вместо четырёх независимых сравнений с TEAM_ARENA.
func _is_color_team_mode() -> bool:
	return MatchState.match_mode == MatchState.Mode.TEAM_ARENA \
		or MatchState.match_mode == MatchState.Mode.CONTAINER_EXTRACTION

## ContainerManager заводится map_scene.gd из кода уже ПОСЛЕ _ready() HUD — резолвится лениво, как
## MatchManager/ScoreManager. null на картах любого другого режима.
func _resolve_container_manager() -> Node:
	if _container_manager != null and is_instance_valid(_container_manager):
		return _container_manager
	var scene := get_tree().current_scene
	if scene != null:
		_container_manager = scene.get_node_or_null("ContainerManager")
	return _container_manager

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

## TeamLabel (левый столбец). MatchState.player_team, не tank.is_attacker(): дочерние _ready()
## (в т.ч. HUD) идут РАНЬШЕ корневого _ready() карты, где TeamSpawner.spawn_team() выставляет
## tank.team — на момент _ready() HUD значение ещё дефолтное. match_mode тоже ставится корневым
## _ready(), поэтому обновляем лениво в _process. В TEAM_ARENA стороны — команды-цвета
## (Красные/Синие), никаких «атака/оборона».
func _update_team_label() -> void:
	if _is_color_team_mode():
		_team_label.text = "Команда: Красные" if MatchState.player_team == 0 else "Команда: Синие"
	else:
		_team_label.text = "Команда: Атака" if MatchState.player_team == 0 else "Команда: Оборона"

## Серия по цвету команды: [красные, синие]. Серия хранится по стороне (attack/defense), а в
## TEAM_ARENA смены сторон нет: attack = команда 0 = Красные, defense = команда 1 = Синие.
func _series_by_color() -> Array:
	return [MatchState.series_wins_attack, MatchState.series_wins_defense]

## Строка 2 (верх-центр): общий счёт. CONTAINER_EXTRACTION — доставленные контейнеры по цветам
## команд плюс «осталось на карте» (не доставленные — и лежащие, и в чужих слотах): матч из одного
## раунда, серию показывать незачем. TARGET_OBJECTIVE — серия раундов по стороне
## («Атака : Оборона» — игрок меняет сторону между раундами, «Ты» не имеет смысла);
## TEAM_ARENA — убийства команд-цветов в текущем раунде И через разделитель серия раундов, всё
## по цветам (Красные = команда 0 = attack_kills, Синие = команда 1 = defense_kills).
func _update_match_score_line() -> void:
	if MatchState.match_mode == MatchState.Mode.CONTAINER_EXTRACTION:
		var cm := _resolve_container_manager()
		if cm == null:
			_score_label.text = "Контейнеры  Красные 0 : 0 Синие"
			return
		_score_label.text = "Контейнеры  Красные %d : %d Синие      Осталось на карте: %d" % \
			[cm.attack_delivered, cm.defense_delivered, cm.remaining()]
		return
	if MatchState.match_mode == MatchState.Mode.TEAM_ARENA:
		var sm := _resolve_score_manager()
		var red_kills: int = sm.attack_kills if sm != null else 0
		var blue_kills: int = sm.defense_kills if sm != null else 0
		var s := _series_by_color()  # тот же порядок Красные:Синие, что и в убийствах
		_score_label.text = "Убийства  Красные %d : %d Синие      Раунды  %d : %d" % \
			[red_kills, blue_kills, s[0], s[1]]
	else:
		_score_label.text = "По раундам — Атака %d : %d Оборона" % \
			[MatchState.series_wins_attack, MatchState.series_wins_defense]

## Группа "objective_health" — та же, что map_scene.gd регистрирует и TankAIController читает
## (см. tank_ai_controller.gd._find_objective()) — не по имени узла, работает для любой карты без
## правки этого файла. is_instance_valid: цель освобождается при уничтожении (free_on_destroy=true),
## после чего ссылка висячая.
func _resolve_objective_health() -> Node:
	if _objective_health != null and is_instance_valid(_objective_health):
		return _objective_health
	_objective_health = get_tree().get_first_node_in_group("objective_health")
	return _objective_health

## Строка 3 (верх-центр, под счётом раундов): здоровье objective-цели. ТОЛЬКО режим
## TARGET_OBJECTIVE. Имя режима в тексте НЕ пишем — режим задан в настройках карты
## (map_scene.gd @export match_mode), в HUD ему не место.
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
	# record_round_result() (в MatchManager) уже отработал до этого сигнала — серия актуальна.
	# current_round() ещё НЕ инкрементирован (это делает advance_round при старте след. раунда),
	# поэтому здесь это номер только что закончившегося раунда.
	var head := _round_result_head(winner)
	if MatchState.series_complete():
		_result_label.text = "%s\n%s" % [head, _series_verdict()]
		_restart_button.text = "Новый матч"
	else:
		_result_label.text = "Раунд %d/%d — %s" % \
			[MatchState.current_round(), MatchState.total_rounds, head]
		_restart_button.text = "Следующий раунд" + (" (смена сторон)" if _has_side_swap() else "")
	_result_label.visible = true
	_restart_button.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # иначе кнопку нечем кликнуть — мышь захвачена CameraRig

## Итог серии — по стороне-победителю. TEAM_ARENA — по цвету; TARGET_OBJECTIVE — по атака/оборона
## (игрок мог помогать обеим сторонам за матч, «выиграл/проиграл» от лица игрока не однозначно).
func _series_verdict() -> String:
	if _is_color_team_mode():
		var s := _series_by_color()  # [красные, синие]
		var res: String
		if s[0] > s[1]:
			res = "Красные выиграли матч"
		elif s[1] > s[0]:
			res = "Синие выиграли матч"
		else:
			res = "Матч: ничья"
		return "%s   (серия Красные %d : %d Синие)" % [res, s[0], s[1]]
	var verdict: String = {
		"attack": "Матч за атакой", "defense": "Матч за обороной", "tie": "Матч: ничья",
	}[MatchState.series_winner()]
	return "%s   (серия Атака %d : %d Оборона)" % \
		[verdict, MatchState.series_wins_attack, MatchState.series_wins_defense]

## TARGET_OBJECTIVE — «Победа атакующих/обороняющихся» (сторона и есть команда).
## TEAM_ARENA — «Красные/Синие победили» + счёт убийств раунда, никаких атака/оборона.
func _round_result_head(winner: String) -> String:
	if MatchState.match_mode == MatchState.Mode.CONTAINER_EXTRACTION:
		var cm := _resolve_container_manager()
		var red: int = cm.attack_delivered if cm != null else 0   # attack == команда 0 == Красные
		var blue: int = cm.defense_delivered if cm != null else 0  # defense == команда 1 == Синие
		return "%s победили (контейнеры %d : %d)" % \
			["Красные" if winner == "attack" else "Синие", red, blue]
	if not _is_color_team_mode():
		return "Победа атакующих" if winner == "attack" else "Победа обороняющихся"
	var sm := _resolve_score_manager()
	var red_kills: int = sm.attack_kills if sm != null else 0   # attack == команда 0 == Красные
	var blue_kills: int = sm.defense_kills if sm != null else 0  # defense == команда 1 == Синие
	return "%s победили (убийства %d : %d)" % \
		["Красные" if winner == "attack" else "Синие", red_kills, blue_kills]

## Смена сторон между раундами — только TARGET_OBJECTIVE: там роли атака/оборона осмысленно
## чередуются между раундами. В TEAM_ARENA стороны — постоянные команды-цвета (Красные/Синие),
## игрок весь матч в одной; инверсия player_team рассинхронила бы HUD с реальным полем.
func _has_side_swap() -> bool:
	if _is_color_team_mode():
		return false
	var scene := get_tree().current_scene
	return scene != null and scene.get_node_or_null("TeamSpawner") != null

func _on_restart_pressed() -> void:
	if MatchState.series_complete():
		MatchState.reset_series()  # новый матч с нуля: раунд 1, player_team = 0
	else:
		MatchState.advance_round()  # инкремент раунда ИМЕННО здесь — при старте следующего
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
			_state_label.text = "Статус: обычное  |  Маскировка: M"
		TankStateMachineScript.State.DISGUISED:
			_state_label.text = "Статус: маскировка (%.1f с)" % _fsm.get_node("DisguiseTimer").time_left
		TankStateMachineScript.State.DISGUISE_COOLDOWN:
			_state_label.text = "Статус: кулдаун маскировки (%.1f с)" % _fsm.get_node("CooldownTimer").time_left
		TankStateMachineScript.State.RELOAD:
			_state_label.text = "Статус: перезарядка (%.1f с)" % _fsm.get_node("ReloadTimer").time_left

extends CanvasLayer
## HUD — минимальный HUD игрока (ТЗ §10): боезапас, статус танка с таймерами, таймер
## раунда, прогресс objective, счёт команд, финальная стадия, экран результата. Подписка
## на сигналы вместо поллинга — кроме отображения "сколько секунд осталось" у активных
## Timer-нод (нет сигнала на каждый тик).

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@onready var _ammo_label: Label = $AmmoLabel
@onready var _state_label: Label = $StateLabel
@onready var _round_timer_label: Label = $RoundTimerLabel
@onready var _objective_label: Label = $ObjectiveLabel
@onready var _score_label: Label = $ScoreLabel
@onready var _final_stage_label: Label = $FinalStageLabel
@onready var _result_label: Label = $ResultLabel

var _fsm: Node
var _ammo: Node
var _match_manager: Node
var _score_manager: Node

func _ready() -> void:
	var tank: Node = get_tree().current_scene.get_node_or_null("PlayerTank")
	if tank != null:
		_ammo = tank.get_node("AmmoComponent")
		_fsm = tank.get_node("TankStateMachine")
		_ammo.ammo_changed.connect(_on_ammo_changed)
		_fsm.state_changed.connect(_on_state_changed)
		_on_ammo_changed(_ammo.current_ammo, _ammo.max_ammo)
		_update_state_label()

	_match_manager = get_tree().current_scene.get_node_or_null("MatchManager")
	if _match_manager != null:
		_match_manager.round_ended.connect(_on_round_ended)
		_match_manager.final_stage_started.connect(_on_final_stage_started)

	_score_manager = get_tree().current_scene.get_node_or_null("ScoreManager")
	if _score_manager != null:
		_score_manager.score_changed.connect(_on_score_changed)
		_on_score_changed(_score_manager.attack_kills, _score_manager.defense_kills)

	var objective: Node = get_tree().current_scene.get_node_or_null("Map/ObjectiveZone")
	if objective != null:
		objective.progress_changed.connect(_on_objective_progress)
		_on_objective_progress(0.0, GameConfig.objective_hold_time_sec)

	_final_stage_label.visible = false

func _process(_delta: float) -> void:
	if _fsm != null:
		_update_state_label()
	if _match_manager != null:
		_update_round_timer_label()
		if _match_manager._final_stage_active:
			_update_final_stage_label()

func _on_final_stage_started() -> void:
	_final_stage_label.visible = true

func _update_final_stage_label() -> void:
	var t: float = _match_manager.get_node("FinalStageTimer").time_left
	_final_stage_label.text = "ФИНАЛЬНАЯ СТАДИЯ: %.0f с" % t

func _update_round_timer_label() -> void:
	var t: float = _match_manager.get_node("RoundTimer").time_left
	var minutes: int = int(t) / 60
	var seconds: int = int(t) % 60
	_round_timer_label.text = "Раунд: %02d:%02d" % [minutes, seconds]

func _on_objective_progress(elapsed: float, required: float) -> void:
	_objective_label.text = "Objective: %.1f/%.1f с" % [elapsed, required]

func _on_score_changed(attack_kills: int, defense_kills: int) -> void:
	_score_label.text = "Атака %d : %d Оборона" % [attack_kills, defense_kills]

func _on_round_ended(winner: String) -> void:
	_result_label.text = "Победа атакующих!" if winner == "attack" else "Победа обороняющихся!"
	_result_label.visible = true

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

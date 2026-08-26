extends CanvasLayer
## HUD — минимальный HUD игрока (ТЗ §10): за какую команду игрок в этом раунде (пост-ревью),
## боезапас, статус танка с таймерами, таймер раунда, прогресс objective, счёт команд,
## финальная стадия, экран результата. Подписка
## на сигналы вместо поллинга — кроме отображения "сколько секунд осталось" у активных
## Timer-нод (нет сигнала на каждый тик).
## RestartButton (пост-ревью) — появляется вместе с ResultLabel по round_ended, снимает
## захват мыши (иначе по кнопке нечем кликнуть), по нажатию инвертирует MatchState.player_team
## (autoload, см. team_spawner.gd) и рестартует сцену — команды меняются сторонами.

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@onready var _team_label: Label = $TeamLabel
@onready var _ammo_label: Label = $AmmoLabel
@onready var _state_label: Label = $StateLabel
@onready var _round_timer_label: Label = $RoundTimerLabel
@onready var _objective_label: Label = $ObjectiveLabel
@onready var _score_label: Label = $ScoreLabel
@onready var _final_stage_label: Label = $FinalStageLabel
@onready var _result_label: Label = $ResultLabel
@onready var _restart_button: Button = $RestartButton
@onready var _crosshair: Control = $Crosshair

var _fsm: Node
var _ammo: Node
var _match_manager: Node
var _score_manager: Node
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
		_barrel = tank.get_node("Turret/Barrel")
		_camera = tank.get_node("CameraRig/Camera3D")

	_match_manager = get_tree().current_scene.get_node_or_null("MatchManager")
	if _match_manager != null:
		_match_manager.round_ended.connect(_on_round_ended)
		_match_manager.final_stage_started.connect(_on_final_stage_started)

	_score_manager = get_tree().current_scene.get_node_or_null("ScoreManager")
	if _score_manager != null:
		_score_manager.score_changed.connect(_on_score_changed)
		_on_score_changed(_score_manager.attack_kills, _score_manager.defense_kills)

	var objective_health: Node = get_tree().current_scene.get_node_or_null("Map/DestructibleObjective/HealthComponent")
	if objective_health != null:
		objective_health.damaged.connect(_on_objective_damaged)
		_on_objective_damaged(0, GameConfig.objective_hits_required)

	_final_stage_label.visible = false
	_restart_button.visible = false
	_restart_button.pressed.connect(_on_restart_pressed)

func _process(_delta: float) -> void:
	if _fsm != null:
		_update_state_label()
	if _match_manager != null:
		_update_round_timer_label()
		if _match_manager._final_stage_active:
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

func _update_round_timer_label() -> void:
	var t: float = _match_manager.get_node("RoundTimer").time_left
	var minutes: int = int(t) / 60
	var seconds: int = int(t) % 60
	_round_timer_label.text = "Раунд: %02d:%02d" % [minutes, seconds]

func _on_objective_damaged(current_hits: int, max_hits: int, _killer: Node = null) -> void:
	_objective_label.text = "Objective: %d/%d попаданий" % [current_hits, max_hits]

func _on_score_changed(attack_kills: int, defense_kills: int) -> void:
	_score_label.text = "Атака %d : %d Оборона" % [attack_kills, defense_kills]

func _on_round_ended(winner: String) -> void:
	_result_label.text = "Победа атакующих!" if winner == "attack" else "Победа обороняющихся!"
	_result_label.visible = true
	_restart_button.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # иначе кнопку нечем кликнуть — мышь захвачена CameraRig

func _on_restart_pressed() -> void:
	MatchState.player_team = 1 - MatchState.player_team  # команды меняются сторонами каждый новый раунд
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

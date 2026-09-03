extends CharacterBody3D
## Tank — корневой узел танка: команда + визуал команды/HP. Остальная логика — в дочерних
## компонентах (TankStateMachine, TankMovement, ...), это НЕ god-object.
##
## - «Подкраска танка цветом команды» (apply_team_visuals()): меши корпуса/башни/ствола красятся
##   в GameConfig.team_attack_color / team_defense_color по tank.team. Вызывается team_spawner.gd
##   сразу после присвоения team и respawn_controller.gd на возврате в игру.
## - Индикация HP — Label3D над танком, ТОЛЬКО в debug-режиме (MatchState.debug_enabled). Раньше
##   при нефинальном попадании корпус+башня перекрашивались в красный — заменено на цифры HP,
##   чтобы не конфликтовать с цветом команды.
## Уничтожение танка не удаляет узел — HealthComponent.free_on_destroy=false, респаун ведёт
## RespawnController (см. respawn_controller.gd).

enum Team { ATTACK, DEFENSE }

@export var team: Team = Team.ATTACK

## Высота Label3D с HP над центром корпуса (корпус ~0.6, башня ~0.9 — 2.3 гарантированно сверху).
const _HP_LABEL_Y := 2.3

var _team_material: StandardMaterial3D
var _hp_label: Label3D

@onready var _health: Node = get_node_or_null("HealthComponent")

func _ready() -> void:
	add_to_group("tanks")
	if _health != null:
		_health.damaged.connect(_on_damaged)
		_health.destroyed.connect(_on_destroyed)
	apply_team_visuals()
	if MatchState.debug_enabled:
		_setup_hp_label()

func is_attacker() -> bool:
	return team == Team.ATTACK

## Единственная точка «подкраски танка цветом команды». Ставит material_override на меши
## корпуса/башни/ствола. Идемпотентна — переиспользует один StandardMaterial3D, только меняет
## albedo. team_spawner.gd зовёт её после team = ... (и для игрока, и для ботов), respawn —
## на возврате в игру (на случай, если что-то оставило свой override за прошлую жизнь).
func apply_team_visuals() -> void:
	if _team_material == null:
		_team_material = StandardMaterial3D.new()
	_team_material.albedo_color = GameConfig.team_defense_color if team == Team.DEFENSE else GameConfig.team_attack_color
	for path in ["HullMesh", "Turret/TurretMesh", "Turret/Barrel/BarrelMesh"]:
		var mesh: MeshInstance3D = get_node_or_null(path)
		if mesh != null:
			mesh.material_override = _team_material

## Вызывается RespawnController при возврате танка в игру — сбрасывает индикатор HP на полный и
## заново применяет цвет команды.
func on_respawned() -> void:
	apply_team_visuals()
	_refresh_hp_label()

func _on_damaged(_current_hits: int, _max_hits: int, _killer: Node) -> void:
	_refresh_hp_label()

func _on_destroyed(_killer: Node) -> void:
	if _hp_label != null:
		_hp_label.text = "DEAD"

## Label3D — billboard, всегда лицом к камере; дочерний узел корня танка, скрывается/показывается
## вместе с ним на смерти/респавне (RespawnController прячет весь танк).
func _setup_hp_label() -> void:
	_hp_label = Label3D.new()
	_hp_label.name = "HpDebugLabel"
	_hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.no_depth_test = true
	_hp_label.fixed_size = true
	_hp_label.pixel_size = 0.0007
	_hp_label.outline_size = 12
	_hp_label.modulate = Color(1, 1, 1)
	_hp_label.outline_modulate = Color(0, 0, 0)
	_hp_label.position = Vector3(0.0, _HP_LABEL_Y, 0.0)
	add_child(_hp_label)
	# call_deferred: team_spawner._apply_tank_config() проставляет health.max_hits уже ПОСЛЕ
	# add_child(tank) (то есть после этого _ready()) — читаем актуальное значение на кадр позже.
	_refresh_hp_label.call_deferred()

func _refresh_hp_label() -> void:
	if _hp_label == null or _health == null:
		return
	_hp_label.text = "HP %d/%d" % [max(0, _health.max_hits - _health.current_hits), _health.max_hits]

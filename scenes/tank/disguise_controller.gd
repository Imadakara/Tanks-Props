extends Node3D
## DisguiseController — активация маскировки в валидном DisguiseSlot, подмена визуала
## (ТЗ §6). Условия досрочного снятия (поворот башни / движение / выстрел / столкновение)
## реализованы в TurretController / TankMovement / TankStateMachine / CollisionDetector —
## этот компонент только переключает визуал по факту смены состояния и хранит, в каком
## слоте танк сейчас стоит.

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

signal disguise_started()
signal disguise_ended()

@export var is_player_controlled: bool = true

var _slots_inside: Array = []
var _active_slot: Node = null
var _disguise_mesh_instance: MeshInstance3D

@onready var _hull_mesh: MeshInstance3D = get_parent().get_node("HullMesh")
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")

func _ready() -> void:
	_state_machine.state_changed.connect(_on_state_changed)

func _unhandled_input(event: InputEvent) -> void:
	if not is_player_controlled:
		return
	if event.is_action_pressed("toggle_disguise"):
		try_enter_disguise()

func register_slot(slot: Node) -> void:
	if not _slots_inside.has(slot):
		_slots_inside.append(slot)

func unregister_slot(slot: Node) -> void:
	_slots_inside.erase(slot)

func is_in_valid_slot() -> bool:
	return not _slots_inside.is_empty()

## Публичный вход для игрока (Input Action toggle_disguise) и ботов (Этап 8).
func try_enter_disguise() -> bool:
	if _slots_inside.is_empty():
		return false
	if not _state_machine.request_disguise():
		return false
	_active_slot = _slots_inside[0]
	_show_disguise(_active_slot)
	disguise_started.emit()
	return true

func _on_state_changed(old_state, new_state) -> void:
	if old_state == TankStateMachineScript.State.DISGUISED and new_state != TankStateMachineScript.State.DISGUISED:
		_hide_disguise()
		disguise_ended.emit()

func _show_disguise(slot: Node) -> void:
	_hull_mesh.visible = false
	_turret.visible = false
	if _disguise_mesh_instance == null:
		_disguise_mesh_instance = MeshInstance3D.new()
		add_child(_disguise_mesh_instance)
	_disguise_mesh_instance.mesh = slot.disguise_mesh
	_disguise_mesh_instance.visible = true

func _hide_disguise() -> void:
	_hull_mesh.visible = true
	_turret.visible = true
	if _disguise_mesh_instance != null:
		_disguise_mesh_instance.visible = false
	_active_slot = null

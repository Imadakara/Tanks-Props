extends CharacterBody3D
## Tank — корневой узел танка: команда + визуальная индикация повреждения. Остальная
## логика — в дочерних компонентах (TankStateMachine, TankMovement, ...), это НЕ
## god-object. HealthComponent теперь многоударный (см. health_component.gd) — при
## НЕфинальном попадании корпус+башня перекрашиваются в красный («подранок»).
## Уничтожение танка (пост-ревью) не удаляет узел — HealthComponent.free_on_destroy=false
## на танках, респаун ведёт RespawnController (см. respawn_controller.gd).

enum Team { ATTACK, DEFENSE }

@export var team: Team = Team.ATTACK

var _damaged_material: StandardMaterial3D

func _ready() -> void:
	add_to_group("tanks")
	var health: Node = get_node_or_null("HealthComponent")
	if health != null:
		health.damaged.connect(_on_damaged)

func is_attacker() -> bool:
	return team == Team.ATTACK

## Вызывается RespawnController при возврате танка в игру (пост-ревью) — снимает подсветку
## «подранка» с прошлой жизни.
func clear_damage_paint() -> void:
	var hull: MeshInstance3D = get_node_or_null("HullMesh")
	if hull != null:
		hull.material_override = null
	var turret_mesh: MeshInstance3D = get_node_or_null("Turret/TurretMesh")
	if turret_mesh != null:
		turret_mesh.material_override = null

func _on_damaged(current_hits: int, max_hits: int) -> void:
	if current_hits >= max_hits:
		return  # последний удар — танк сейчас уничтожится, красить незачем
	if _damaged_material == null:
		_damaged_material = StandardMaterial3D.new()
		_damaged_material.albedo_color = Color(0.85, 0.1, 0.1)
	var hull: MeshInstance3D = get_node_or_null("HullMesh")
	if hull != null:
		hull.material_override = _damaged_material
	var turret_mesh: MeshInstance3D = get_node_or_null("Turret/TurretMesh")
	if turret_mesh != null:
		turret_mesh.material_override = _damaged_material

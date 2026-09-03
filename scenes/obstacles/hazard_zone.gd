@tool
extends Area3D
## HazardZone — универсальный префаб НЕПРОХОДИМОЙ ЗОНЫ (для любой карты). `Area3D` без
## физического тела: танк (игрок и бот) проезжает СКВОЗЬ неё свободно, но запекатель навмеша
## видит её по слою 3 (`collision_layer = 4`, входит в `geometry/collision_mask = 5`) и боты
## маршрут через неё не строят. Одна техническая сцена `scenes/obstacles/HazardZone.tscn`,
## размер каждого экземпляра — `@export size` (`@tool`, синхронит коллайдер и меш). См.
## `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md` §2.
##
## `collision_layer = 4` / `collision_mask = 0` и полупрозрачный красный материал заданы в самой
## сцене. Меш — только визуал, на игру не влияет.

## Габариты зоны. Применяются к дочернему `CollisionShape3D` (`BoxShape3D`) и `Mesh` (`BoxMesh`).
@export var size: Vector3 = Vector3(2.0, 1.25, 2.0):
	set(value):
		size = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

func _ready() -> void:
	_apply()

## Sub-ресурсы в `HazardZone.tscn` помечены `resource_local_to_scene = true` — правка `size`
## одного инстанса не задевает остальные.
func _apply() -> void:
	if not is_node_ready():
		return
	if _shape != null and _shape.shape is BoxShape3D:
		_shape.shape.size = size
	if _mesh != null and _mesh.mesh is BoxMesh:
		_mesh.mesh.size = size

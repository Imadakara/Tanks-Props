@tool
extends Area3D
## HazardZone — универсальный префаб НЕПРОХОДИМОЙ ЗОНЫ (для любой карты). `Area3D` без
## физического тела: танк (игрок и бот) проезжает СКВОЗЬ неё свободно. Одна техническая сцена
## `scenes/obstacles/HazardZone.tscn`, размер каждого экземпляра — `@export size` (`@tool`,
## синхронит коллайдер и меш). См. `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md` §2.
##
## `collision_layer = 4` (слой 3) / `collision_mask = 0` и полупрозрачный красный материал заданы
## в самой сцене. Меш — только визуал.
##
## ВАЖНО: навмеш зона НЕ вырезает (проверено — ни editor-запечка `PARSED_GEOMETRY_BOTH`, ни
## рантайм `PARSED_GEOMETRY_STATIC_COLLIDERS` её не исключают; `geometry_collision_mask=5` на деле
## режет только слой 1). Боты не заезжают в зону РЕАКТИВНО: их лучи объезда (`tank_ai_controller.
## _cast_ray_dist`, `collide_with_areas=true`, маска включает слой 3) видят Area3D зоны как
## препятствие и рулят в обход — A*-маршрут при этом может идти сквозь зону, но gap-scan/
## аварийный тормоз бота его от неё отклоняют. Для настоящего carve навмеша нужен был бы
## `NavigationObstacle3D` (`affect_navigation_mesh`) — вне текущего объёма.

## Габариты зоны. Применяются к дочернему `CollisionShape3D` (`BoxShape3D`) и `Mesh` (`BoxMesh`).
@export var size: Vector3 = Vector3(2.0, 1.25, 2.0):
	set(value):
		size = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

func _ready() -> void:
	_apply()
	if Engine.is_editor_hint():
		return
	# Непроходимые зоны — keep-out для динамической расстановки препятствий (сами editor-placed,
	# система их не трогает; см. dynamic_obstacle_placer.gd).
	add_to_group("hazard_zones")

## Sub-ресурсы в `HazardZone.tscn` помечены `resource_local_to_scene = true` — правка `size`
## одного инстанса не задевает остальные.
func _apply() -> void:
	if not is_node_ready():
		return
	if _shape != null and _shape.shape is BoxShape3D:
		_shape.shape.size = size
	if _mesh != null and _mesh.mesh is BoxMesh:
		_mesh.mesh.size = size

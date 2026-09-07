@tool
extends StaticBody3D
## Structure — коробка ПОСТОЯННОЙ геометрии карты (мебель, стены, столешницы, полки, тумбы).
## Технически идентична `Obstacle` (`scenes/obstacles/obstacle.gd`): `@export size`/`color`
## синхронизируют дочерние `BoxShape3D`/`BoxMesh`/`StandardMaterial3D`, `@tool` — чтобы это
## работало прямо в редакторе, `collision_layer = 1` / `collision_mask = 0` заданы в самой сцене
## (запекатель навмеша берёт геометрию по слою 1).
##
## ЗАЧЕМ ОТДЕЛЬНЫЙ ПРЕФАБ, А НЕ `Obstacle.tscn`: `obstacle.gd` регистрируется в группу
## `"obstacles"`, а динамическая расстановка препятствий (`map_scene.gd._apply_dynamic_obstacles()`
## → `dynamic_obstacle_placer.gd`) эту группу ЦЕЛИКОМ УДАЛЯЕТ перед раскладкой. Кухонная карта,
## собранная из `Obstacle`, была бы снесена до голого пола первой же галочкой «динамические
## препятствия» в меню. Разделение по смыслу заодно честное: `Obstacle` — сменное укрытие
## (и объект имитации маскировки, его размер совпадает с `GameConfig.disguise_prop_size`),
## `Structure` — сама карта.
##
## Группа `"structures"` — на будущее (общий keep-out для любой процедурной расстановки, единый
## обход геометрии карты); ничего в неё сейчас не смотрит, регистрация ничего не стоит.
##
## НЕ масштабировать узел через `Transform → Scale` — ненулевой scale на физ.теле в Jolt ведёт
## себя неочевидно и путает запекатель (см. `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md` §6.2).
## Размер — только `size` здесь.

@export var size: Vector3 = Vector3(12.0, 6.0, 12.0):
	set(value):
		size = value
		_apply()

@export var color: Color = Color(0.78, 0.74, 0.68):
	set(value):
		color = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

func _ready() -> void:
	_apply()
	if not Engine.is_editor_hint():
		add_to_group("structures")

## Sub-ресурсы в `Structure.tscn` помечены `resource_local_to_scene = true` — у каждого инстанса
## свои `BoxShape3D`/`BoxMesh`/`StandardMaterial3D`, правка одного инстанса не задевает остальные.
func _apply() -> void:
	if not is_node_ready():
		return
	if _shape != null and _shape.shape is BoxShape3D:
		_shape.shape.size = size
	if _mesh != null:
		if _mesh.mesh is BoxMesh:
			_mesh.mesh.size = size
		if _mesh.material_override is StandardMaterial3D:
			_mesh.material_override.albedo_color = color

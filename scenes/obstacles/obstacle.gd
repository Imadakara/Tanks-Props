@tool
extends StaticBody3D
## Obstacle — универсальный префаб СПЛОШНОГО препятствия (коробка / ящик / стенка / укрытие) для
## ЛЮБОЙ карты. Одна техническая сцена `scenes/obstacles/Obstacle.tscn`, каждый экземпляр
## настраивается через `@export` (`size` / `color`) — скрипт `@tool`, поэтому коллайдер, меш и
## материал синхронизируются прямо в редакторе, без ручной правки двух мест (см.
## `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md`).
##
## Заменяет прежние разложенные по `.tscn` карт руками связки
## `StaticBody3D + CollisionShape3D + MeshInstance3D`. Ставится ребёнком `NavigationRegion3D` —
## запекатель навмеша берёт его геометрию по слою 1 (`environment`), как и раньше. Никакой код не
## ищет препятствия по имени, имя нужно только для порядка в сцене.
##
## `collision_layer = 1` / `collision_mask = 0` заданы в самой сцене (`Obstacle.tscn`): тело
## ничего не «замечает», но его форму видит запекатель (`geometry/collision_mask = 5`).
##
## НЕ масштабировать узел через `Transform → Scale` — ненулевой scale на физ.теле в Jolt ведёт
## себя неочевидно и путает запекатель (гайд §6.2). Размер — только `size` здесь.

## Габариты коробки. Применяются к дочернему `CollisionShape3D` (`BoxShape3D`) и `Mesh`
## (`BoxMesh`) синхронно. Дефолт совпадает с прежними `Obstacle*` в `TargetObjectiveMap.tscn`
## (и с `GameConfig.disguise_prop_size` — объект имитации маскировки).
@export var size: Vector3 = Vector3(2.0, 1.25, 2.0):
	set(value):
		size = value
		_apply()

## Цвет меша (`albedo`). Дефолт — коричневый, как у прежних `Obstacle*`. Серый переопределяют
## инстансы-стенки.
@export var color: Color = Color(0.6, 0.35, 0.15):
	set(value):
		color = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

func _ready() -> void:
	_apply()

## Sub-ресурсы в `Obstacle.tscn` помечены `resource_local_to_scene = true` — у каждого инстанса
## свои `BoxShape3D` / `BoxMesh` / `StandardMaterial3D`, правка `size`/`color` одного инстанса не
## задевает остальные.
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
